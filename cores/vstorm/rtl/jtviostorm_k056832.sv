// K056832 CPU-visible boundary for Violent Storm.
//
// Register and lane behavior follows the pinned MAME 0.289
// k054156_k054157_k056832.cpp implementation.  The renderer is intentionally
// outside this boundary: tile-ROM reads are held until tile_ok and the
// selected-page/bank state is visible to the future line-fetch engine.
module jtviostorm_k056832(
    input             clk,
    input             rst,

    input             reg_cs,
    input             b_cs,
    input             vram_cs,
    input             romrd_cs,
    input             cpu_we,
    input             cpu_rnw,
    input      [4:0]  reg_addr,
    input      [1:0]  b_addr,
    input      [12:1] vram_cpu_addr,
    input      [15:0] cpu_din,
    input      [1:0]  cpu_dsn,
    output reg [15:0] cpu_dout,

    // Physical address is {selected_page[3:0], CPU-window word[11:0]}.
    // The generated JTFRAME BRAM exposes this as vmem_addr[17:1].
    output     [17:1] vram_addr,
    output     [1:0]  vram_we,
    input      [15:0] vram_dout,

    output reg        tile_cs,
    output reg [21:2] tile_addr,
    input      [31:0] tile_data,
    input             tile_ok,
    output            tile_wait,

    output     [4:0]  selected_page,
    output     [8:0]  rom_bank,
    output            mode_5bpp,
    output     [3:0]  layer_page0, layer_page1, layer_page2, layer_page3,
    // Full 16-bit signed scroll registers (MAME stores/combines these as
    // (int16_t)new_data with no masking -- see word_w()/get_tile_info()'s
    // rowscroll/colscroll path). A 10-bit slice wrapped incorrectly for
    // multi-page parallax scroll beyond +-511; see Fix 4 in the evidence
    // ledger (2026-08-18, K056832 5bpp datapath/burst/scale/scroll entry).
    output signed [15:0] layer_dx0, layer_dx1, layer_dx2, layer_dx3,
    output signed [15:0] layer_dy0, layer_dy1, layer_dy2, layer_dy3,
    output     [1:0]  layer_flip0, layer_flip1, layer_flip2, layer_flip3,
    // Global screen flip -- REG0 (word index 0, byte 0x270000) bits 5/4,
    // k054156_k054157_k056832.cpp word_w() case 0x00/2: "if (new_data&0x20)
    // flip|=TILEMAP_FLIPY; if (new_data&0x10) flip|=TILEMAP_FLIPX;" applied
    // to *all* K056832_PAGE_COUNT tilemaps unconditionally (not per-layer).
    // Confirmed reachable: .mister/evidence/mame_k056832_reg5_reg0_usage.json
    // -- normal boot REG0=0x44 (bits 4/5 clear); with cabinet Flip Screen DIP
    // forced + reset, firmware writes REG0=0x74 (bits 4/5 both set) during
    // boot init.
    output            gflip_x, gflip_y,
    // Correction registers used only while the matching global-flip bit is
    // set (tilemap_draw_common(), k054156_k054157_k056832.cpp:1346-1370):
    //   flipy: corr = regs[0x3c/2]; if (corr&0x400) sign-extend from bit10
    //          (11-bit signed, byte addr 0x27003C) -- else corr=0.
    //   flipx: corr = regs[0x3a/2]; if (corr&0x800) sign-extend from bit11
    //          (12-bit signed, byte addr 0x27003A) -- else corr=0.
    // Evidence capture (mame_k056832_reg5_reg0_sprite_evidence_summary.md
    // section 2) found these hold D3/00 whether or not flip is active for
    // viostorm's traced boot -- exposed here pre-sign-extended so the video
    // renderer need not re-derive the mask width.
    output     signed [12:0] corr_x,
    output     signed [11:0] corr_y
);

    reg [15:0] regs [0:31];
    reg [15:0] bregs[0:3];
    integer idx;

    wire [4:0] reg_index = reg_addr;
    wire [1:0] b_index = b_addr;
    wire write_active = cpu_we && !cpu_rnw;

    function [15:0] combine_word;
        input [15:0] old_word;
        input [15:0] new_word;
        input [1:0]  dsn;
        begin
            combine_word = old_word;
            if (!dsn[1]) combine_word[15:8] = new_word[15:8];
            if (!dsn[0]) combine_word[7:0]  = new_word[7:0];
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (idx = 0; idx < 32; idx = idx + 1)
                regs[idx] <= 16'h0000;
            for (idx = 0; idx < 4; idx = idx + 1)
                bregs[idx] <= 16'h0000;
        end else begin
            if (reg_cs && write_active)
                regs[reg_index] <= combine_word(regs[reg_index], cpu_din, cpu_dsn);
            if (b_cs && write_active)
                bregs[b_index] <= combine_word(bregs[b_index], cpu_din, cpu_dsn);
        end
    end

    // The CPU-visible window is one selected 4K-word page.  MAME's
    // change_rambank() selects the unpaged bank (page 16) when external
    // line-scroll is enabled; otherwise bits {4:3,1:0} select one of the
    // sixteen tilemap pages.
    assign selected_page = regs[5'h00][1] ? 5'd16 :
                           {1'b0, regs[5'h19][4:3], regs[5'h19][1:0]};
    // Viostorm's packed tile image is 4 MiB: 512 banks of 0x800
    // 32-bit words.  MAME's non-tile-bank path uses the low nine bits of
    // REG1A for that address; do not truncate bit 8 at the SDRAM boundary.
    assign rom_bank = regs[5'h1a][8:0];
    assign mode_5bpp = (regs[5'h03][7:6] == 2'b11);
    // K056832 layer controls used by the line renderer. Page selectors are
    // the documented 2x2 page-grid fields; scroll values are signed 10-bit
    // register values; flip overrides come from REG1.
    assign layer_page0 = {regs[5'h08][4:3], regs[5'h0c][4:3]};
    assign layer_page1 = {regs[5'h09][4:3], regs[5'h0d][4:3]};
    assign layer_page2 = {regs[5'h0a][4:3], regs[5'h0e][4:3]};
    assign layer_page3 = {regs[5'h0b][4:3], regs[5'h0f][4:3]};
    // Full 16-bit register value, unmasked (see port comment above).
    assign layer_dx0 = regs[5'h14];
    assign layer_dx1 = regs[5'h15];
    assign layer_dx2 = regs[5'h16];
    assign layer_dx3 = regs[5'h17];
    assign layer_dy0 = regs[5'h10];
    assign layer_dy1 = regs[5'h11];
    assign layer_dy2 = regs[5'h12];
    assign layer_dy3 = regs[5'h13];
    assign layer_flip0 = regs[5'h01][1:0];
    assign layer_flip1 = regs[5'h01][3:2];
    assign layer_flip2 = regs[5'h01][5:4];
    assign layer_flip3 = regs[5'h01][7:6];
    assign gflip_x = regs[5'h00][4];
    assign gflip_y = regs[5'h00][5];
    // 12-bit (0x3a) / 11-bit (0x3c) signed correction fields, sign-extended
    // from bit 11 / bit 10 respectively -- see port comment above for the
    // MAME line citations.
    assign corr_x = {regs[5'h1d][11], regs[5'h1d][11:0]};
    assign corr_y = {regs[5'h1e][10], regs[5'h1e][10:0]};
    assign vram_addr = {selected_page, vram_cpu_addr[12:1]};
    assign vram_we = (vram_cs && write_active) ? ~cpu_dsn : 2'b00;

    // Tile ROM readback (POST checksum), matching k056832_device::
    // mw_rom_word_r() (k054156_k054157_k056832.cpp). `offset` there is the
    // CPU's 16-bit-word index into the 0x2000-byte readback window, i.e.
    // vram_cpu_addr[12:1]. Two branches:
    //  - bregs[2]&8 (comment: "we want only the 2s" -- the 5th bit-plane):
    //    bit = offset%4; addr = (offset/4)*5; temp = rombase[addr+4+bank];
    //    then a fixed bit-shuffle of `temp` per `bit`.
    //  - else ("the 0s and 1s" -- the 4 chunky planes): addr = (offset>>1)*5
    //    + (offset&1 ? 2 : 0) + bank; result = rombase[addr]<<8 | rombase[addr+1].
    // `bank` in MAME is 10240*m_cur_gfx_banks bytes (mw_rom_word_r(),
    // k054156_k054157_k056832.cpp:820) -- a bpp-scaled stride (2048 tiles *
    // 5 bytes/row-packed-tile), not the 8192-byte-per-bank scheme used
    // elsewhere in the device. bank_bytes/primary_addr are sized to 23 bits
    // so the *10240 product (max 511*10240=5,232,640) does not truncate
    // internally; the final tile_addr port keeps its existing 20-bit/4MB
    // word-address width (mem.yaml's `tile` SDRAM bus, addr_width 22 bytes,
    // is a generated-wrapper artifact outside this file's edit scope), so
    // the low 20 bits of the computed word address are what actually reach
    // the SDRAM slot -- for bank values whose byte address exceeds the 4MB
    // window this deliberately wraps, matching what an out-of-range bank
    // read against the real, physically-sized ROM would already be (open
    // bus/wrapped, not a value software depends on).
    //
    // rombase[] is byte-addressed; tile_data is a 32-bit/4-byte-word SDRAM
    // port, so a 2-word (8-byte) fetch is made and the needed byte(s) are
    // extracted from that window, matching the video renderer's approach.
    // Each word request holds tile_addr stable for its whole tile_cs/
    // tile_ok handshake (see jtframe_romrq.v's "addr not changed until
    // data_ok" contract): tile_cs is asserted only in RD_W0 (word0, address
    // stable) and RD_W1 (word1, address stable); RD_GAP deasserts tile_cs
    // for one cycle in between so the address change from word0 to word1
    // never happens while cs is asserted.
    localparam RD_IDLE=3'd0, RD_W0=3'd1, RD_GAP=3'd2, RD_W1=3'd3, RD_DONE=3'd4;
    reg [2:0]  rd_st;
    reg [31:0] rd_word0, rd_word1;

    wire [11:0] rd_off    = vram_cpu_addr[12:1];
    wire [22:0] bank_bytes = {5'b0,rom_bank} * 23'd10240;
    wire [15:0] addrA  = {5'b0,rd_off[11:1]} * 16'd5 + (rd_off[0] ? 16'd2 : 16'd0);
    wire [15:0] addrB4 = {6'b0,rd_off[11:2]} * 16'd5 + 16'd4;
    wire [1:0]  plane5_bit  = rd_off[1:0];
    wire [15:0] primary_off = bregs[2][3] ? addrB4 : addrA;
    wire [22:0] primary_addr = bank_bytes + {7'b0,primary_off};
    wire [19:0] word_addr0 = primary_addr[21:2];
    wire [1:0]  byte_off0  = primary_addr[1:0];
    wire [19:0] word_addr1 = word_addr0 + 20'd1;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rd_st <= RD_IDLE;
            rd_word0 <= 32'd0;
            rd_word1 <= 32'd0;
        end else case (rd_st)
            RD_IDLE: if (romrd_cs && cpu_rnw) rd_st <= RD_W0;
            RD_W0: if (tile_ok) begin
                rd_word0 <= tile_data;
                rd_st <= RD_GAP;
            end
            RD_GAP: rd_st <= RD_W1;
            RD_W1: if (tile_ok) begin
                rd_word1 <= tile_data;
                rd_st <= RD_DONE;
            end
            RD_DONE: if (!romrd_cs) rd_st <= RD_IDLE;
            default: rd_st <= RD_IDLE;
        endcase
    end

    always @* begin
        tile_cs   = (rd_st == RD_W0) || (rd_st == RD_W1);
        tile_addr = (rd_st == RD_W1) ? word_addr1 : word_addr0;
    end
    assign tile_wait = romrd_cs && cpu_rnw && (rd_st != RD_DONE);

    // idx spans 0..4 (byte_off0 is 0..3, and the low byte needs +1), so a
    // 3-bit index is required -- a 2-bit index would silently wrap 3+1 to 0.
    function [7:0] byte_at(input [63:0] d, input [2:0] idx);
        byte_at = d[idx*8 +: 8];
    endfunction

    wire [63:0] rd_buf   = {rd_word1,rd_word0};
    wire [7:0]  byte_hi  = byte_at(rd_buf, {1'b0,byte_off0});
    wire [7:0]  byte_lo  = byte_at(rd_buf, {1'b0,byte_off0} + 3'd1);
    reg  [15:0] plane5_res;
    always @* begin
        case (plane5_bit)
            2'd0: plane5_res = ({8'h0,byte_hi} & 16'h0080) << 5 |
                                (({8'h0,byte_hi} & 16'h0040) >> 2);
            2'd1: plane5_res = ({8'h0,byte_hi} & 16'h0020) << 7 |
                                ({8'h0,byte_hi} & 16'h0010);
            2'd2: plane5_res = ({8'h0,byte_hi} & 16'h0008) << 9 |
                                (({8'h0,byte_hi} & 16'h0004) << 2);
            default: plane5_res = ({8'h0,byte_hi} & 16'h0002) << 11 |
                                (({8'h0,byte_hi} & 16'h0001) << 4);
        endcase
    end

    always @* begin
        cpu_dout = 16'hffff; // write-only register windows read as open bus
        if (vram_cs && cpu_rnw)
            cpu_dout = vram_dout;
        else if (romrd_cs && cpu_rnw && rd_st == RD_DONE) begin
            if (bregs[2][3])
                cpu_dout = plane5_res;
            else
                cpu_dout = {byte_hi,byte_lo};
        end
    end
endmodule
