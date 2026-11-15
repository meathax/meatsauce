// SPDX-License-Identifier: GPL-3.0-or-later
// Simpsons-specific MAME-compatible bounded zoom path. No PCB accuracy claim.
module simpsons_zoom_draw #(parameter AW=10,CW=16,PW=16)(
 input rst,clk,draw,output busy,input [CW-1:0] code,input [AW-1:0] xpos,
 input [3:0] ysub,input [6:0] tile_width,input hflip,vflip,input [PW-5:0] pal,
 output reg [CW+6:2] rom_addr,output reg rom_cs,input rom_ok,input [31:0] rom_data,
 output reg [AW-1:0] buf_addr,output buf_we,output [PW-1:0] buf_din
);
localparam IDLE=0,SETTLE0=1,READ0=2,SETTLE1=3,READ1=4,EMIT=5;
reg [2:0] state;reg [31:0] first_half,second_half;
reg [CW-1:0] saved_code;reg [3:0] saved_row;
reg [PW-5:0] saved_pal;reg direction;reg [6:0] extent,count;
reg [20:0] step;reg [19:0] phase;
wire [3:0] source_x=phase[19:16];
wire [31:0] half_data=source_x[3] ? second_half : first_half;
wire [2:0] bit_index=3'd7-source_x[2:0];
wire [3:0] pen={half_data[24+bit_index],half_data[16+bit_index],half_data[8+bit_index],half_data[bit_index]};
assign busy=state!=IDLE;
assign buf_we=state==EMIT;
assign buf_din={saved_pal,pen};
function [20:0] source_step(input [6:0] n);
 begin case(n)
            1: source_step=21'd1048576;
            2: source_step=21'd524288;
            3: source_step=21'd349525;
            4: source_step=21'd262144;
            5: source_step=21'd209715;
            6: source_step=21'd174762;
            7: source_step=21'd149796;
            8: source_step=21'd131072;
            9: source_step=21'd116508;
            10: source_step=21'd104857;
            11: source_step=21'd95325;
            12: source_step=21'd87381;
            13: source_step=21'd80659;
            14: source_step=21'd74898;
            15: source_step=21'd69905;
            16: source_step=21'd65536;
            17: source_step=21'd61680;
            18: source_step=21'd58254;
            19: source_step=21'd55188;
            20: source_step=21'd52428;
            21: source_step=21'd49932;
            22: source_step=21'd47662;
            23: source_step=21'd45590;
            24: source_step=21'd43690;
            25: source_step=21'd41943;
            26: source_step=21'd40329;
            27: source_step=21'd38836;
            28: source_step=21'd37449;
            29: source_step=21'd36157;
            30: source_step=21'd34952;
            31: source_step=21'd33825;
            32: source_step=21'd32768;
            33: source_step=21'd31775;
            34: source_step=21'd30840;
            35: source_step=21'd29959;
            36: source_step=21'd29127;
            37: source_step=21'd28339;
            38: source_step=21'd27594;
            39: source_step=21'd26886;
            40: source_step=21'd26214;
            41: source_step=21'd25575;
            42: source_step=21'd24966;
            43: source_step=21'd24385;
            44: source_step=21'd23831;
            45: source_step=21'd23301;
            46: source_step=21'd22795;
            47: source_step=21'd22310;
            48: source_step=21'd21845;
            49: source_step=21'd21399;
            50: source_step=21'd20971;
            51: source_step=21'd20560;
            52: source_step=21'd20164;
            53: source_step=21'd19784;
            54: source_step=21'd19418;
            55: source_step=21'd19065;
            56: source_step=21'd18724;
            57: source_step=21'd18396;
            58: source_step=21'd18078;
            59: source_step=21'd17772;
            60: source_step=21'd17476;
            61: source_step=21'd17189;
            62: source_step=21'd16912;
            63: source_step=21'd16644;
            64: source_step=21'd16384;
            default: source_step=0;
 endcase end
endfunction
always @(posedge clk)begin
 if(rst)begin state<=IDLE;rom_cs<=0;rom_addr<=0;buf_addr<=0;first_half<=0;second_half<=0;phase<=0;count<=0;extent<=0;step<=0;direction<=0;saved_pal<=0;saved_code<=0;saved_row<=0;end
 else case(state)
 IDLE:if(draw && tile_width!=0)begin
  saved_code<=code;saved_row<=ysub^{4{vflip}};saved_pal<=pal;
  extent<=tile_width;count<=0;direction<=hflip;step<=source_step(tile_width);
  // Native draw hflip=1 is the normal packed-MSB orientation.
  phase<=hflip ? 0 : (tile_width-1)*source_step(tile_width);
  buf_addr<=xpos;rom_addr<={code,1'b0,ysub^{4{vflip}}};rom_cs<=1;state<=SETTLE0;
 end
 SETTLE0:state<=READ0; // romrq OKLATCH=1 may report old data for one clock.
 READ0:if(rom_ok)begin first_half<=rom_data;rom_addr<={saved_code,1'b1,saved_row};state<=SETTLE1;end
 SETTLE1:state<=READ1;
 READ1:if(rom_ok)begin second_half<=rom_data;rom_cs<=0;state<=EMIT;end
 EMIT:begin
  phase<=direction ? phase+step : phase-step;buf_addr<=buf_addr+1'd1;count<=count+1'd1;
  if(count+1==extent)state<=IDLE;
 end
 endcase
end
endmodule
