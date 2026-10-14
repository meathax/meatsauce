// Physical RGB/color/lookup PROMs, packed as transport words for block RAM.
// Full source bytes are preserved; outputs use the wired low PROM nibbles.
module alpha68kn_video_rom (
    input wire clk,load_wr,
    input wire [24:0] load_addr,
    input wire [15:0] load_data,
    input wire [12:0] color_addr,
    output wire [7:0] color_data,
    input wire [8:0] pen,
    input wire [7:0] background,
    output wire [23:0] rgb,
    input wire [3:0] debug_kind,
    input wire [12:0] debug_addr,
    output reg [15:0] debug_data
);
    reg [15:0] red[0:127],green[0:127],blue[0:127];
    reg [15:0] clut_lo[0:127],clut_hi[0:127],color_rom[0:4095];
    // Full-word synchronous reads; aligned selectors preserve each original cycle.
    reg [15:0] color_q,lo,hi,r,g,b;
    reg color_lane,pen_lane,pen_background,rgb_lane;
    reg [7:0] background_q;
    wire [7:0] indirect=pen_background ? background_q :
        pen_lane ? {hi[11:8],lo[11:8]} : {hi[3:0],lo[3:0]};
    assign color_data=color_lane ? color_q[15:8] : color_q[7:0];
    wire [3:0] rn=rgb_lane?r[11:8]:r[3:0];
    wire [3:0] gn=rgb_lane?g[11:8]:g[3:0];
    wire [3:0] bn=rgb_lane?b[11:8]:b[3:0];
    assign rgb={rn,rn,gn,gn,bn,bn};
    wire [15:0] debug_clut=debug_addr[8]?clut_hi[debug_addr[7:1]]:clut_lo[debug_addr[7:1]];
    always @(posedge clk) begin
        if(load_wr) begin
            if(load_addr>=25'h30100 && load_addr<25'h30200) red[load_addr[7:1]]<=load_data;
            if(load_addr>=25'h30200 && load_addr<25'h30300) green[load_addr[7:1]]<=load_data;
            if(load_addr>=25'h30300 && load_addr<25'h30400) blue[load_addr[7:1]]<=load_data;
            if(load_addr>=25'h30400 && load_addr<25'h30500) clut_lo[load_addr[7:1]]<=load_data;
            if(load_addr>=25'h30500 && load_addr<25'h30600) clut_hi[load_addr[7:1]]<=load_data;
            if(load_addr>=25'h31000 && load_addr<25'h33000)
                color_rom[12'((load_addr-25'h31000)>>1)]<=load_data;
        end
        color_q<=color_rom[color_addr[12:1]];
        color_lane<=color_addr[0];
        lo<=clut_lo[pen[7:1]];
        hi<=clut_hi[pen[7:1]];
        pen_lane<=pen[0];
        pen_background<=pen[8];
        background_q<=background;
        r<=red[indirect[7:1]];
        g<=green[indirect[7:1]];
        b<=blue[indirect[7:1]];
        rgb_lane<=indirect[0];
        case(debug_kind)
            3:debug_data<={red[debug_addr[7:1]][7:0],red[debug_addr[7:1]][15:8]};
            4:debug_data<={green[debug_addr[7:1]][7:0],green[debug_addr[7:1]][15:8]};
            5:debug_data<={blue[debug_addr[7:1]][7:0],blue[debug_addr[7:1]][15:8]};
            6:debug_data<={debug_clut[7:0],debug_clut[15:8]};
            7:debug_data<={color_rom[debug_addr[12:1]][7:0],color_rom[debug_addr[12:1]][15:8]};
            default:debug_data<=16'hffff;
        endcase
    end
endmodule
