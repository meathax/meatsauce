/*  This file is part of JTFRAME.
    JTFRAME program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JTFRAME program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JTFRAME.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 02-5-2020 */

// Produces the right signals for jtframe_sdram to get the ROM data
// A prom_we signal is used for the second half of the ROM byte stream

// For system simulation, it is useful sometimes to be able to load the
// PROM data quickly at the beginning of the simulation. If the PROM
// modules are isolated, this can be done manually typing the path to
// each rom file in the jtframe_prom instantiation. However, sometimes
// the hierarchy will not allow it or the code may get messy.

/* verilator lint_off WIDTH */
module jtframe_dwnld #(
    parameter        SDRAMW    = 23, // bank size, default = 8MB for 32MB SDRAM
    parameter        SIMFILE   = "rom.bin",
    parameter [26:0] PROM_START= `ifdef JTFRAME_PROM_START `JTFRAME_PROM_START `else ~27'd0 `endif,
    parameter [26:0] BA1_START = ~27'd0,
    parameter [26:0] BA2_START = ~27'd0,
    parameter [26:0] BA3_START = ~27'd0,
    parameter [26:0] HEADER    = `ifdef JTFRAME_HEADER `JTFRAME_HEADER `else 0 `endif,
    parameter [25:0] SWAB      = 0, // swap every pair of input bytes (SDRAM only)
    parameter        GFX8B0    = 0, // bit 0 for HHVVV  sequence
    parameter        GFX16B0   = 0, // bit 0 for HHVVVV sequence
    parameter        BALUT     = 0, // 1 to use the header as the start for banks and PROM sections
                                    // header format: two bytes for the offset of each bank and PROM
    parameter        BALUT_LEN = 5,
    parameter        BALUT_REVERSE = 1, // header offset bytes are low/high when set
    parameter        LUTSH     = 0, // bit shift to apply to ioctl_addr for BALUT comparisons
    parameter        XL        = 0
)(
    input                clk,
    input                ioctl_rom,
    input      [26:0]    ioctl_addr, // max 128 MB
    input      [ 7:0]    ioctl_dout,
    input                ioctl_wr,
    output reg [SDRAMW-1:1] prog_addr,
    output     [15:0]    prog_data,
    output reg [ 1:0]    prog_mask, // active low
    output reg           prog_we,
    output               prog_rd,
    output reg [ 1:0]    prog_ba,

    input                gfx4_en,   //  HVVV  -> VVVH
    input                gfx8_en,   // HHVVV  -> VVVHH
    input                gfx16_en,  // HHVVVV -> VVVVHH
    input                gfx16b_en, // VHHVVV -> VVVVHH
    input                gfx16c_en, //  HVVVV -> VVVVH

    output reg           prom_we,
    output reg           header,
    // Hardware-visible count of download words silently discarded because the
    // internal FIFO was full. Saturates at 255. Any non-zero value after a
    // ROM load means SDRAM contents are corrupt (see the strip-diagnostic
    // overlay in the Escape Kids target). Costs ~9 registers; always present
    // so no ifdef divergence between diagnostic and release builds.
    output reg [ 7:0]    ovfl_cnt = 8'd0,
    input                sdram_ack
);

`ifdef SIMULATION
initial begin
    if( BALUT>3 ) begin
        $display("BALUT must be 0-3");
        $finish;
    end
end
`endif

localparam BA_EN   = BA1_START!=~27'd0 || BA2_START!=~27'd0 || BA3_START!=~27'd0 || BALUT!=0,
           PROM_EN = PROM_START!=~27'd0;
/* verilator lint_on  WIDTH */
reg  [15:0] data_out;
wire        is_prom;
reg  [26:0] part_addr, nohdr_addr;

assign prog_data = data_out;
assign prog_rd   = 0;

function [15:0] header_word;
    input [15:0] raw;
    begin
        header_word = BALUT_REVERSE ? raw : { raw[7:0], raw[15:8] };
    end
endfunction

