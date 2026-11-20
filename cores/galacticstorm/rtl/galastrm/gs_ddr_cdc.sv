// SPDX-License-Identifier: BSD-3-Clause
// Whole held DDRAM commands cross to the physical service clock. The client
// observes acceptance on FIFO admission; all accepted commands retain order.
// One outstanding read burst per client, as in gs_ddr_surface. Reply capacity
// covers the complete native eight-word burst even while the client is stopped.
module gs_ddr_cdc(
    input wire client_clk,ram_clk,cold_reset,
    input wire client_rd,client_we,input wire [7:0] client_burstcnt,
    input wire [28:0] client_addr,input wire [63:0] client_din,input wire [7:0] client_be,
    output wire client_busy,client_dout_ready,output wire [63:0] client_dout,
    output reg reply_overflow,
    input wire DDRAM_BUSY,output wire [7:0] DDRAM_BURSTCNT,
    output wire [28:0] DDRAM_ADDR,input wire [63:0] DDRAM_DOUT,
    input wire DDRAM_DOUT_READY,output wire DDRAM_RD,
    output wire [63:0] DDRAM_DIN,output wire [7:0] DDRAM_BE,output wire DDRAM_WE
);
    // Keep raw board reset out of the client's synchronous busy/reply logic.
    // Catch assertion immediately, including pulses between client edges, then
    // release each FIFO side on its own clock.
    (* preserve, dont_merge, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] client_reset_s=2'b11,ram_reset_s=2'b11;
    always @(posedge client_clk or posedge cold_reset)
        if(cold_reset)client_reset_s<=2'b11;
        else client_reset_s<={client_reset_s[0],1'b0};
    always @(posedge ram_clk or posedge cold_reset)
        if(cold_reset)ram_reset_s<=2'b11;
        else ram_reset_s<={ram_reset_s[0],1'b0};
    wire client_reset=client_reset_s[1],ram_reset=ram_reset_s[1];
    wire command_full,command_empty,command_pop;
    wire [110:0] command_word;
    gs_async_fifo #(.DW(111),.AW(3)) commands(
        .wr_clk(client_clk),.wr_reset(client_reset),.wr_en((client_rd || client_we) && !client_reset),
        .wr_data({client_rd,client_we,client_burstcnt,client_addr,client_din,client_be}),.full(command_full),
        .rd_clk(ram_clk),.rd_reset(ram_reset),.rd_en(command_pop),.rd_data(command_word),.empty(command_empty),.rd_level());
    assign client_busy=command_full || client_reset;
    assign {DDRAM_BURSTCNT,DDRAM_ADDR,DDRAM_DIN,DDRAM_BE}=command_word[108:0];
    assign DDRAM_RD=!command_empty && !ram_reset && command_word[110];
    assign DDRAM_WE=!command_empty && !ram_reset && command_word[109];
    assign command_pop=(DDRAM_RD || DDRAM_WE) && !DDRAM_BUSY;
    wire reply_full,reply_empty;
    gs_async_fifo #(.DW(64),.AW(4)) replies(
        .wr_clk(ram_clk),.wr_reset(ram_reset),.wr_en(DDRAM_DOUT_READY && !ram_reset),.wr_data(DDRAM_DOUT),.full(reply_full),
        .rd_clk(client_clk),.rd_reset(client_reset),.rd_en(!reply_empty && !client_reset),.rd_data(client_dout),.empty(reply_empty),.rd_level());
    assign client_dout_ready=!reply_empty && !client_reset;
    always @(posedge ram_clk)begin
        if(DDRAM_DOUT_READY && reply_full)reply_overflow<=1;
        if(ram_reset)reply_overflow<=0;
    end
endmodule
