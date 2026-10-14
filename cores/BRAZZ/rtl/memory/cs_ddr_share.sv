// SPDX-License-Identifier: GPL-3.0-or-later
// Fair command ownership between the board ROM port and rotation writes.
// Retain selection through BUSY; finish each read burst before another command.
module cs_ddr_share (
    input logic clk, reset,
    input logic board_rd, board_we,
    input logic [28:0] board_addr,
    input logic [7:0] board_burst, board_be,
    input logic [63:0] board_din,
    output logic board_busy,
    input logic rotate_we,
    input logic [28:0] rotate_addr,
    input logic [7:0] rotate_be,
    input logic [63:0] rotate_din,
    output logic rotate_busy,
    input logic DDRAM_BUSY, DDRAM_DOUT_READY,
    output logic DDRAM_RD, DDRAM_WE,
    output logic [28:0] DDRAM_ADDR,
    output logic [7:0] DDRAM_BURSTCNT, DDRAM_BE,
    output logic [63:0] DDRAM_DIN
);
    logic locked, owner_rotate, prefer_rotate;
    logic [7:0] read_remaining;
    logic select_rotate;
    wire board_request=board_rd || board_we;
    wire command=DDRAM_RD || DDRAM_WE;
    always_comb begin
        select_rotate=locked ? owner_rotate :
            (rotate_we && (!board_request || prefer_rotate));
        board_busy=reset || read_remaining!=0 || select_rotate || DDRAM_BUSY;
        rotate_busy=reset || read_remaining!=0 || !select_rotate || DDRAM_BUSY;
        DDRAM_RD=!reset && read_remaining==0 && !select_rotate && board_rd;
        DDRAM_WE=!reset && read_remaining==0 &&
                 (select_rotate ? rotate_we : board_we);
        DDRAM_ADDR=select_rotate ? rotate_addr : board_addr;
        DDRAM_BURSTCNT=select_rotate ? 8'd1 : board_burst;
        DDRAM_BE=select_rotate ? rotate_be : board_be;
        DDRAM_DIN=select_rotate ? rotate_din : board_din;
    end
    always_ff @(posedge clk) begin
        if(reset) begin
            locked<=0;owner_rotate<=0;prefer_rotate<=0;read_remaining<=0;
        end else begin
            if(read_remaining!=0 && DDRAM_DOUT_READY)
                read_remaining<=read_remaining-1'b1;
            if(command) begin
                if(DDRAM_BUSY) begin locked<=1;owner_rotate<=select_rotate;end
                else begin
                    locked<=0;prefer_rotate<=!select_rotate;
                    if(DDRAM_RD) read_remaining<=DDRAM_BURSTCNT;
                end
            end
        end
    end
endmodule
