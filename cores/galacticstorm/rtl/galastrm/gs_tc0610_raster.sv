// SPDX-License-Identifier: BSD-3-Clause
// MAME 0.289 poly.h render_polygon<4,2>, Galastrm visible destination clip.
// Produces actual shader signed 16.16 starts/deltas, with binary32 setup.
module gs_tc0610_raster #(
    parameter CLIP_LEFT=96,CLIP_RIGHT=415,CLIP_TOP=84,CLIP_BOTTOM=315,
    parameter EXTERNAL_FP=0
)(
    input wire clk,reset,query,
    output wire query_ready,
    input wire empty,
    input wire [255:0] vertices,
    output reg valid,
    input wire ready,
    output reg done,
    output reg [8:0] y,
    output reg [9:0] start_x,stop_x,
    output reg signed [31:0] u,v,du,dv,
    output wire [1:0] unit_operation,
    output wire [31:0] unit_a,unit_b,
    output wire unit_a_stb,unit_b_stb,unit_z_ack,
    input wire unit_a_ack,unit_b_ack,unit_z_valid,
    input wire [31:0] unit_z
);
    localparam IDLE=0,START=1,EDGE_PREP=2,EDGE_ISSUE=3,EDGE_WAIT=4,
        CHAIN_START=5,CHAIN_SKIP=6,CHAIN_CLASSIFY=7,LINE_ADVANCE=8,
        LINE_LOAD=9,LINE_ISSUE=10,LINE_WAIT=11,OUTPUT_LINE=12,FINISH=13,
        MINMAX=14,CAPTURE_Y=15,ROUND_Y=16,START_CLIP=17,LINE_ROUND=18,LINE_RANGE=19,
        ROUND_Y_MAX=20,LINE_ROUND_START=21,LINE_ROUND_STOP=22,
        EDGE_LOAD_XY=23,EDGE_LOAD_EU=24,EDGE_LOAD_EV=25,
        CONVERT_START=26,CONVERT_DELTA=27;
    reg [4:0] state;
    reg [31:0] vx[0:3],vy[0:3];
    reg [1:0] origin[0:3];
    reg [3:0] active;
    reg [1:0] edge_index,edge_low,edge_high,forward_edge,backward_edge;
    reg [2:0] edge_operation;
    reg [31:0] edge_delta,edge_reciprocal,edge_dx;
    reg [1:0] min_vertex,max_vertex,compare_vertex;
    reg [31:0] convert_input;
    reg convert_round;
    reg signed [31:0] minimum_line,maximum_line,rounded_start,rounded_stop;
    reg [31:0] maximum_y;
    reg [9:0] last_y;
    reg forward_left,parameter_v;
    reg [4:0] instruction;
    // A single write port loads the scanline operands and records FP results.
    // Valid bits preserve reset-zero semantics without clearing the RAM array.
    (* ramstyle="MLAB, no_rw_check" *) reg [31:0] work[0:31];
    reg [31:0] work_valid;
    reg [3:0] load_index;
    reg [4:0] operand_a,operand_b;
    wire coordinate_round=state==LINE_ROUND || state==LINE_ROUND_START || state==LINE_ROUND_STOP;
    wire [4:0] read_a=coordinate_round ? 5'd19 :
        state==CONVERT_START || (state==LINE_WAIT && (instruction==17 || instruction==19)) ? 5'd26 : operand_a;
    wire [4:0] read_b=coordinate_round ? 5'd20 : operand_b;
    wire [31:0] work_a=work_valid[read_a] ? work[read_a] : 32'b0;
    wire [31:0] work_b=work_valid[read_b] ? work[read_b] : 32'b0;
    reg signed [31:0] integer_start,integer_stop;
    wire [1:0] next_edge=edge_index+2'd1;
    wire [1:0] left_edge=forward_left ? forward_edge : backward_edge;
    wire [1:0] right_edge=forward_left ? backward_edge : forward_edge;
    reg [1:0] fp_operation;
    reg [31:0] fp_a,fp_b;
    reg [4:0] destination;
    wire fp_ready,fp_valid;
    wire [31:0] fp_result;
    integer i;
    function automatic fp_less(input [31:0] a,b);
        begin
            if(a[30:0]==0 && b[30:0]==0) fp_less=0;
            else if(a[31]!=b[31]) fp_less=a[31];
            else fp_less=a[31] ? a[30:0]>b[30:0] : a[30:0]<b[30:0];
        end
    endfunction
    function automatic [31:0] negate(input [31:0] a);
        begin negate={~a[31],a[30:0]};end
    endfunction
    function automatic [31:0] tex_u(input [1:0] index);
        begin tex_u=index>=2 ? 32'h4bff8000 : 32'b0;end
    endfunction
    function automatic [31:0] tex_v(input [1:0] index);
        begin tex_v=(index==1 || index==2) ? 32'h4bc78000 : 32'b0;end
    endfunction
    function automatic [31:0] tex_delta(input [31:0] low,high);
        begin tex_delta=low==high ? 32'b0 : low==0 ? high : negate(low);end
    endfunction
    function automatic [31:0] integer_float(input signed [31:0] value,input half_scale);
        reg [31:0] magnitude,shifted;
        reg [4:0] lead;
        reg [7:0] exponent;
        integer n;
        begin
            magnitude=value[31] ? -value : value;lead=0;
            for(n=0;n<32;n=n+1) if(magnitude[n]) lead=n[4:0];
            // Normalize to bit 31 once; selecting [30:8] keeps the same
            // truncated fraction for every magnitude and both scale modes.
            shifted=magnitude<<(5'd31-lead);
            exponent=8'd127+lead-half_scale;
            integer_float=value==0 ? 32'b0 : {value[31],exponent,shifted[30:8]};
        end
    endfunction
    // Round nearest with ties toward negative infinity, or truncate toward
    // zero. Right-shift jam retains guard/sticky bits for every binary32 value.
    function automatic signed [31:0] coordinate_integer(input [31:0] value,input do_round);
        reg [26:0] jam;
        reg [31:0] magnitude;
        reg [4:0] shift;
        reg [2:0] left_shift;
        begin
            shift=8'd150-value[30:23];left_shift=value[25:23]-3'd6;
            jam={1'b1,value[22:0],3'b0};magnitude=0;
            if(value[30:23]>=158)
                coordinate_integer=do_round && !value[31] ? 32'sh7fffffff : 32'sh80000000;
            else if(value[30:23]<126 || (!do_round && value[30:23]==126))
                coordinate_integer=0;
            else begin
                if(value[30:23]>=150) magnitude={8'b0,1'b1,value[22:0]}<<left_shift;
                else begin
                    if(shift[4]) jam={16'b0,jam[26:16]}|{26'b0,(|jam[15:0])};
                    if(shift[3]) jam={8'b0,jam[26:8]}|{26'b0,(|jam[7:0])};
                    if(shift[2]) jam={4'b0,jam[26:4]}|{26'b0,(|jam[3:0])};
                    if(shift[1]) jam={2'b0,jam[26:2]}|{26'b0,(|jam[1:0])};
                    if(shift[0]) jam={1'b0,jam[26:1]}|{26'b0,jam[0]};
                    magnitude={8'b0,jam[26:3]}+
                        (do_round && jam[2] && (value[31] || (|jam[1:0])));
                end
                coordinate_integer=value[31] ? -$signed(magnitude) : $signed(magnitude);
            end
        end
    endfunction

    // y+0.5 has only ten significant input bits. A range decoder encodes it
    // exactly, without a second general 32-bit normalizer and barrel shifter.
    function automatic [31:0] half_line_float(input [8:0] line_y);
        reg [9:0] magnitude;
        begin
            magnitude={line_y,1'b1};
            casez(magnitude)
            10'b1?????????:half_line_float={1'b0,8'd135,magnitude[8:0],14'b0};
            10'b01????????:half_line_float={1'b0,8'd134,magnitude[7:0],15'b0};
            10'b001???????:half_line_float={1'b0,8'd133,magnitude[6:0],16'b0};
            10'b0001??????:half_line_float={1'b0,8'd132,magnitude[5:0],17'b0};
            10'b00001?????:half_line_float={1'b0,8'd131,magnitude[4:0],18'b0};
            10'b000001????:half_line_float={1'b0,8'd130,magnitude[3:0],19'b0};
            10'b0000001???:half_line_float={1'b0,8'd129,magnitude[2:0],20'b0};
            10'b00000001??:half_line_float={1'b0,8'd128,magnitude[1:0],21'b0};
            10'b000000001?:half_line_float={1'b0,8'd127,magnitude[0],22'b0};
            default:half_line_float=32'h3f000000;
            endcase
        end
    endfunction
    wire [31:0] fully=half_line_float(y);
    // One exact coordinate rounder consumes a registered input in successive
    // setup/scanline states. This retains the source's midpoint convention.
    wire signed [31:0] converted_coordinate=coordinate_integer(convert_input,convert_round);
    wire signed [31:0] float_integer=instruction==18 ? CLIP_LEFT-integer_start : integer_start;
    wire [31:0] converted_integer=integer_float(float_integer,1'b0);
    always @* begin
        operand_a=0;operand_b=0;
        case(instruction)
        0: begin operand_a=16;operand_b=1;end
        1: begin operand_a=16;operand_b=9;end
        2: begin operand_a=17;operand_b=4;end
        3: begin operand_a=0;operand_b=28;end
        4: begin operand_a=18;operand_b=12;end
        5: begin operand_a=8;operand_b=28;end
        6: begin operand_a=20;operand_b=19;end
        7: begin operand_a=0;operand_b=21;end
        8: begin operand_a=0;operand_b=0;end
        9: begin operand_a=23;operand_b=19;end
        10: begin operand_a=17;operand_b=parameter_v ? 6 : 5;end
        11: begin operand_a=parameter_v ? 3 : 2;operand_b=28;end
        12: begin operand_a=18;operand_b=parameter_v ? 14 : 13;end
        13: begin operand_a=parameter_v ? 11 : 10;operand_b=28;end
        14: begin operand_a=25;operand_b=24;end
        15: begin operand_a=26;operand_b=22;end
        16: begin operand_a=23;operand_b=26;end
        17: begin operand_a=24;operand_b=28;end
        18: begin operand_a=0;operand_b=26;end
        19: begin operand_a=27;operand_b=28;end
        endcase
    end
    wire [1:0] load_edge=load_index<7 ? left_edge : right_edge;
    wire [1:0] load_pair=(load_index==0 || load_index==1 || load_index==7 || load_index==8) ? 2'd0 :
        (load_index==2 || load_index==9) ? 2'd1 :
        (load_index==3 || load_index==4 || load_index==10 || load_index==11) ? 2'd2 : 2'd3;
    wire load_upper=load_index==1 || load_index==8 || load_index==2 || load_index==9 ||
        load_index==4 || load_index==11 || load_index==6 || load_index==13;
    // Four full 64-bit pairs per edge: {ey,ex}, {eu,end_y}, {sx,ev}, {sv,su}.
    // Complete row writes retain neighboring fields; valid bits mask reset RAM.
    (* ramstyle="MLAB, no_rw_check" *) reg [63:0] geometry[0:15];
    reg [15:0] geometry_valid;
    wire compare_slopes=origin[forward_edge]==origin[backward_edge];
    wire [1:0] chain_pair=compare_slopes ? 2'd2 : 2'd0;
    wire geometry_write=state==EDGE_LOAD_XY || state==EDGE_LOAD_EU || state==EDGE_LOAD_EV ||
        (state==EDGE_WAIT && fp_valid && edge_operation>=3);
    wire [1:0] geometry_write_pair=state==EDGE_LOAD_XY ? 2'd0 :
        state==EDGE_LOAD_EU ? 2'd1 :
        state==EDGE_LOAD_EV || edge_operation==3 ? 2'd2 : 2'd3;
    wire [3:0] geometry_a_address=geometry_write ? {edge_index,geometry_write_pair} :
        state==LINE_LOAD ? {load_edge,load_pair} :
        state==LINE_ADVANCE ? {forward_edge,2'd1} : {forward_edge,chain_pair};
    wire [3:0] geometry_b_address=state==LINE_ADVANCE ? {backward_edge,2'd1} :
        {backward_edge,chain_pair};
    wire [63:0] geometry_a=geometry_valid[geometry_a_address] ? geometry[geometry_a_address] : 64'b0;
    wire [63:0] geometry_b=geometry_valid[geometry_b_address] ? geometry[geometry_b_address] : 64'b0;
    wire [31:0] chain_a=compare_slopes ? geometry_a[63:32] : geometry_a[31:0];
    wire [31:0] chain_b=compare_slopes ? geometry_b[63:32] : geometry_b[31:0];
    reg [63:0] geometry_data;
    always @* begin
        geometry_data=geometry_a;
        case(state)
        EDGE_LOAD_XY: geometry_data={vy[edge_low],vx[edge_low]};
        EDGE_LOAD_EU: geometry_data={tex_u(edge_low),vy[edge_high]};
        EDGE_LOAD_EV: geometry_data={geometry_a[63:32],tex_v(edge_low)};
        EDGE_WAIT: case(edge_operation)
            3: geometry_data={fp_result,geometry_a[31:0]};
            4: geometry_data={geometry_a[63:32],fp_result};
            5: geometry_data={fp_result,geometry_a[31:0]};
        endcase
        endcase
    end
    always @(posedge clk) begin
        if(geometry_write) begin
            geometry[geometry_a_address]<=geometry_data;
            geometry_valid[geometry_a_address]<=1'b1;
        end
        if(reset) geometry_valid<=0;
    end
    wire [4:0] load_address=load_index<7 ? {1'b0,load_index} :
        load_index<14 ? {1'b0,load_index}+5'd1 : 5'd16;
    reg [31:0] load_data;
    always @* begin
        case(load_index)
        0,1,2,3,4,5,6,7,8,9,10,11,12,13:
            load_data=load_upper ? geometry_a[63:32] : geometry_a[31:0];
        default: load_data=fully;
        endcase
    end
    wire work_write=state==LINE_LOAD || (state==LINE_WAIT && fp_valid);
    wire [4:0] work_address=state==LINE_LOAD ? load_address : destination;
    wire [31:0] work_data=state==LINE_LOAD ? load_data : fp_result;
    always @(posedge clk) begin
        if(work_write) begin work[work_address]<=work_data;work_valid[work_address]<=1'b1;end
        if(reset) work_valid<=0;
    end
    assign query_ready=state==IDLE;
    always @* begin
        fp_operation=0;fp_a=0;fp_b=0;destination=0;
        if(state==EDGE_ISSUE || state==EDGE_WAIT) begin
            case(edge_operation)
            0: begin fp_a=vy[edge_high];fp_b=negate(vy[edge_low]);end
            1: begin fp_operation=2;fp_a=32'h3f800000;fp_b=edge_delta;end
            2: begin fp_a=vx[edge_high];fp_b=negate(vx[edge_low]);end
            3: begin fp_operation=1;fp_a=edge_dx;fp_b=edge_reciprocal;end
            4: begin fp_operation=1;fp_a=tex_delta(tex_u(edge_low),tex_u(edge_high));fp_b=edge_reciprocal;end
            5: begin fp_operation=1;fp_a=tex_delta(tex_v(edge_low),tex_v(edge_high));fp_b=edge_reciprocal;end
            endcase
        end else begin
            case(instruction)
             0: begin destination=17;fp_a=work_a;fp_b=negate(work_b);end
             1: begin destination=18;fp_a=work_a;fp_b=negate(work_b);end
             2: begin destination=28;fp_operation=1;fp_a=work_a;fp_b=work_b;end
             3: begin destination=19;fp_a=work_a;fp_b=work_b;end
             4: begin destination=28;fp_operation=1;fp_a=work_a;fp_b=work_b;end
             5: begin destination=20;fp_a=work_a;fp_b=work_b;end
             6: begin destination=21;fp_a=work_a;fp_b=negate(work_b);end
             7: begin destination=22;fp_operation=2;fp_a=32'h3f800000;fp_b=work_b;end
             8: begin destination=23;fp_a=converted_integer;fp_b=32'h3f000000;end
             9: begin destination=23;fp_a=work_a;fp_b=negate(work_b);end
            10: begin destination=28;fp_operation=1;fp_a=work_a;fp_b=work_b;end
            11: begin destination=24;fp_a=work_a;fp_b=work_b;end
            12: begin destination=28;fp_operation=1;fp_a=work_a;fp_b=work_b;end
            13: begin destination=25;fp_a=work_a;fp_b=work_b;end
            14: begin destination=26;fp_a=work_a;fp_b=negate(work_b);end
            15: begin destination=26;fp_operation=1;fp_a=work_a;fp_b=work_b;end
            16: begin destination=28;fp_operation=1;fp_a=work_a;fp_b=work_b;end
            17: begin destination=27;fp_a=work_a;fp_b=work_b;end
            18: begin destination=28;fp_operation=1;fp_a=converted_integer;fp_b=work_b;end
            19: begin destination=27;fp_a=work_a;fp_b=work_b;end
            endcase
        end
    end
    gs_float32 #(.EXTERNAL_FP(EXTERNAL_FP)) scalar(
        .clk(clk),.reset(reset),.request(state==EDGE_ISSUE || state==LINE_ISSUE),
        .request_ready(fp_ready),.operation(fp_operation),.a(fp_a),.b(fp_b),
        .valid(fp_valid),.ready(state==EDGE_WAIT || state==LINE_WAIT),.result(fp_result),
        .unit_operation(unit_operation),.unit_a(unit_a),.unit_b(unit_b),
        .unit_a_stb(unit_a_stb),.unit_b_stb(unit_b_stb),.unit_z_ack(unit_z_ack),
        .unit_a_ack(unit_a_ack),.unit_b_ack(unit_b_ack),
        .unit_z_valid(unit_z_valid),.unit_z(unit_z));
    always @(posedge clk) begin
        done<=0;
        case(state)
        IDLE: if(query && query_ready) begin
            if(empty) state<=FINISH;
            else begin
                for(i=0;i<4;i=i+1) begin vx[i]<=vertices[i*64 +: 32];vy[i]<=vertices[i*64+32 +: 32];end
                state<=START;
            end
        end
        START: begin
            min_vertex<=0;max_vertex<=0;compare_vertex<=1;state<=MINMAX;
        end
        MINMAX: begin
            if(fp_less(vy[compare_vertex],vy[min_vertex])) min_vertex<=compare_vertex;
            else if(fp_less(vy[max_vertex],vy[compare_vertex])) max_vertex<=compare_vertex;
            if(compare_vertex==3) state<=CAPTURE_Y;
            else compare_vertex<=compare_vertex+1'b1;
        end
        CAPTURE_Y: begin
            convert_input<=vy[min_vertex];convert_round<=1;maximum_y<=vy[max_vertex];state<=ROUND_Y;
        end
        ROUND_Y: begin
            minimum_line<=converted_coordinate;convert_input<=maximum_y;state<=ROUND_Y_MAX;
        end
        ROUND_Y_MAX: begin maximum_line<=converted_coordinate;state<=START_CLIP;end
        START_CLIP: begin
            y<=minimum_line<CLIP_TOP ? CLIP_TOP : minimum_line[8:0];
            last_y<=maximum_line>CLIP_BOTTOM+1 ? CLIP_BOTTOM+1 : maximum_line[9:0];
            edge_index<=0;
            if(minimum_line>=CLIP_BOTTOM+1 || maximum_line<=CLIP_TOP || maximum_line<=minimum_line) state<=FINISH;
            else state<=EDGE_PREP;
        end
        EDGE_PREP: begin
            if(vy[edge_index]==vy[next_edge]) begin
                active[edge_index]<=0;
                if(edge_index==3) state<=CHAIN_START;
                else edge_index<=next_edge;
            end else begin
                active[edge_index]<=1;
                if(fp_less(vy[next_edge],vy[edge_index])) begin
                    edge_low<=next_edge;edge_high<=edge_index;origin[edge_index]<=next_edge;
                end else begin
                    edge_low<=edge_index;edge_high<=next_edge;origin[edge_index]<=edge_index;
                end
                edge_operation<=0;state<=EDGE_LOAD_XY;
            end
        end
        EDGE_LOAD_XY: state<=EDGE_LOAD_EU;
        EDGE_LOAD_EU: state<=EDGE_LOAD_EV;
        EDGE_LOAD_EV: state<=EDGE_ISSUE;
        EDGE_ISSUE: if(fp_ready) state<=EDGE_WAIT;
        EDGE_WAIT: if(fp_valid) begin
            case(edge_operation)
            0: edge_delta<=fp_result;
            1: edge_reciprocal<=fp_result;
            2: edge_dx<=fp_result;
            endcase
            if(edge_operation==5) begin
                if(edge_index==3) state<=CHAIN_START;
                else begin edge_index<=next_edge;state<=EDGE_PREP;end
            end else begin edge_operation<=edge_operation+1'b1;state<=EDGE_ISSUE;end
        end
        CHAIN_START: begin forward_edge<=min_vertex;backward_edge<=min_vertex-2'd1;state<=CHAIN_SKIP;end
        CHAIN_SKIP: begin
            if(!active[forward_edge]) forward_edge<=forward_edge+2'd1;
            if(!active[backward_edge]) backward_edge<=backward_edge-2'd1;
            if(active[forward_edge] && active[backward_edge]) state<=CHAIN_CLASSIFY;
        end
        CHAIN_CLASSIFY: begin
            forward_left<=fp_less(chain_a,chain_b);
            state<=LINE_ADVANCE;
        end
        LINE_ADVANCE: begin
            if(!active[forward_edge] || (fp_less(geometry_a[31:0],fully) && fp_less(fully,maximum_y)))
                forward_edge<=forward_edge+2'd1;
            else if(!active[backward_edge] || (fp_less(geometry_b[31:0],fully) && fp_less(fully,maximum_y)))
                backward_edge<=backward_edge-2'd1;
            else begin load_index<=0;state<=LINE_LOAD;end
        end
        LINE_LOAD: begin
            if(load_index==14) begin instruction<=0;parameter_v<=0;state<=LINE_ISSUE;end
            else load_index<=load_index+1'b1;
        end
        LINE_ISSUE: if(fp_ready) state<=LINE_WAIT;
        LINE_WAIT: if(fp_valid) begin
            state<=LINE_ISSUE;
            if(instruction==5) state<=LINE_ROUND;
            if((instruction==17 && integer_start>=CLIP_LEFT) || instruction==19) begin
                convert_input<=fp_result;convert_round<=0;state<=CONVERT_START;
            end else instruction<=instruction+1'b1;
        end
        LINE_ROUND: begin
            convert_input<=work_a;convert_round<=1;state<=LINE_ROUND_START;
        end
        LINE_ROUND_START: begin
            rounded_start<=converted_coordinate;convert_input<=work_b;state<=LINE_ROUND_STOP;
        end
        LINE_ROUND_STOP: begin rounded_stop<=converted_coordinate;state<=LINE_RANGE;end
        CONVERT_START: begin
            if(!parameter_v) u<=converted_coordinate;else v<=converted_coordinate;
            convert_input<=work_a;state<=CONVERT_DELTA;
        end
        CONVERT_DELTA: begin
            if(!parameter_v) begin
                du<=converted_coordinate;parameter_v<=1;instruction<=10;state<=LINE_ISSUE;
            end else begin
                dv<=converted_coordinate;
                if((integer_start<CLIP_LEFT ? CLIP_LEFT : integer_start)>=(integer_stop>CLIP_RIGHT ? CLIP_RIGHT+1 : integer_stop)) begin start_x<=0;stop_x<=0;end
                else begin start_x<=integer_start<CLIP_LEFT ? CLIP_LEFT : integer_start[9:0];stop_x<=integer_stop>CLIP_RIGHT ? CLIP_RIGHT+1 : integer_stop[9:0];end
                valid<=1;state<=OUTPUT_LINE;
            end
        end
        LINE_RANGE: begin
            integer_start<=rounded_start<rounded_stop ? rounded_start : rounded_stop;
            integer_stop<=rounded_start<rounded_stop ? rounded_stop : rounded_start;state<=LINE_ISSUE;
        end
        OUTPUT_LINE: if(valid && ready) begin
            valid<=0;
            if({1'b0,y}+10'd1>=last_y) state<=FINISH;
            else begin y<=y+1'b1;state<=LINE_ADVANCE;end
        end
        FINISH: begin done<=1;state<=IDLE;end
        endcase
        if(reset) begin
            state<=IDLE;valid<=0;done<=0;y<=0;start_x<=0;stop_x<=0;u<=0;v<=0;du<=0;dv<=0;
            active<=0;edge_index<=0;edge_low<=0;edge_high<=0;forward_edge<=0;backward_edge<=0;
            edge_operation<=0;edge_delta<=0;edge_reciprocal<=0;edge_dx<=0;
            min_vertex<=0;max_vertex<=0;compare_vertex<=0;maximum_y<=0;last_y<=0;forward_left<=0;parameter_v<=0;
            convert_input<=0;convert_round<=0;minimum_line<=0;maximum_line<=0;rounded_start<=0;rounded_stop<=0;
            instruction<=0;integer_start<=0;integer_stop<=0;
            for(i=0;i<4;i=i+1) begin
                vx[i]<=0;vy[i]<=0;origin[i]<=0;
            end
            load_index<=0;
        end
    end
endmodule