function [26:0] header_offset;
    input [15:0] raw;
    reg   [15:0] word;
    begin
        word = header_word(raw);
        header_offset = {11'd0, word} << LUTSH;
    end
endfunction

always @(*) begin
    header    = HEADER!=0 && ioctl_addr < HEADER && ioctl_rom;
    nohdr_addr = ioctl_addr-HEADER;
    part_addr  = nohdr_addr;
    if( gfx4_en   ) part_addr[GFX8B0 +:4] = { nohdr_addr[GFX8B0 +:3], nohdr_addr[GFX8B0+3 +:1] }; // HVVV   -> VVVH
    if( gfx8_en   ) part_addr[GFX8B0 +:5] = { nohdr_addr[GFX8B0 +:3], nohdr_addr[GFX8B0+3 +:2] }; // HHVVV  -> VVVHH
    if( gfx16_en  ) part_addr[GFX16B0+:6] = { nohdr_addr[GFX16B0+:4], nohdr_addr[GFX16B0+4+:2] }; // HHVVVV -> VVVVHH
    if( gfx16b_en ) part_addr[GFX16B0+:6] = { nohdr_addr[GFX16B0+5], nohdr_addr[GFX16B0+:3],nohdr_addr[GFX16B0+3+:2] }; // VHHVVV -> VVVVHH
    if( gfx16c_en ) part_addr[GFX16B0+:5] = { nohdr_addr[GFX16B0+:4], nohdr_addr[GFX16B0+4+:1] }; //  HVVVV -> VVVVH
end

`ifdef SIMULATION `ifdef JTFRAME_PROM_START `ifndef LOADROM
    `define SIM_LOAD_PROM
`endif `endif `endif

`ifndef SIM_LOAD_PROM
/////////////////////////////////////////////////
// Normal operation
reg  [ 2:0] bank;
reg  [26:0] offset;
reg  [26:0] eff_addr;
reg [2*9*8-1:0] ba_start=0; // 16 bits per offset
reg        ioctl_wr1=0, ioctl_rom1=0, header1=0;
reg [ 7:0] ioctl_dout1=0;
reg [26:0] part_addr1=0;
wire       use_ioctl_wr, use_ioctl_rom, use_header;
wire [7:0] use_ioctl_dout;
wire [26:0] use_part_addr;
wire [ 7:0] balut_bit_addr = { ioctl_addr[4:0], 3'b000 };
wire [SDRAMW-1:1] nx_prog_addr = XL ? { bank[2], eff_addr[SDRAMW-2:1] } : eff_addr[SDRAMW-1:1];
wire [ 1:0] nx_prog_mask = (eff_addr[0]^SWAB[0]) ? 2'b10 : 2'b01;
wire [ 1:0] nx_prog_ba   = bank[1:0];

initial begin
    prog_addr = 0;
    prog_ba   = 0;
    prog_mask = 2'b11;
    prog_we   = 0;
    prom_we   = 0;
    bank      = 0;
    offset    = 0;
    eff_addr  = 0;
    data_out  = 0;
end

assign use_ioctl_wr   = ioctl_wr1;
assign use_ioctl_rom  = ioctl_rom1;
assign use_ioctl_dout = ioctl_dout1;
assign use_header     = header1;
assign use_part_addr  = part_addr1;

always @(posedge clk) begin
    ioctl_wr1   <= ioctl_wr;
    ioctl_rom1  <= ioctl_rom;
    ioctl_dout1 <= ioctl_dout;
    header1     <= header;
    part_addr1  <= part_addr;
end

always @(*) begin
    case( bank )
        3'd0: offset = 0;
        3'd1: offset = BALUT==0 ? BA1_START : header_offset(ba_start[16+:16]);
        3'd2: offset = BALUT==0 ? BA2_START : header_offset(ba_start[32+:16]);
        3'd3: offset = BALUT==0 ? BA3_START : header_offset(ba_start[48+:16]);
        3'd4: offset = XL && BALUT!=0 ? header_offset(ba_start[64+:16]) : 27'd0;
        3'd5: offset = XL && BALUT!=0 ? header_offset(ba_start[80+:16]) : 27'd0;
        3'd6: offset = XL && BALUT!=0 ? header_offset(ba_start[96+:16]) : 27'd0;
        3'd7: offset = XL && BALUT!=0 ? header_offset(ba_start[112+:16]) : 27'd0;
        default: offset = 0;
    endcase // bank
    eff_addr = use_part_addr-offset;
end

generate
    if( BALUT==0 || !BA_EN ) begin
        always @(use_part_addr) begin
            bank = !BA_EN ? 3'd0 : ( /* verilator lint_off UNSIGNED */
                    use_part_addr >= BA3_START ? 3'd3 : (
                    use_part_addr >= BA2_START ? 3'd2 : (
                    use_part_addr >= BA1_START ? 3'd1 : 3'd0 ))); /* verilator lint_on UNSIGNED */
        end
        assign is_prom = PROM_EN && use_part_addr>=PROM_START;
    end else begin
        // header table containing each bank start offset shifted by LUTSH bits
        always @(posedge clk) begin
            if ( ioctl_wr && ioctl_rom && header && ioctl_addr[6:0]<(BALUT_LEN<<1) ) begin
                ba_start[balut_bit_addr+:8] <= ioctl_dout;
            end
        end
        /* verilator lint_off WIDTHEXPAND */
        always @* begin
            bank = 0;
            if( use_part_addr >= header_offset(ba_start[16+:16]) ) bank = 1;
            if( use_part_addr >= header_offset(ba_start[32+:16]) ) bank = 2;
            if( use_part_addr >= header_offset(ba_start[48+:16]) ) bank = 3;
            if( XL && BALUT_LEN>4 && use_part_addr >= header_offset(ba_start[64+:16]) ) bank = 4;
            if( XL && BALUT_LEN>5 && use_part_addr >= header_offset(ba_start[80+:16]) ) bank = 5;
            if( XL && BALUT_LEN>6 && use_part_addr >= header_offset(ba_start[96+:16]) ) bank = 6;
            if( XL && BALUT_LEN>7 && use_part_addr >= header_offset(ba_start[112+:16]) ) bank = 7;
        end
        assign is_prom = (!XL && BALUT_LEN>4 && use_part_addr >= header_offset(ba_start[64+:16])) ||
                         ( XL && BALUT_LEN>8 && use_part_addr >= header_offset(ba_start[128+:16]));
        /* verilator lint_on WIDTHEXPAND */
    end
