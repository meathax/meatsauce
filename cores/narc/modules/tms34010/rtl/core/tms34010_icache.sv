// -----------------------------------------------------------------------------
// tms34010_icache.sv
//
// TMS34010 instruction cache, 1988 User's Guide section 5.4.
//
//   5.4.1  256 bytes: four segments of eight four-word subsegments. Each
//          segment has a segment start address (SSA, address bits 31-9) and
//          one present (P) flag per subsegment. Bits 8-6 select the
//          subsegment, bits 5-4 the word.
//   5.4.2  LRU stack of segment numbers. A segment miss replaces the least
//          recently used segment: its P flags are cleared and its SSA loaded.
//          Reset clears every P flag and orders the stack 0-3.
//   5.4.3  Hit: the word is read from the cache and the segment goes to the
//          top of the stack. Subsegment miss: the four-word subsegment is
//          read from memory, its P flag set, the segment moved to the top and
//          the word read from the cache. Segment miss: as above after
//          replacing the LRU segment.
//   5.4    Only words addressed by the PC (opcodes, immediates, absolute
//          addresses) use the cache; data reads and writes bypass it, and
//          writes never update it (5.4.4).
//   5.4.5  HSTCTL.CF=1 flushes: all P flags clear (the reset state) and
//          fetches bypass the cache for as long as CF stays set.
//   5.4.6  CONTROL.CD=1 bypasses the cache and protects its contents.
//
// The fill reads the subsegment as two 32-bit fields (four word cycles).
// The data store is a 64 x 32 synchronous RAM (one Cyclone V M10K); a hit
// answers the clock after it is asked, well within the machine state (5.5:
// two cache fetches per pair of states). The lookup uses the PC register
// (c_pc), which addresses every instruction word, rather than the core's
// general address mux.
//
// Assumptions (docs/cycle_accuracy.md):
//   C2  A segment with no P flag set does not match; a fetch into it is a
//       segment miss. SSA contents after reset are not specified (5.4.2),
//       and this keeps a freshly reset cache from matching on reset SSAs.
//   C3  Reset/flush stack order: segment 0 on top, segment 3 at the bottom
//       (replaced first). The guide says only "numerical order (0-3)".
//   C4  Subsegment words are filled in ascending address order.
//
// With ENABLE=0 the module is a wire.
//
// Clock domain: core clock. Reset is synchronous active-high (A0003).
// -----------------------------------------------------------------------------

