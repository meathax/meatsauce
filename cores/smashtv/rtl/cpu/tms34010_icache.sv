// -----------------------------------------------------------------------------
// tms34010_icache.sv
//
// TMS34010 on-chip instruction cache (256 bytes), per the 1988 User's Guide
// (§5 Instruction Cache). Structure:
//   - 4 SEGMENTS. Each segment caches one aligned 64-byte (512-bit = 32-word)
//     region of program space, identified by its Segment Start Address (SSA =
//     the upper bit-address bits PC[31:9]).
//   - Each segment holds 8 SUBSEGMENTS of 4 words (8 bytes) each, with one
//     "present" (P) flag per subsegment. 4 seg x 8 sub x 4 words x 16 bits =
//     2048 bits = 256 bytes.
//   - A fetch HITs when some segment's SSA matches PC[31:9] AND that
//     subsegment's P flag is set; the word is returned with no memory cycle.
//   - On a MISS the whole 4-word subsegment is filled from memory (the real
//     device's cache-fill), its P flag set, then the requested word returned.
//   - Segment replacement is LRU across the 4 segments (exact 4-entry LRU).
//   - CD (CONTROL bit 15) disables the cache -> every fetch is a pass-through
//     memory read. A flush pulse invalidates all segments (e.g. CACHE flush /
//     self-modifying-code sync).
//
// The cache is FUNCTIONALLY TRANSPARENT: for any given program image it returns
// exactly the same words as a direct memory fetch. It changes only memory-cycle
// timing (a first-order timing determinant on real silicon, and it cuts SDRAM
// fetch traffic on the FPGA). Verified transparent by the boot differential.
//
// Integration: the core routes CORE_FETCH through this module. During a fetch
// the module drives the shared memory port (mem_req/mem_addr) for fills; the
// core muxes that onto its bus while in CORE_FETCH. `fetch_done` replaces
// `mem_ack` as the fetch-complete handshake; `fetch_word` is the 16-bit opcode.
// -----------------------------------------------------------------------------