endgenerate

// The single pending register that used to sit here silently overwrote a
// queued word whenever a second ioctl write arrived while the SDRAM write
// was still un-acked, and nothing throttles the HPS (ioctl_wait is tied to
// the DDR dump path only).  Every SDRAM stall longer than one ioctl beat -
// a refresh burst, a row miss, a bank conflict - therefore dropped download
// bytes, leaving those SDRAM words holding stale contents.  Queue the words
// instead so a stall is absorbed rather than discarded.
//
// Byte pairing. The HPS delivers one byte per ioctl write. Writing each byte
// on its own needs the SDRAM byte masks (DQML/DQMH) to protect the other
// lane, and on real hardware the masked lane of the second write of a pair
// was seen to be stored anyway: the low byte of a 16-bit word ended up equal
// to its high byte (Escape Kids, 8x1 tile strips, decoded from screenshots
// on 2026-09-03; the chip-model bench cannot reproduce it because the RTL
// drives the mask correctly and the failure is at the pins). Rather than
// depend on DQM timing at all, hold the first byte of every 16-bit word and
// issue one unmasked full-word write when its partner arrives. The masks are
// then never asserted during programming, so a marginal mask cannot unmask
// or mask anything. A byte without a partner (a stream that ends on an odd
// length, an address jump, a PROM byte, end of download) is flushed alone
// with its own mask, so the general contract is unchanged.
localparam FIFOAW = 6;   // 64 entries, enough for a full refresh burst
localparam FIFODW = (SDRAMW-1) + 16 + 2 + 2;

reg  [FIFODW-1:0] fifo[0:(1<<FIFOAW)-1];
reg  [FIFOAW:0]   fifo_wptr, fifo_rptr;
wire [FIFOAW:0]   fifo_used  = fifo_wptr - fifo_rptr;
wire              fifo_empty = fifo_wptr == fifo_rptr;
wire              fifo_full  = fifo_used == (1<<FIFOAW);
wire [FIFODW-1:0] fifo_dout  = fifo[fifo_rptr[FIFOAW-1:0]];
wire              new_word   = use_ioctl_wr && use_ioctl_rom && !use_header && !is_prom;
wire              new_prom   = use_ioctl_wr && use_ioctl_rom && !use_header && is_prom;
// A write slot is free when nothing is outstanding, or the outstanding one
// is being acknowledged this cycle.
wire              slot_free  = !prog_we || sdram_ack;

// first byte of a word, waiting for its partner
reg               half_v;
reg  [SDRAMW-1:1] half_addr;
reg  [ 7:0]       half_data;
reg  [ 1:0]       half_mask, half_ba;
wire              half_match = half_v && half_addr==nx_prog_addr &&
                               half_ba==nx_prog_ba && half_mask!=nx_prog_mask;
// dsn is active low: 2'b10 means the low lane is written
wire [15:0]       pair_data  = half_mask==2'b10 ? { use_ioctl_dout, half_data } :
                                                  { half_data, use_ioctl_dout };
