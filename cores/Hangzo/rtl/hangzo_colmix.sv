// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ns
module hangzo_colmix(
    input wire[31:0] layers,
    input wire[12:0] sprite_pixel,
    input wire[3:0] layer_enable,
    input wire[2:0] priority_control,
    output reg[10:0] pen
);
    wire[7:0] p0=layers[7:0],p1=layers[15:8],p2=layers[23:16],p3=layers[31:24];
    wire v0=layer_enable[0] && p0[3:0]!=0;
    wire v1=layer_enable[1] && p1[3:0]!=0;
    wire v2=layer_enable[2] && p2[3:0]!=0;
    wire v3=layer_enable[3] && p3[3:0]!=0;
    reg[2:0] tile_priority;
    reg blocked;
    always @* begin
        pen=11'd768;tile_priority=0;
        case(priority_control[1:0])
            0: begin
                if(priority_control[2]) begin
                    if(layer_enable[2]) begin
                        pen=11'd512+{3'd0,p3[3:0],p2[3:0]};tile_priority=3;
                    end
                end else begin
                    if(layer_enable[3]) begin pen=11'd768+{3'd0,p3};tile_priority=1;end
                    if(v2) begin pen=11'd512+{3'd0,p2};tile_priority=tile_priority|3'd2;end
                end
                if(v1) begin pen=11'd256+{3'd0,p1};tile_priority=tile_priority|3'd4;end
            end
            1: begin
                if(layer_enable[3]) begin pen=11'd768+{3'd0,p3};tile_priority=1;end
                if(v1) begin pen=11'd256+{3'd0,p1};tile_priority=tile_priority|3'd2;end
                if(v2) begin pen=11'd512+{3'd0,p2};tile_priority=tile_priority|3'd4;end
            end
            2: begin
                if(v1) begin pen=11'd256+{3'd0,p1};tile_priority=1;end
                if(v3) begin pen=11'd768+{3'd0,p3};tile_priority=tile_priority|3'd2;end
                if(v2) begin pen=11'd512+{3'd0,p2};tile_priority=tile_priority|3'd4;end
            end
            default:;
        endcase
        blocked=(sprite_pixel[11:10]==2'b10 && tile_priority[2]) ||
                (sprite_pixel[11:10]==2'b11 && |tile_priority[2:1]);
        if(sprite_pixel[3:0]!=0 && !blocked)pen=11'd1024+{1'b0,sprite_pixel[9:0]};
        if(v0)pen={3'd0,p0};
    end
endmodule
