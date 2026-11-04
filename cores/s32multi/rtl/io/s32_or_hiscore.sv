//============================================================================
// OutRunners high-score persistence.
//
// OutRunners keeps its ten-entry ranking table only in V70 work RAM
// (0x20E301..0x20E33B, 59 bytes; MAME hiscore.dat entry 1).  The game copies
// the default table from program ROM 0x2CC8 into that range about 10 and
// again about 143 frames after every reset (MAME 0.289 write-tap trace), and
// never again while running.  hiscore.dat's second entry (0x20E212) is a live
// counter cycling 00/70/78 every 64 frames, so it is neither saved nor used as
// a readiness check here.
//
// The scores ride in the same MiSTer NVRAM file as the 93C46 EEPROM (one
// file per MRA): bytes 0..127 EEPROM, 128..186 the table, 187 a 0x5A
// signature that marks the table valid.  Total 188 bytes (MRA nvram size).
//
//   * Restore: GUARD_CYCLES after reset release (past the second ROM copy),
//     two POLL_CYCLES-spaced polls must see the default first/last bytes
//     (0x53/0x75); then, if a valid table was loaded or captured, it is
//     written back byte-by-byte through work RAM port B.
//   * Capture: afterwards every POLL_CYCLES the 59 RAM bytes are compared
//     with the shadow; changes update it and raise `dirty` (OR-ed into
//     ioctl_upload_req so MiSTer saves on the next OSD open).
//
// Work RAM port B: registered address, unregistered q (data valid two clocks
// after ram_addr is driven from a register).  The shadow is two 32x8 MLABs
// (even/odd file bytes) read asynchronously by the HPS upload path, which
// samples ioctl_din combinationally like the EEPROM shadow.
//============================================================================
module s32_or_hiscore #(
    parameter integer GUARD_CYCLES = 241586535,  // 5.0 s @ 48,317,307 Hz
    parameter integer POLL_CYCLES  = 262144      // ~5.4 ms
) (
    input             clk,
    input             rst,          // game reset (re-arm the restore)
    input             enable,       // OutRunners descriptor

    // HPS NVRAM (index 3) download / upload, 16-bit WIDE ioctl
    input             dl_wr,        // ioctl_download && ioctl_wr && index==3
    input      [26:0] dl_addr,
    input      [15:0] dl_data,
    input             ul_active,    // index-3 upload in progress
    input      [26:0] ul_addr,
    output     [15:0] ul_data,      // file bytes 128..191

    // work RAM port B
    output reg [15:0] ram_addr,
    output reg        ram_we,
    output reg  [1:0] ram_be,
    output reg [15:0] ram_wdata,
    input      [15:0] ram_q,

    output reg        dirty = 1'b0
);

localparam [16:0] TABLE_BASE = 17'h0E301;    // 0x20E301 in the 128 KiB RAM
localparam  [5:0] TABLE_LAST = 6'd58;        // 59 bytes
localparam  [7:0] SIG        = 8'h5A;

// --------------------------------------------------------------- shadow
// lo_mem[w] = file byte 128+2w (table byte 2w); hi_mem[w] = byte 2w+1.
(* ramstyle = "MLAB, no_rw_check" *) reg [7:0] lo_mem [0:31];
(* ramstyle = "MLAB, no_rw_check" *) reg [7:0] hi_mem [0:31];
reg valid = 1'b0;                            // shadow holds a real table