wire              push_pair  = new_word && half_match;
wire              push_half  = half_v && ( !use_ioctl_rom || new_prom || (new_word && !half_match) );
wire              push       = push_pair || push_half;
wire [FIFODW-1:0] fifo_din   = push_pair ?
        { nx_prog_addr, pair_data,     2'b00,     nx_prog_ba } :
        { half_addr,    {2{half_data}}, half_mask, half_ba    };

`ifdef SIMULATION
integer fifo_ovfl = 0;
always @(posedge clk) if( push && fifo_full && !(slot_free && fifo_empty) )
    fifo_ovfl <= fifo_ovfl + 1;
`endif

// Same drop condition as the simulation counter above, kept in hardware so
// real boards can report it (fifo_full implies !fifo_empty, so the guard
// reduces to push && fifo_full).
always @(posedge clk)
    if( push && fifo_full && ovfl_cnt != 8'hff )
        ovfl_cnt <= ovfl_cnt + 8'd1;

task issue_from_fifo; begin
    { prog_addr, data_out, prog_mask, prog_ba } <= fifo_dout;
    prog_we   <= 1;
    prom_we   <= 0;
    fifo_rptr <= fifo_rptr + 1'd1;
end endtask

initial begin
    fifo_wptr = 0;
    fifo_rptr = 0;
    half_v    = 0;
    half_addr = 0;
    half_data = 0;
    half_mask = 2'b11;
    half_ba   = 0;
end

always @(posedge clk) begin
    // ---- enqueue side
    if( push && !fifo_full ) begin
        fifo[fifo_wptr[FIFOAW-1:0]] <= fifo_din;
        fifo_wptr <= fifo_wptr + 1'd1;
    end

    // ---- pairing register
    if( new_word ) begin
        if( half_match ) begin
            half_v <= 0;
        end else begin
            // the previous half, if any, is flushed by push_half this cycle
            half_v    <= 1;
            half_addr <= nx_prog_addr;
            half_data <= use_ioctl_dout;
            half_mask <= nx_prog_mask;
            half_ba   <= nx_prog_ba;
        end
    end else if( push_half ) begin
        half_v <= 0;
    end

    // ---- PROM writes bypass the SDRAM path entirely
    if( new_prom ) begin
        prog_addr <= use_part_addr[SDRAMW-2:0];
        prom_we   <= 1;
        prog_we   <= 0;
        data_out  <= {2{use_ioctl_dout}};
        prog_mask <= nx_prog_mask;
    end else if( slot_free ) begin
        // ---- dequeue side: start the next queued word, or go idle.
        // Every SDRAM-bound word travels through the queue, so a word pushed
        // this cycle is issued on the next one.
        if( !fifo_empty ) begin
            issue_from_fifo;
        end else begin
            prog_we <= 0;
            prom_we <= 0;
        end
    end else if( prog_we ) begin
        prom_we <= 0;
    end
end

`else
////////////////////////////////////////////////////////
// Load only PROMs directly from file in simulation
/* verilator lint_off WIDTH */

parameter [31:0] GAME_ROM_LEN = `GAME_ROM_LEN;

integer          f, readcnt, dumpcnt;
reg       [ 7:0] mem[0:`GAME_ROM_LEN];

initial prog_ba=0;

// This is only executed if JTFRAME_PROM_START was defined
initial begin
    dumpcnt = PROM_START+HEADER;
    if( SIMFILE != "" && (PROM_EN||BALUT==1) ) begin
        f=$fopen(SIMFILE,"rb");
        if( f != 0 ) begin
            readcnt=$fread( mem, f );
            $display("INFO: PROM download: %6X bytes loaded from file (%s)", readcnt, SIMFILE);
            $fclose(f);
            if( BALUT==1 ) begin
                dumpcnt=header_offset({mem[9],mem[8]});
            end
            if( dumpcnt >= readcnt ) begin
                $display("WARNING: PROM_START (%X) is set beyond the end of the file (%X)", PROM_START, dumpcnt);
                $display("         GAME_ROM_LEN=%X",GAME_ROM_LEN);
            end else begin
                $display("INFO: fast PROM download from %X to %X", dumpcnt, GAME_ROM_LEN);
            end
        end else begin
            $display("WARNING: %m cannot open %s", SIMFILE);
            dumpcnt = GAME_ROM_LEN; // stop the download process
        end
    end else begin
        $display("INFO: PROM download skipped because PROM_START was not defined.");
    end
end

// The PROM starts ioctl_rom after the header section is over
reg start_ok=0;
initial prog_we=0;

always @(posedge clk) begin
    if( ioctl_rom ) start_ok<=1;
    if( dumpcnt < GAME_ROM_LEN && start_ok && !header) begin
        prom_we   <= 1;
        prog_we   <= 0;
        prog_mask <= 2'b11;
        data_out  <= {2{mem[dumpcnt]}};
        prog_addr <= dumpcnt[SDRAMW-2:0]-HEADER;
        dumpcnt   <= dumpcnt+1;
    end else begin
        prom_we <= 0;
    end
end
/* verilator lint_on WIDTH */
`endif

endmodule
