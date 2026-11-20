// SPDX-License-Identifier: BSD-3-Clause
// TC0480SCP scanline coordinate setup, pinned MAME 0.289 tc0480scp.cpp.
// Compute once per layer/line; the tile pipeline consumes u_start + x*x_step.
// Global flip remains explicitly unsupported until derived scroll history is wired.
module gs_scp_line (
    input wire clk,reset,query,
    output wire query_ready,
    input wire [1:0] layer,
    input wire [8:0] screen_y,
    input wire [383:0] controls,
    output wire mem_req,
    output reg [15:0] mem_addr,
    input wire mem_ack,
    input wire [15:0] mem_rdata,
    output reg valid,supported,double_width,
    output reg [8:0] source_y,
    output reg signed [31:0] u_start,x_step
);
    localparam IDLE=0,COLUMN=1,GAP_H=2,HIGH=3,GAP_L=4,LOW=5,GAP_Z=6,ZOOM=7,CALC=8,CAPTURE=9;
    reg [3:0] state;
    reg [1:0] saved_layer;
    reg [8:0] saved_screen_y;
    reg row_zoom_enable,simple;
    reg [15:0] row_high;
    reg [7:0] row_low,row_zoom;
    reg [15:0] response_data;
    reg response_valid;
    reg signed [31:0] sx_origin,y_fixed,nominal_step;
    reg [15:0] cx,cy,z,xf,yf,priority_control;
    wire signed [31:0] zx=32'sd65536-$signed({16'b0,z[15:8],8'b0});
    wire signed [31:0] zy=32'sd65536-($signed({24'b0,z[7:0]})-32'sd127)*32'sd512;
    wire is_simple=saved_layer<2 && zx==65536 && zy==65536;
    wire signed [31:0] stagger=$signed({28'b0,saved_layer,2'b0});
    wire signed [31:0] bgx=-$signed({16'b0,cx})-stagger;
    // zx/zy are multiples of 256/512. Keep their integer factors small;
    // the layer coefficient has only four values and needs no multiplier.
    wire [8:0] zx_units=9'd256-{1'b0,z[15:8]};
    wire [7:0] zy_units=8'd255-z[7:0];
    wire [9:0] y_units={1'b0,saved_screen_y}+10'd3;
    wire [17:0] y_product=y_units*zy_units;
    wire [14:0] zx_wide={6'b0,zx_units};
    wire [14:0] zx_layer=saved_layer==0 ? 15'd0 :
        saved_layer==1 ? zx_wide<<2 : saved_layer==2 ? zx_wide<<3 :
        (zx_wide<<3)+(zx_wide<<2);
    wire [14:0] sx_product=(zx_wide<<6)-(zx_wide<<3)-zx_wide+zx_layer;
    wire signed [31:0] sx_calc=is_simple ? (bgx-32'sd40)*32'sd65536 :
        (bgx+32'sd15+stagger)*32'sd65536+
        (32'sd255-$signed({24'b0,xf[7:0]}))*32'sd256+
        -$signed({9'b0,sx_product,8'b0});
    wire signed [31:0] y_calc=$signed({16'b0,cy})*32'sd65536+
        (is_simple ? 32'sd0 : $signed({24'b0,yf[7:0]})*32'sd256)+
        $signed({5'b0,y_product,9'b0});
    wire [15:0] row_base=(double_width ? 16'h8000 : 16'h4000)+{4'b0,saved_layer,10'b0};
    wire [15:0] column_base=(double_width ? 16'ha800 : 16'h6800)+
        {4'b0,saved_layer-2'd2,10'b0};
    wire [15:0] zoom_base=(double_width ? 16'ha000 : 16'h6000)+
        {4'b0,saved_layer-2'd2,10'b0};
    wire [8:0] column_index=saved_screen_y+9'd3;
    wire [14:0] zoom_wide={7'b0,row_zoom};
    wire [14:0] zoom_layer=saved_layer==0 ? 15'd0 :
        saved_layer==1 ? zoom_wide<<2 : saved_layer==2 ? zoom_wide<<3 :
        (zoom_wide<<3)+(zoom_wide<<2);
    wire [14:0] zoom_product=(zoom_wide<<6)+(zoom_wide<<3)-zoom_wide-zoom_layer;
    wire signed [31:0] zoom_adjust=-$signed({9'b0,zoom_product,8'b0});
    assign query_ready=state==IDLE;
    assign mem_req=state==COLUMN || state==HIGH || state==LOW || state==ZOOM;
    // One response stage separates the external memory bus from the distributed
    // scroll/zoom registers. Data is sampled unconditionally; validity gates use.
    always @(posedge clk) begin
        response_data<=mem_rdata;
        if(reset) response_valid<=0;
        else response_valid<=mem_req && mem_ack;
    end
    always @* begin
        case(state)
        COLUMN: mem_addr=column_base+{6'b0,column_index,1'b0};
        HIGH: mem_addr=row_base+{6'b0,source_y,1'b0};
        LOW: mem_addr=row_base+16'h1000+{6'b0,source_y,1'b0};
        ZOOM: mem_addr=zoom_base+{6'b0,source_y,1'b0};
        default: mem_addr=0;
        endcase
    end
    always @(posedge clk) begin
        if(reset) begin
            state<=IDLE;valid<=0;supported<=0;double_width<=0;source_y<=0;
            u_start<=0;x_step<=0;saved_layer<=0;saved_screen_y<=0;
            row_zoom_enable<=0;simple<=0;row_high<=0;row_low<=0;row_zoom<=0;
            sx_origin<=0;y_fixed<=0;nominal_step<=0;
        end else begin
            valid<=0;
            case(state)
            IDLE: if(query) begin
                saved_layer<=layer;saved_screen_y<=screen_y;
                cx<=controls[layer*16+:16];cy<=controls[(4+layer)*16+:16];
                z<=controls[(8+layer)*16+:16];xf<=controls[(16+layer)*16+:16];
                yf<=controls[(20+layer)*16+:16];priority_control<=controls[240+:16];
                state<=CAPTURE;
            end
            CAPTURE: begin
                double_width<=priority_control[7];supported<=!priority_control[6];
                row_zoom_enable<=saved_layer>=2 && priority_control[saved_layer-2'd2];
                simple<=is_simple;row_high<=0;row_low<=0;row_zoom<=0;
                sx_origin<=sx_calc;y_fixed<=y_calc;nominal_step<=zx;
                source_y<=y_calc[24:16];
                state<=saved_layer>=2 ? COLUMN : HIGH;
            end
            COLUMN: if(response_valid) begin source_y<=y_fixed[24:16]+response_data[8:0];state<=GAP_H;end
            GAP_H: state<=HIGH;
            HIGH: if(response_valid) begin row_high<=response_data;state<=simple ? CALC : GAP_L;end
            GAP_L: state<=LOW;
            LOW: if(response_valid) begin row_low<=response_data[7:0];state<=row_zoom_enable ? GAP_Z : CALC;end
            GAP_Z: state<=ZOOM;
            ZOOM: if(response_valid) begin row_zoom<=response_data[7:0];state<=CALC;end
            CALC: begin
                u_start<=sx_origin-$signed({row_high,16'b0})-
                    $signed({16'b0,row_low,8'b0})-zoom_adjust;
                x_step<=nominal_step-$signed({16'b0,row_zoom,8'b0});
                valid<=1;state<=IDLE;
            end
            endcase
        end
    end
endmodule
