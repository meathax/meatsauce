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
    output     [1:0]  layer_x0, layer_x1, layer_x2, layer_x3,
    output     [1:0]  layer_y0, layer_y1, layer_y2, layer_y3,
    output     [1:0]  layer_w0, layer_w1, layer_w2, layer_w3,
    output     [1:0]  layer_h0, layer_h1, layer_h2, layer_h3,
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
            // Compile-time reset iterators have no value outside their loop.
            for (integer reset_reg = 0; reset_reg < 32; reset_reg = reset_reg + 1)
                regs[reset_reg] <= 16'h0000;
            for (integer reset_breg = 0; reset_breg < 4; reset_breg = reset_breg + 1)
                bregs[reset_breg] <= 16'h0000;
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
    // Metamorphic's K056832 region is 0x500000 bytes = 640 logical 0x2000-byte
    // MAME banks. change_rombank() uses the full 32-bit value REG1A | REG1B<<16
    // and then modulo 640. The FPGA stream removes the unused fifth plane, so
    // each logical bank occupies 0x800 32-bit words, but bank selection must
    // still follow the ASIC/MAME modulo rule (not simply REG1A[8:0]).
    // Do not place a 32-bit `% 640` divider/modulo in the live ROM-address path.
    // That implementation produced a ~57 ns register-to-SDRAM path in TimeQuest.
    // Recompute the MAME bank modulo iteratively only when either source register
    // changes, then hold the result stable for ROM transactions.
    reg  [9:0]  rom_bank_mod_r;
    reg  [31:0] bank_work;
    reg  [9:0]  bank_rem;
    reg  [5:0]  bank_count;
    reg         bank_calc_busy;
    wire [10:0] bank_rem_shift = {bank_rem, bank_work[31]};
    wire [10:0] bank_rem_next  = (bank_rem_shift >= 11'd640) ?
                                  (bank_rem_shift - 11'd640) : bank_rem_shift;
    assign rom_bank = rom_bank_mod_r[8:0];

    // 32-cycle restoring modulo engine. A K056832 ROM read is held off while
    // the bank value is being refreshed, so the SDRAM sees only a registered,
    // stable bank address.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rom_bank_mod_r <= 10'd0;
            bank_work      <= 32'd0;
            bank_rem       <= 10'd0;
            bank_count     <= 6'd0;
            bank_calc_busy <= 1'b0;
        end else begin
            if (reg_cs && write_active && (reg_index == 5'h1a || reg_index == 5'h1b)) begin
                // MAME change_rombank(): REG1A | (REG1B << 16). B3 is not
                // the high bank word; the B-register window controls read mode.
                bank_work <= (reg_index == 5'h1a) ?
                    {regs[5'h1b], combine_word(regs[5'h1a], cpu_din, cpu_dsn)} :
                    {combine_word(regs[5'h1b], cpu_din, cpu_dsn), regs[5'h1a]};
                bank_rem       <= 10'd0;
                bank_count     <= 6'd0;
                bank_calc_busy <= 1'b1;
            end else if (bank_calc_busy) begin
                bank_work  <= {bank_work[30:0],1'b0};
                bank_rem   <= bank_rem_next[9:0];
                bank_count <= bank_count + 6'd1;
                if (bank_count == 6'd31) begin
                    rom_bank_mod_r <= bank_rem_next[9:0];
                    bank_calc_busy <= 1'b0;
                end
            end
        end
    end

    assign mode_5bpp = (regs[5'h03][7:6] == 2'b11);
    // K056832 layer controls used by the line renderer. Page selectors are
    // the documented 2x2 page-grid fields; scroll values are signed 10-bit
    // register values; flip overrides come from REG1.
    assign layer_page0 = {regs[5'h08][4:3], regs[5'h0c][4:3]};
    assign layer_page1 = {regs[5'h09][4:3], regs[5'h0d][4:3]};
    assign layer_page2 = {regs[5'h0a][4:3], regs[5'h0e][4:3]};
    assign layer_page3 = {regs[5'h0b][4:3], regs[5'h0f][4:3]};
    // MAME K056832 page rectangle: regs 08-0E encode Ystart in [4:3] and H in [1:0];
    // regs 18-1E encode Xstart in [4:3] and W in [1:0].
    assign layer_y0=regs[5'h08][4:3]; assign layer_h0=regs[5'h08][1:0];
    assign layer_y1=regs[5'h09][4:3]; assign layer_h1=regs[5'h09][1:0];
    assign layer_y2=regs[5'h0a][4:3]; assign layer_h2=regs[5'h0a][1:0];
    assign layer_y3=regs[5'h0b][4:3]; assign layer_h3=regs[5'h0b][1:0];
    assign layer_x0=regs[5'h0c][4:3]; assign layer_w0=regs[5'h0c][1:0];
    assign layer_x1=regs[5'h0d][4:3]; assign layer_w1=regs[5'h0d][1:0];
    assign layer_x2=regs[5'h0e][4:3]; assign layer_w2=regs[5'h0e][1:0];
    assign layer_x3=regs[5'h0f][4:3]; assign layer_w3=regs[5'h0f][1:0];
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

    // Tile ROM readback (POST checksum), mw_rom_word_r() in MAME. MAME's tile
    // region keeps 5 bytes per 8-pixel row (bytes 0-3 loaded, byte 4 erased);
    // the FPGA stream stores only the four loaded bytes, one 32-bit word per
    // row group. Bank = 2048 groups. In plane-5 mode (bregs[2][3]) MAME reads
    // the erased byte, so the result is zero. Otherwise offset[0] picks the
    // byte pair {0,1} or {2,3} of the group word, high byte first.
    localparam RD_IDLE=2'd0, RD_W0=2'd1, RD_DONE=2'd2;
    reg [1:0]  rd_st;
    reg [31:0] rd_word;

    wire [11:0] rd_off = vram_cpu_addr[12:1];

    // mw_rom_word_r() uses a 0x2800-byte logical stride for this 5-byte
    // graphics format.  The private MiSTer stream drops the erased fifth byte,
    // so each populated bank is exactly 0x2000 physical bytes.  Metamorphic's
    // two 1 MiB source ROMs populate banks 0..255; later logical banks are the
    // erased tail of the MAME region and must read as zero, never into LVC data.
    wire rom_bank_has_data = (rom_bank_mod_r < 10'd256);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rd_st   <= RD_IDLE;
            rd_word <= 32'd0;
        end else case (rd_st)
            RD_IDLE: if (romrd_cs && cpu_rnw && !bank_calc_busy) begin
                if (rom_bank_has_data)
                    rd_st <= RD_W0;
                else begin
                    rd_word <= 32'd0;
                    rd_st   <= RD_DONE;
                end
            end
            RD_W0: if (tile_ok) begin
                rd_word <= tile_data;
                rd_st   <= RD_DONE;
            end
            RD_DONE: if (!romrd_cs) rd_st <= RD_IDLE;
            default: rd_st <= RD_IDLE;
        endcase
    end

    always @* begin
        tile_cs   = (rd_st == RD_W0);
        // 256 populated banks * 0x800 32-bit words = the 2 MiB tile slot.
        // Keep the leading zero explicit so no bank can address the following
        // K053250 slot even if software selects an erased logical bank.
        tile_addr = {1'b0, rom_bank_mod_r[7:0], rd_off[11:1]};
    end
    assign tile_wait = romrd_cs && cpu_rnw && (bank_calc_busy || (rd_st != RD_DONE));

    wire [15:0] rom_pair = rd_off[0] ? {rd_word[23:16], rd_word[31:24]}
                                     : {rd_word[7:0],   rd_word[15:8]};

    always @* begin
        cpu_dout = 16'hffff; // write-only register windows read as open bus
        if (vram_cs && cpu_rnw)
            cpu_dout = vram_dout;
        else if (romrd_cs && cpu_rnw && rd_st == RD_DONE)
            cpu_dout = bregs[2][3] ? 16'h0000 : rom_pair;
    end
endmodule