// HPS file byte 128+2w..+1 -> shadow word w (file offsets 128..191)
wire       dl_hit  = dl_wr && (dl_addr[26:7] == 20'd1) && !dl_addr[6];
wire [4:0] dl_word = dl_addr[5:1];

reg  [5:0] k;                                // engine table byte index
wire [4:0] ul_word = ul_addr[5:1];
wire       ul_hit  = (ul_addr[26:7] == 20'd1) && !ul_addr[6];
wire [4:0] sh_raddr = ul_active ? ul_word : k[5:1];
wire [7:0] sh_lo_q = lo_mem[sh_raddr];
wire [7:0] sh_hi_q = hi_mem[sh_raddr];
wire [7:0] sh_byte = k[0] ? sh_hi_q : sh_lo_q;

assign ul_data = !ul_hit          ? 16'h0000 :
                 (ul_word == 5'd29) ? {valid ? SIG : 8'h00, sh_lo_q} :
                 (ul_word >= 5'd30) ? 16'h0000 : {sh_hi_q, sh_lo_q};

reg       sh_we;
reg [5:0] sh_wk;       // table index of the pending shadow write
reg [7:0] sh_wdata;
always @(posedge clk) begin
    if (dl_hit) begin
        lo_mem[dl_word] <= dl_data[7:0];
        hi_mem[dl_word] <= dl_data[15:8];
    end
    else if (sh_we) begin
        if (!sh_wk[0]) lo_mem[sh_wk[5:1]] <= sh_wdata;
        else           hi_mem[sh_wk[5:1]] <= sh_wdata;
    end
end

// --------------------------------------------------------------- engine
// RAM byte for table index k: address 0xE301+k; odd addresses are the high
// byte of the little-endian 16-bit word.
wire [16:0] k_byte_addr = TABLE_BASE + {11'd0, k};
wire        k_lane_hi   = k_byte_addr[0];
wire  [7:0] ram_byte    = k_lane_hi ? ram_q[15:8] : ram_q[7:0];

localparam [2:0] S_GUARD   = 3'd0,
                 S_IDLE    = 3'd1,
                 S_RD      = 3'd2,   // drive address
                 S_RD_W    = 3'd3,   // RAM registers address
                 S_RD_USE  = 3'd4,   // q valid
                 S_RESTORE = 3'd5;
reg  [2:0] st = S_GUARD;
reg [27:0] timer = 28'd0;
reg        live = 1'b0;          // restore decided; capturing
reg        ready_once = 1'b0;    // first of two readiness polls seen
reg        chk_first_ok = 1'b0;
reg        scan_changed = 1'b0;
reg        ul_d = 1'b0;

always @(posedge clk) begin
    ram_we <= 1'b0;
    sh_we  <= 1'b0;
    ul_d   <= ul_active;

    // An upload start acknowledges the current generation (like the EEPROM
    // modified flag); a download establishes a clean, freshly loaded state.
    if (ul_active && !ul_d)
        dirty <= 1'b0;

    if (dl_hit) begin
        if (dl_word == 5'd29) valid <= (dl_data[15:8] == SIG);
        dirty <= 1'b0;
    end

    if (rst || !enable || dl_hit) begin
        st <= S_GUARD;
        timer <= 28'd0;
        live <= 1'b0;
        ready_once <= 1'b0;
        k <= 6'd0;
    end
    else if (ul_active) begin
        // Hold while HPS reads the shadow: the shadow read port follows the
        // upload address, so engine compares/writes must not run.
    end
    else begin
        case (st)
        S_GUARD: begin
            timer <= timer + 1'b1;
            if (timer == GUARD_CYCLES[27:0]) begin
                timer <= 28'd0;
                st <= S_IDLE;
            end
        end

        S_IDLE: begin
            timer <= timer + 1'b1;
            if (timer >= POLL_CYCLES[27:0] && !ul_active) begin
                timer <= 28'd0;
                k <= 6'd0;
                chk_first_ok <= 1'b0;
                scan_changed <= 1'b0;
                st <= S_RD;
            end
        end

        S_RD: begin
            ram_addr <= k_byte_addr[16:1];
            st <= S_RD_W;
        end
        S_RD_W: st <= S_RD_USE;

        S_RD_USE: begin
            if (!live) begin
                // Readiness: first byte, then last byte of the default table.
                if (k == 6'd0) begin
                    chk_first_ok <= (ram_byte == 8'h53);
                    k <= TABLE_LAST;
                    st <= S_RD;
                end
                else if (chk_first_ok && ram_byte == 8'h75) begin
                    if (!ready_once) begin
                        ready_once <= 1'b1;
                        st <= S_IDLE;
                    end
                    else if (valid) begin
                        k <= 6'd0;
                        st <= S_RESTORE;
                    end
                    else begin
                        live <= 1'b1;
                        st <= S_IDLE;
                    end
                end
                else begin
                    ready_once <= 1'b0;
                    st <= S_IDLE;
                end
            end
            else begin
                // Capture scan.
                if (ram_byte != sh_byte || !valid) begin
                    sh_we <= 1'b1;
                    sh_wk <= k;
                    sh_wdata <= ram_byte;
                    scan_changed <= 1'b1;
                end
                if (k == TABLE_LAST) begin
                    if (scan_changed || ram_byte != sh_byte || !valid) begin
                        valid <= 1'b1;
                        dirty <= 1'b1;
                    end
                    st <= S_IDLE;
                end
                else begin
                    k <= k + 1'b1;
                    st <= S_RD;
                end
            end
        end

        S_RESTORE: begin
            ram_addr  <= k_byte_addr[16:1];
            ram_be    <= k_lane_hi ? 2'b10 : 2'b01;
            ram_wdata <= {sh_byte, sh_byte};
            ram_we    <= 1'b1;
            if (k == TABLE_LAST) begin
                live <= 1'b1;
                st <= S_IDLE;
            end
            else
                k <= k + 1'b1;
        end

        default: st <= S_GUARD;
        endcase
    end
end

endmodule