`default_nettype none

module tms34010_icache
  import tms34010_pkg::*;
#(
  parameter bit ENABLE = 1'b0
)(
  input  logic                          clk,
  input  logic                          rst,
  input  logic                          cd_i,       // CONTROL.CD
  input  logic                          cf_i,       // HSTCTL.CF

  // CPU side.
  input  logic                          c_req,
  input  logic                          c_we,
  input  logic [ADDR_WIDTH-1:0]         c_addr,
  input  logic [FIELD_SIZE_WIDTH-1:0]   c_size,
  input  logic [DATA_WIDTH-1:0]         c_wdata,
  input  logic                          c_iaq,
  input  logic                          c_ifetch,   // word addressed by the PC
  input  logic [ADDR_WIDTH-1:0]         c_pc,       // the PC (= c_addr when c_ifetch)
  input  logic                          c_srt,
  input  logic                          c_is_io,
  input  logic                          c_io_we,
  output logic                          c_ack,
  output logic [DATA_WIDTH-1:0]         c_rdata,
  output logic                          c_from_mem, // this ack's word came from memory

  // Memory side.
  output logic                          m_req,
  output logic                          m_we,
  output logic [ADDR_WIDTH-1:0]         m_addr,
  output logic [FIELD_SIZE_WIDTH-1:0]   m_size,
  output logic [DATA_WIDTH-1:0]         m_wdata,
  output logic                          m_iaq,
  output logic                          m_srt,
  output logic                          m_is_io,
  output logic                          m_io_we,
  input  logic                          m_ack,
  input  logic [DATA_WIDTH-1:0]         m_rdata
);

  generate
    if (ENABLE) begin : g_cache

      typedef enum logic [1:0] {
        IC_IDLE = 2'd0,
        IC_HIT  = 2'd1,
        IC_FILL = 2'd2,
        IC_DONE = 2'd3
      } ic_state_t;

      // Justification (a): architected cache state (5.4.1, 5.4.2) and the
      // fill sequencer.
      ic_state_t   state_q;
      logic [22:0] ssa_q   [0:3];
      logic [7:0]  p_q     [0:3];
      logic [1:0]  lru_q   [0:3];      // [0] most, [3] least recently used
      logic [1:0]  seg_q;              // segment being filled / read
      logic        half_q;             // fill: second 32-bit field
      logic [31:0] fill_lo_q;          // fill: words 0-1 of the subsegment
      logic [31:0] ram_q;
      logic [31:0] ram [0:63];

      logic        bypass;
      logic        lookup;
      logic [3:0]  ssa_match;
      logic        seg_hit;
      logic [1:0]  hit_seg;
      logic        word_hit;
      logic [2:0]  sub;
      logic [1:0]  use_seg;
      logic [1:0]  lru_d   [0:3];
      logic        ram_we;
      logic [5:0]  ram_waddr;
      logic [5:0]  ram_raddr;

      assign bypass = cd_i || cf_i || !c_ifetch;
      assign lookup = (state_q == IC_IDLE) && c_req && !bypass;
      assign sub    = c_pc[8:6];

      always_comb begin
        ssa_match = '0;
        seg_hit   = 1'b0;
        hit_seg   = 2'd0;
        for (int s = 0; s < 4; s++) begin
          ssa_match[s] = (ssa_q[s] == c_pc[31:9]) && (p_q[s] != 8'h00);
          if (ssa_match[s]) begin
            seg_hit = 1'b1;
            hit_seg = 2'(s);
          end
        end
      end
      assign word_hit = seg_hit && p_q[hit_seg][sub];
      assign use_seg  = seg_hit ? hit_seg : lru_q[3];

      // LRU stack: move use_seg to the top, push the ones above it down.
      always_comb begin
        int pos;
        pos = 3;
        for (int i = 0; i < 4; i++)
          if (lru_q[i] == use_seg) pos = i;
        for (int i = 0; i < 4; i++) begin
          if (i == 0)        lru_d[i] = use_seg;
          else if (i <= pos) lru_d[i] = lru_q[i-1];
          else               lru_d[i] = lru_q[i];
        end
      end

      // Data store. Index {segment, subsegment, word pair}.
      assign ram_we    = (state_q == IC_FILL) && m_ack;
      assign ram_waddr = {seg_q, sub, half_q};
      assign ram_raddr = {use_seg, sub, c_pc[5]};

      always_ff @(posedge clk) begin
        if (ram_we)
          ram[ram_waddr] <= m_rdata;
        ram_q <= ram[ram_raddr];
      end

      always_ff @(posedge clk) begin
        if (rst) begin
          state_q <= IC_IDLE;
          for (int s = 0; s < 4; s++) begin
            p_q[s]   <= 8'h00;
            lru_q[s] <= 2'(s);
          end
          seg_q   <= 2'd0;
          half_q  <= 1'b0;
        end else if (cf_i) begin
          // Flush (5.4.5): back to the reset contents. A fill already in the
          // memory fabric completes but sets no P flag.
          for (int s = 0; s < 4; s++) begin
            p_q[s]   <= 8'h00;
            lru_q[s] <= 2'(s);
          end
          if ((state_q == IC_FILL) && m_ack) begin
            if (!half_q) begin
              fill_lo_q <= m_rdata;
              half_q    <= 1'b1;
            end else begin
              state_q <= IC_DONE;
            end
          end else if ((state_q == IC_HIT) || (state_q == IC_DONE)) begin
            state_q <= IC_IDLE;
          end
        end else begin
          unique case (state_q)
            IC_IDLE: if (lookup) begin
              seg_q <= use_seg;
              for (int i = 0; i < 4; i++) lru_q[i] <= lru_d[i];
              if (word_hit) begin
                state_q <= IC_HIT;
              end else begin
                if (!seg_hit) begin
                  ssa_q[use_seg] <= c_pc[31:9];
                  p_q[use_seg]   <= 8'h00;
                end
                half_q  <= 1'b0;
                state_q <= IC_FILL;
              end
            end
            IC_HIT:  state_q <= IC_IDLE;
            IC_FILL: if (m_ack) begin
              if (!half_q) begin
                fill_lo_q <= m_rdata;
                half_q    <= 1'b1;
              end else begin
                p_q[seg_q][sub] <= 1'b1;
                state_q         <= IC_DONE;
              end
            end
            IC_DONE: state_q <= IC_IDLE;
            default: state_q <= IC_IDLE;
          endcase
        end
      end

      // The fill's second field (words 2-3) is on m_rdata in IC_FILL and
      // registered into the RAM; IC_DONE answers from the RAM output or the
      // held first field.
      logic [31:0] hi_q;
      always_ff @(posedge clk)
        if ((state_q == IC_FILL) && m_ack && half_q) hi_q <= m_rdata;

      always_comb begin
        // Default: pass the CPU request straight through.
        m_req   = c_req && bypass && (state_q == IC_IDLE);
        m_we    = c_we;
        m_addr  = c_addr;
        m_size  = c_size;
        m_wdata = c_wdata;
        m_iaq   = c_iaq;
        m_srt   = c_srt;
        m_is_io = c_is_io;
        m_io_we = c_io_we;
        c_ack   = m_ack && bypass && (state_q == IC_IDLE);
        c_rdata = m_rdata;
        c_from_mem = c_ack && c_ifetch;

        unique case (state_q)
          IC_HIT: begin
            c_ack   = 1'b1;
            c_rdata = {16'h0000, c_pc[4] ? ram_q[31:16] : ram_q[15:0]};
            c_from_mem = 1'b0;
          end
          IC_FILL: begin
            m_req   = 1'b1;
            m_we    = 1'b0;
            m_addr  = {c_pc[31:6], half_q, 5'b00000};
            m_size  = FIELD_SIZE_WIDTH'(32);
            m_wdata = '0;
            m_iaq   = 1'b1;
            m_srt   = 1'b0;
            m_is_io = 1'b0;
            m_io_we = 1'b0;
          end
          IC_DONE: begin
            c_ack = 1'b1;
            c_from_mem = 1'b1;
            unique case (c_pc[5:4])
              2'd0:    c_rdata = {16'h0000, fill_lo_q[15:0]};
              2'd1:    c_rdata = {16'h0000, fill_lo_q[31:16]};
              2'd2:    c_rdata = {16'h0000, hi_q[15:0]};
              default: c_rdata = {16'h0000, hi_q[31:16]};
            endcase
          end
          default: ;
        endcase
      end

    end else begin : g_wire
      assign m_req   = c_req;
      assign m_we    = c_we;
      assign m_addr  = c_addr;
      assign m_size  = c_size;
      assign m_wdata = c_wdata;
      assign m_iaq   = c_iaq;
      assign m_srt   = c_srt;
      assign m_is_io = c_is_io;
      assign m_io_we = c_io_we;
      assign c_ack   = m_ack;
      assign c_rdata = m_rdata;
      assign c_from_mem = m_ack && c_ifetch;
    end
  endgenerate

endmodule : tms34010_icache

`default_nettype wire