`default_nettype none
module tms34010_icache
  import tms34010_pkg::*;
(
  input  logic                  clk,
  input  logic                  rst,

  input  logic                  cache_disable,  // CONTROL.CD (bit 15): 1 = bypass
  input  logic                  flush,          // 1-cycle: invalidate all segments

  // Fetch interface (from the core's CORE_FETCH state).
  input  logic                  fetch_req,      // core requests the word at fetch_pc
  input  logic [ADDR_WIDTH-1:0] fetch_pc,       // bit-address, [3:0] = 0
  output logic                  fetch_done,     // 1 = fetch_word valid this cycle
  output logic [15:0]           fetch_word,     // returned instruction word
  output logic                  busy,           // 1 = a subsegment fill is in progress

  // Memory master (muxed onto the core's bus while it is in CORE_FETCH).
  output logic                  icache_mem_req,
  output logic [ADDR_WIDTH-1:0] icache_mem_addr,
  input  logic [DATA_WIDTH-1:0] mem_rdata,
  input  logic                  mem_ack
);

  // --- address decomposition (word-aligned bit-address) ----------------------
  //   PC[3:0]   = 0            (16-bit word alignment for a fetch)
  //   PC[5:4]   = word within subsegment (4 words)
  //   PC[8:6]   = subsegment within segment (8 subsegments)
  //   PC[31:9]  = SSA tag
  localparam int TAGW = ADDR_WIDTH - 9;         // 23
  logic [1:0]        word_sel;
  logic [2:0]        subseg_sel;
  logic [TAGW-1:0]   tag;
  assign word_sel   = fetch_pc[5:4];
  assign subseg_sel = fetch_pc[8:6];
  assign tag        = fetch_pc[ADDR_WIDTH-1:9];

  // --- storage ---------------------------------------------------------------
  logic [15:0]     cdata   [0:3][0:7][0:3];      // [segment][subsegment][word]
  logic [TAGW-1:0] seg_ssa [0:3];
  logic            seg_valid   [0:3];
  logic            sub_present [0:3][0:7];
  // Exact LRU: mru[0] = most-recently-used segment index, mru[3] = LRU victim.
  logic [1:0]      mru [0:3];

  // --- combinational hit detection -------------------------------------------
  logic       hit;
  logic [1:0]  hit_seg;
  always_comb begin
    hit     = 1'b0;
    hit_seg = 2'd0;
    for (int s = 0; s < 4; s++) begin
      if (seg_valid[s] && (seg_ssa[s] == tag) && sub_present[s][subseg_sel]) begin
        hit     = 1'b1;
        hit_seg = s[1:0];
      end
    end
  end

  // Segment already allocated to this SSA (present or not) — a miss reuses it
  // rather than evicting another segment. Else the LRU victim is allocated.
  logic       ssa_match;
  logic [1:0] ssa_seg;
  always_comb begin
    ssa_match = 1'b0;
    ssa_seg   = mru[3];                          // default: evict LRU
    for (int s = 0; s < 4; s++)
      if (seg_valid[s] && (seg_ssa[s] == tag)) begin
        ssa_match = 1'b1;
        ssa_seg   = s[1:0];
      end
  end

  // --- fill FSM --------------------------------------------------------------
  typedef enum logic [1:0] { IC_IDLE, IC_FILL, IC_DONE } ic_state_t;
  ic_state_t   ic_state;
  logic [1:0]  fill_seg;      // segment being filled
  logic [1:0]  fill_word;     // which of the 4 words is being read
  logic [2:0]  fill_subseg;   // subsegment being filled
  logic [TAGW-1:0] fill_tag;

  // Pass-through (cache disabled): fetch maps straight to a memory read.
  logic bypass;
  assign bypass = cache_disable;

  // Busy while a fill is running (not at a clean instruction boundary). The core
  // uses this to avoid diverting to an interrupt mid-fill (which would orphan it).
  assign busy = (ic_state != IC_IDLE);

  // Memory address: the fetch PC when bypassing, else the current fill word's
  // subsegment bit-address {tag, subseg, word, 0}.
  assign icache_mem_addr = bypass ? fetch_pc
                                  : {fill_tag, fill_subseg, fill_word, 4'b0000};

  // Memory request: in bypass, mirror the fetch; otherwise only during a fill.
  assign icache_mem_req = bypass ? fetch_req
                                 : (ic_state == IC_FILL);

  // Fetch handshake + returned word.
  always_comb begin
    if (bypass) begin
      fetch_done = fetch_req & mem_ack;
      fetch_word = mem_rdata[15:0];
    end else if (hit) begin
      fetch_done = fetch_req;                    // 0-wait cache hit
      fetch_word = cdata[hit_seg][subseg_sel][word_sel];
    end else if (ic_state == IC_DONE) begin
      fetch_done = 1'b1;                          // fill just completed
      fetch_word = cdata[fill_seg][subseg_sel][word_sel];
    end else begin
      fetch_done = 1'b0;                          // miss: waiting on fill
      fetch_word = 16'h0000;
    end
  end

  // LRU update helper: move segment `s` to MRU (front), shift the rest back.
  task automatic touch_lru(input logic [1:0] s);
    logic [1:0] tmp [0:3];
    int j;
    j = 0;
    tmp[0] = s;
    for (int k = 0; k < 4; k++)
      if (mru[k] != s) begin
        j = j + 1;
        tmp[j] = mru[k];
      end
    for (int k = 0; k < 4; k++) mru[k] <= tmp[k];
  endtask

  integer i, k;
  always_ff @(posedge clk) begin
    if (rst) begin
      ic_state <= IC_IDLE;
      for (i = 0; i < 4; i++) begin
        seg_valid[i] <= 1'b0;
        seg_ssa[i]   <= '0;
        mru[i]       <= i[1:0];
        for (k = 0; k < 8; k++) sub_present[i][k] <= 1'b0;
      end
    end else if (flush) begin
      // Invalidate everything; fills in progress are abandoned.
      ic_state <= IC_IDLE;
      for (i = 0; i < 4; i++) begin
        seg_valid[i] <= 1'b0;
        for (k = 0; k < 8; k++) sub_present[i][k] <= 1'b0;
      end
    end else if (!bypass) begin
      unique case (ic_state)
        IC_IDLE: begin
          if (fetch_req && hit) begin
            touch_lru(hit_seg);
          end else if (fetch_req && !hit) begin
            // Begin a subsegment fill into the SSA-matching segment, or evict
            // the LRU victim and (re)allocate it to this SSA.
            fill_seg    <= ssa_seg;
            fill_subseg <= subseg_sel;
            fill_tag    <= tag;
            fill_word   <= 2'd0;
            if (!ssa_match) begin
              // reallocate: new SSA, drop all its subsegments
              seg_valid[ssa_seg] <= 1'b1;
              seg_ssa[ssa_seg]   <= tag;
              for (k = 0; k < 8; k++) sub_present[ssa_seg][k] <= 1'b0;
            end
            ic_state <= IC_FILL;
          end
        end
        IC_FILL: begin
          if (mem_ack) begin
            cdata[fill_seg][fill_subseg][fill_word] <= mem_rdata[15:0];
            if (fill_word == 2'd3) begin
              sub_present[fill_seg][fill_subseg] <= 1'b1;
              ic_state <= IC_DONE;
            end else begin
              fill_word <= fill_word + 2'd1;
            end
          end
        end
        IC_DONE: begin
          touch_lru(fill_seg);
          ic_state <= IC_IDLE;
        end
        default: ic_state <= IC_IDLE;
      endcase
    end
  end

endmodule : tms34010_icache

`default_nettype wire
