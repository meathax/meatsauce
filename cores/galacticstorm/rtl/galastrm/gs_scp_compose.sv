// SPDX-License-Identifier: BSD-3-Clause
// Pinned Galastrm background order/priority, galastrm.cpp:605-609,665-691.
// Every background is transparent at pen zero, including the bottom layer.
module gs_scp_compose (
    input wire [47:0] layer_pixels,
    input wire [3:0] layer_opaque,
    input wire [2:0] priority_order,
    output reg [11:0] pixel_index,
    output reg [3:0] background_priority,
    input wire sprite_present,
    input wire [1:0] sprite_priority,
    output wire sprite_allowed
);
    reg [7:0] order;
    integer rank,current_layer;
    always @* begin
        order=8'h1b;
        case(priority_order)
        0: order=8'h1b; // 0123
        1: order=8'h6c; // 1230
        2: order=8'hb1; // 2301
        3: order=8'hc6; // 3012
        4: order=8'he4; // 3210
        5: order=8'h93; // 2103
        6: order=8'h4e; // 1032
        7: order=8'h39; // 0321
        endcase
        pixel_index=0;background_priority=0;current_layer=0;
        for(rank=0;rank<4;rank=rank+1) begin
            current_layer=order[(3-rank)*2+:2];
            if(layer_opaque[current_layer]) begin
                pixel_index=layer_pixels[current_layer*12+:12];
                if(priority_order==7 && rank!=0) background_priority=background_priority|4'h4;
                else background_priority=background_priority|(4'b0001<<rank);
            end
        end
        if(priority_order==3 && !background_priority[1] && pixel_index!=0)
            background_priority=background_priority|4'h4;
    end
    // These are the driver's FFFC/FFF0/FF00/0000 masks for priority 0..3.
    // Sprite ownership is separate: first opaque sprite claims even if masked.
    assign sprite_allowed=sprite_present &&
        ((sprite_priority==0 && background_priority<2) ||
         (sprite_priority==1 && background_priority<4) ||
         (sprite_priority==2 && background_priority<8) || sprite_priority==3);
endmodule
