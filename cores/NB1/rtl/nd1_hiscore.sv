//------------------------------------------------------------------------------
// High-score save for the ND-1 (MiSTer layer). The games keep their score tables in
// the 68000/H8 shared RAM (not in the EEPROM), so the table is saved alongside the
// EEPROM in one NVRAM file:  bytes 0-2047 EEPROM, 2048-3071 score table.
//
// Per-game table location comes from the MRA (ioctl index 3, 6 bytes, as MAME
// hiscore.dat): start offset in shared RAM [15:0] (big-endian), length [15:0],
// start marker byte, end marker byte. The table is only touched once the game has
// initialised it (first byte == start marker and last byte == end marker), which on
// the ND-1 happens after each game's attract demo has run once (hiscore.dat note).
//
//  restore  : a loaded table (a file of at least 2048 + length bytes) is written into
//             shared RAM once, the first time the RAM markers become valid after reset
//  snapshot : the RAM table is copied into the buffer every 60 frames once it is valid
//             (after the restore, if one is pending), and again at the start of an
//             NVRAM upload (ioctl_wait held while copying)
//
// RAM access is through a level-request / one-cycle-ack port that ncv1_core arbitrates
// onto the shared RAM's H8 side (the H8 waits for its ack meanwhile).
//------------------------------------------------------------------------------
`default_nettype none

module nd1_hiscore (
    input  wire         clk,
    input  wire         reset,          // machine reset (restore re-arms on every reset)

    input  wire         ioctl_download,
    input  wire         ioctl_upload,
    input  wire         ioctl_wr,
    input  wire  [24:0] ioctl_addr,
    input  wire   [7:0] ioctl_dout,
    input  wire   [7:0] ioctl_index,
    output wire   [7:0] hs_din,         // upload data for addresses >= 2048
    output reg          ioctl_wait,

    input  wire         vblank,

    output reg   [15:1] ram_addr,
    output reg          ram_req,
    output reg    [1:0] ram_we,
    output reg   [15:0] ram_wdata,
    input  wire  [15:0] ram_q,
    input  wire         ram_ack
);
    // ---------------------------------------------------------------- configuration (index 3)
    reg [15:0] cfg_start = 16'd0, cfg_len = 16'd0;
    reg  [7:0] cfg_sv = 8'd0, cfg_ev = 8'd0;
    always @(posedge clk)
        if (ioctl_download && ioctl_wr && ioctl_index == 8'd3)
            case (ioctl_addr[2:0])
                3'd0: cfg_start[15:8] <= ioctl_dout;
                3'd1: cfg_start[7:0]  <= ioctl_dout;
                3'd2: cfg_len[15:8]   <= ioctl_dout;
                3'd3: cfg_len[7:0]    <= ioctl_dout;
                3'd4: cfg_sv          <= ioctl_dout;
                3'd5: cfg_ev          <= ioctl_dout;
                default: ;
            endcase
    wire        cfg_ok = cfg_len != 16'd0 && cfg_len <= 16'd1024;
    wire [15:0] cfg_endoff = cfg_start + cfg_len - 16'd1;

    // ---------------------------------------------------------------- 1 KB table buffer
    reg  [7:0] buf_mem [1024];
    reg  [9:0] b_waddr;  reg [7:0] b_wdata;  reg b_we;
    reg  [9:0] b_raddr;  reg [7:0] b_q;
    always @(posedge clk) begin
        if (b_we) buf_mem[b_waddr] <= b_wdata;
        b_q <= buf_mem[b_raddr];
    end

    wire nv_dl = ioctl_download && ioctl_index == 8'd4;
    wire nv_ul = ioctl_upload   && ioctl_index == 8'd4;
    wire in_tbl = ioctl_addr[24:11] == 14'd1;             // 2048 .. 4095
    assign hs_din = b_q;

    // the downloaded file holds a complete table (its markers are NOT checked: a new
    // high score rewrites the first byte, e.g. Vol.1 0x07 -> 0x13; MAME's plugin only
    // checks the RAM markers too)
    reg file_tbl = 1'b0;
    wire [9:0] dl_off = ioctl_addr[9:0];

    // ---------------------------------------------------------------- engine
    localparam S_IDLE = 4'd0, S_CHK_S = 4'd1, S_CHK_E = 4'd2, S_RD = 4'd3, S_RD_W = 4'd4,
               S_WR_FETCH = 4'd5, S_WR_BUF = 4'd6, S_WR = 4'd7, S_WR_W = 4'd8, S_DONE_R = 4'd9;
    reg  [3:0] st = S_IDLE;
    reg        restore_pending = 1'b0, restore_done = 1'b0;
    reg        want_snap = 1'b0, mark_s = 1'b0;
    reg        tbl_ok = 1'b0;       // RAM table seen initialised since reset: snapshots skip the marker check
    reg [15:0] idx;                 // byte index into the table
    reg  [5:0] frame_cnt = 6'd0;
    reg        vb_d = 1'b0, ul_d = 1'b0, dl_d = 1'b0;
    reg        going_restore;
    wire [15:0] cur = cfg_start + idx;

    always @(posedge clk) begin
        b_we <= 1'b0;
        vb_d <= vblank;
        ul_d <= nv_ul;
        dl_d <= nv_dl;
        if (nv_dl && !dl_d) file_tbl <= 1'b0;                 // a new NVRAM file: no table until it arrives

        // host side: NVRAM download into the buffer, upload read address
        if (nv_dl && ioctl_wr && in_tbl) begin
            b_waddr <= dl_off; b_wdata <= ioctl_dout; b_we <= 1'b1;
            if (dl_off == 10'd0)                   file_tbl <= 1'b0;
            if ({6'd0, dl_off} == cfg_len - 16'd1) file_tbl <= 1'b1;
        end
        if (st == S_IDLE) b_raddr <= ioctl_addr[9:0];

        if (reset) begin
            st <= S_IDLE; ram_req <= 1'b0; ioctl_wait <= 1'b0;
            restore_pending <= cfg_ok && file_tbl;
            restore_done <= 1'b0; want_snap <= 1'b0; frame_cnt <= 6'd0; tbl_ok <= 1'b0;
        end else begin
            if (vblank && !vb_d) begin
                frame_cnt <= frame_cnt + 6'd1;
                if (frame_cnt == 6'd59) want_snap <= 1'b1;
            end
            if (nv_ul && !ul_d) begin want_snap <= 1'b1; ioctl_wait <= 1'b1; end

            case (st)
            S_IDLE: if (cfg_ok && want_snap && !restore_pending && tbl_ok) begin
                        idx <= 16'd0; st <= S_RD;                              // table known valid: copy
                    end else if (cfg_ok && ((restore_pending && vblank && !vb_d) || (want_snap && !restore_pending))) begin
                        // check the RAM markers first
                        ram_addr <= cfg_start[15:1]; ram_we <= 2'b00; ram_req <= 1'b1; st <= S_CHK_S;
                    end else if (want_snap && restore_pending && !(vblank && !vb_d)) begin
                        want_snap <= 1'b0; ioctl_wait <= 1'b0;   // table not restored yet: keep the loaded copy
                    end
            S_CHK_S: if (ram_ack) begin
                        ram_req <= 1'b0;
                        mark_s  <= (cfg_start[0] ? ram_q[7:0] : ram_q[15:8]) == cfg_sv;
                        ram_addr <= cfg_endoff[15:1]; st <= S_CHK_E;
                    end
            S_CHK_E: if (!ram_req && !ram_ack) ram_req <= 1'b1;
                     else if (ram_ack) begin
                        ram_req <= 1'b0; idx <= 16'd0;
                        if (mark_s && (cfg_endoff[0] ? ram_q[7:0] : ram_q[15:8]) == cfg_ev) begin
                            going_restore <= restore_pending; tbl_ok <= 1'b1;
                            st <= restore_pending ? S_WR_FETCH : S_RD;
                        end else begin
                            // not initialised yet: try again later
                            if (!restore_pending) begin want_snap <= 1'b0; ioctl_wait <= 1'b0; end
                            st <= S_IDLE;
                        end
                     end
            // snapshot: RAM -> buffer, byte by byte
            S_RD:    begin ram_addr <= cur[15:1]; ram_we <= 2'b00; ram_req <= 1'b1; st <= S_RD_W; end
            S_RD_W:  if (ram_ack) begin
                        ram_req <= 1'b0;
                        b_waddr <= idx[9:0]; b_wdata <= cur[0] ? ram_q[7:0] : ram_q[15:8]; b_we <= 1'b1;
                        if (idx == cfg_len - 16'd1) begin want_snap <= 1'b0; ioctl_wait <= 1'b0; st <= S_IDLE; end
                        else begin idx <= idx + 16'd1; st <= S_RD; end
                     end
            // restore: buffer -> RAM, byte by byte
            S_WR_FETCH: begin b_raddr <= idx[9:0]; st <= S_WR_BUF; end
            S_WR_BUF:   st <= S_WR;                                   // b_q valid next clock
            S_WR:    begin
                        ram_addr <= cur[15:1]; ram_we <= cur[0] ? 2'b01 : 2'b10;
                        ram_wdata <= {b_q, b_q}; ram_req <= 1'b1; st <= S_WR_W;
                     end
            S_WR_W:  if (ram_ack) begin
                        ram_req <= 1'b0; ram_we <= 2'b00;
                        if (idx == cfg_len - 16'd1) st <= S_DONE_R;
                        else begin idx <= idx + 16'd1; st <= S_WR_FETCH; end
                     end
            S_DONE_R: begin restore_pending <= 1'b0; restore_done <= 1'b1; st <= S_IDLE; end
            default: st <= S_IDLE;
            endcase
        end
    end
    wire _unused = &{1'b0, restore_done, going_restore};
endmodule
