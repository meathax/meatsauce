// SPDX-License-Identifier: GPL-3.0-or-later
// GX857 decode follows MAME 0.289 src/mame/konami/spy.cpp main_map.
module spy_bus (
    input logic clk, reset, pause, transfer, rnw,
    input logic [15:0] addr,
    input logic [7:0] dout,
    output logic [7:0] din,
    output wire ready,

    output wire rom_cs,
    output wire [17:0] rom_addr,
    input logic [7:0] rom_dout,
    input logic rom_ok,

    output wire work_cs, work_we,
    output wire [12:0] work_addr,
    input logic [7:0] work_dout,
    output wire pal_cs, pal_we,
    input logic [7:0] pal_dout,
    output wire pmc_cs, pmc_we,
    input logic [7:0] pmc_dout,

    output wire tile_cs, obj_cs, gfx_we,
    output wire [13:0] gfx_addr,
    input logic [7:0] tile_dout, obj_dout,
    input logic tile_ok,
    input logic [7:0] system_in, p1_in, p2_in, dip1, dip2,

    output logic [7:0] sound_latch,
    output logic sound_irq, watchdog_reset,
    output wire rmrd, pmc_bk, pmc_start,
    output logic video_enable,
    output wire [1:0] coin_counter,
    output wire [3:0] rom_bank,
    output wire [7:0] control_state
);
    logic [3:0] bank;
    logic [7:0] control;
    wire writing = transfer && !rnw && !reset && !pause;
    wire palette_overlay = addr < 16'h0800 && control[4];
    wire pmc_overlay = addr < 16'h0800 && !control[4] && control[5];
    wire write_io = !rnw && (addr == 16'h3f80 || addr == 16'h3f90 ||
                         addr == 16'h3fa0 || addr == 16'h3fb0 || addr == 16'h3fc0);
    wire read_io = rnw && (addr == 16'h3fd0 || addr == 16'h3fd1 ||
                         addr == 16'h3fd2 || addr == 16'h3fd3 || addr == 16'h3fe0);
    wire gfx_selected = addr >= 16'h2000 && addr <= 16'h5fff && !write_io && !read_io;
    wire sprite_selected = (addr >= 16'h5800 && addr <= 16'h5807) ||
                           (addr >= 16'h5c00 && addr <= 16'h5fff);

    assign rom_cs = !reset && rnw && addr >= 16'h6000;
    assign rom_addr = addr[15] ? {2'b00, addr} :
                      18'h10000 + {1'b0, bank, 13'b0} + {5'b0, addr[12:0]};
    assign work_cs = !reset && addr < 16'h1b00 && !palette_overlay && !pmc_overlay;
    assign pal_cs = !reset && palette_overlay;
    assign pmc_cs = !reset && pmc_overlay;
    assign work_addr = addr[12:0];
    assign work_we = writing && work_cs;
    assign pal_we = writing && pal_cs;
    assign pmc_we = writing && pmc_cs;
    // RMRD redirects sprite reads, but never sprite writes, to K052109 ROM.
    assign obj_cs = !reset && gfx_selected && sprite_selected && (!rnw || !rmrd);
    assign tile_cs = !reset && gfx_selected && !obj_cs;
    assign gfx_we = writing && (tile_cs || obj_cs);
    assign gfx_addr = addr[13:0] - 14'h2000;
    // ROM acknowledgements qualify reads. A write never consumes ROM data.
    assign ready = !rnw || (rom_cs ? rom_ok : tile_cs ? tile_ok : 1'b1);
    assign rmrd = control[2];
    assign pmc_start = control[6];
    assign pmc_bk = control[7];
    assign coin_counter = control[1:0];
    assign rom_bank = bank;
    assign control_state = control;

    always_comb begin
        din = 8'hff;
        if (rom_cs) din = rom_dout;
        else if (work_cs) din = work_dout;
        else if (pal_cs) din = pal_dout;
        else if (pmc_cs) din = pmc_dout;
        else if (obj_cs) din = obj_dout;
        else if (tile_cs) din = tile_dout;
        else if (read_io) begin
            case (addr)
                16'h3fd0: din = system_in;
                16'h3fd1: din = p1_in;
                16'h3fd2: din = p2_in;
                16'h3fd3: din = dip1;
                16'h3fe0: din = dip2;
                default: din = 8'hff;
            endcase
        end
    end
    always_ff @(posedge clk) begin
        sound_irq <= 0;
        watchdog_reset <= 0;
        if (reset) begin
            bank <= 0;
            control <= 0;
            sound_latch <= 0;
            video_enable <= 0;
        end else if (writing) begin
            case (addr)
                16'h3f80: bank <= dout[4] ? {2'b10, dout[2:1]} : {1'b0, dout[3:1]};
                16'h3f90: begin control <= dout; video_enable <= !dout[3]; end
                16'h3fa0: watchdog_reset <= 1;
                16'h3fb0: sound_latch <= dout;
                16'h3fc0: sound_irq <= 1;
                default: ;
            endcase
        end
    end
endmodule
