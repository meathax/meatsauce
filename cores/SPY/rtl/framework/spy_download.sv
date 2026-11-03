// SPDX-License-Identifier: GPL-3.0-or-later
// Byte-wide ioctl index0. Retains an accepted byte through SDRAM ACK and RDY.
module spy_download (
    input wire clk,reset,init,input wire downloading,wr,
    input wire [7:0] index,data,input wire [26:0] addr,
    input wire prog_ack,prog_rdy,
    output wire wait_hps,prog_en,prog_wr,
    output reg [21:0] prog_addr,output reg [1:0] prog_ba,prog_dsn,
    output reg [15:0] prog_din,
    output reg image_ready=0,load_error=0,
    output wire accepted,output reg [24:0] accepted_bytes=0
);
    reg [2:0] state=0;
    reg mirror_tile=0;
    reg old_download=0,finish_pending=0;
    wire selected=downloading&&index==8'd0;
    wire [24:0] expected_addr=old_download?accepted_bytes:25'd0;
    assign accepted=selected&&wr&&!wait_hps;
    assign wait_hps=reset||init||state!=0;
    assign prog_en=selected||state!=0||finish_pending;
    assign prog_wr=state==1||state==4;
    always @(posedge clk) begin
        old_download<=selected;
        if(reset) begin
            state<=0;image_ready<=0;load_error<=0;accepted_bytes<=0;
            old_download<=0;finish_pending<=0;mirror_tile<=0;prog_addr<=0;prog_ba<=0;prog_dsn<=3;prog_din<=0;
        end else begin
            if(selected&&!old_download) begin
                accepted_bytes<=0;image_ready<=0;load_error<=0;finish_pending<=0;
            end
            if(accepted) begin
                if(addr!=expected_addr||addr>=25'h230100) load_error<=1;
                accepted_bytes<=expected_addr+25'd1;
                prog_addr<=addr[22:1];prog_din<={data,data};
                prog_dsn<=addr[0]?2'b01:2'b10;
                prog_ba<=addr>=25'h028000&&addr<25'h0a8000 ? 2'd0 :
                         addr>=25'h0a8000&&addr<25'h1a8000 ? 2'd3 :2'd2;
                mirror_tile<=addr>=25'h028000&&addr<25'h0a8000;
                state<=1;
            end
            if(state==1&&prog_ack) begin
                state<=prog_rdy?(mirror_tile?3:0):2;
                if(prog_rdy&&mirror_tile) prog_ba<=1;
            end
            if(state==2&&prog_rdy) begin
                state<=mirror_tile?3:0;
                if(mirror_tile) prog_ba<=1;
            end
            // A low request cycle separates the two writes. Keep the accepted
            // address/data/DQM and HPS wait asserted until the mirror is ready.
            if(state==3) state<=4;
            if(state==4&&prog_ack) state<=prog_rdy?0:5;
            if(state==5&&prog_rdy) state<=0;
            if(old_download&&!selected) finish_pending<=1;
            if(finish_pending&&state==0) begin
                finish_pending<=0;
                image_ready<=accepted_bytes==25'h230100&&!load_error;
                if(accepted_bytes!=25'h230100) load_error<=1;
            end
        end
    end
endmodule
