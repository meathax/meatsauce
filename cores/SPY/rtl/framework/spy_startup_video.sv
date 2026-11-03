// SPDX-License-Identifier: GPL-3.0-or-later
// Blank native raster while loading/reset; independent of the held game CPU.
module spy_startup_video(input wire clk,reset,output wire ce,hs,vs,hblank,vblank);
    reg [2:0] phase=0;reg [8:0] x=0,y=0;
    assign ce=phase==7;
    assign hs=x>=328&&x<360;assign vs=y>=244&&y<248;
    assign hblank=x<8||x>=312;assign vblank=y<16||y>=240;
    always @(posedge clk) begin
        if(reset) begin phase<=0;x<=0;y<=0;end
        else begin
            phase<=phase+3'd1;
            if(ce) begin
                if(x==383) begin x<=0;y<=y==263?9'd0:y+9'd1;end
                else x<=x+9'd1;
            end
        end
    end
endmodule
