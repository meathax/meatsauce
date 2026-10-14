module VideoProbe(input wire clk,load_wr,input wire [24:0] load_addr,input wire [15:0] load_data,input wire [12:0] color_addr,input wire [8:0] pen,input wire [7:0] background,output wire [7:0] color_data,output wire [23:0] rgb);
alpha68kn_video_rom u(.clk(clk),.load_wr(load_wr),.load_addr(load_addr),.load_data(load_data),.color_addr(color_addr),.color_data(color_data),.pen(pen),.background(background),.rgb(rgb),.debug_kind(4'd0),.debug_addr(13'd0),.debug_data());
endmodule
