// SPDX-License-Identifier: BSD-3-Clause
// Pinned MAME galastrm.cpp transformed quad, separate binary32 operations.
// Scalar setup only. Extents, texture reads and previous-frame surfaces follow.
module gs_tc0610_vertices #(parameter EXTERNAL_FP=0) (
    input wire clk,reset,query,
    output wire query_ready,
    input wire signed [15:0] rzx,rzy,
    output reg valid,
    input wire ready,
    output reg empty,
    output reg [255:0] vertices,
    output wire [1:0] unit_operation,
    output wire [31:0] unit_a,unit_b,
    output wire unit_a_stb,unit_b_stb,unit_z_ack,
    input wire unit_a_ack,unit_b_ack,unit_z_valid,
    input wire [31:0] unit_z
);
    localparam IDLE=0,LAUNCH=1,WAIT_COEFF=2,PREP=3,SEND_A=4,SEND_B=5,WAIT_FP=6;
    reg [2:0] state;
    reg signed [15:0] saved_x,saved_y;
    reg [20:0] count_x,count_y;
    reg [31:0] cosine,sine,operand_a,operand_b,product_a,product_b,sum;
    reg [1:0] vertex,operation;
    reg component;
    wire coefficient_ready,coefficient_valid,coefficient_empty;
    wire [20:0] coefficient_x,coefficient_y;
    wire [31:0] coefficient_cosine,coefficient_sine;
    wire [31:0] mul_z,add_z;
    wire mul_a_ack,mul_b_ack,mul_valid,add_a_ack,add_b_ack,add_valid;
    wire multiply=operation<2;
    wire fp_a_ack=multiply ? mul_a_ack : add_a_ack;
    wire fp_b_ack=multiply ? mul_b_ack : add_b_ack;
    wire fp_valid=multiply ? mul_valid : add_valid;
    wire [31:0] fp_z=multiply ? mul_z : add_z;
    wire signed [21:0] a_integer=vertex<2 ?
        -$signed({1'b0,count_x}) : $signed({1'b0,count_x})-22'sd1;
    wire signed [21:0] b_integer=(vertex==0 || vertex==3) ?
        -$signed({1'b0,count_y}) : $signed({1'b0,count_y})-22'sd1;
    function automatic [31:0] integer_float(input signed [21:0] value);
        reg [21:0] magnitude;
        reg [31:0] shifted;
        reg [4:0] lead;
        reg [7:0] exponent;
        integer i;
        begin
            magnitude=value[21] ? -value : value;
            lead=0;
            for(i=0;i<22;i=i+1) if(magnitude[i]) lead=i[4:0];
            shifted={10'b0,magnitude}<<(23-lead);
            exponent=8'd127+lead;
            integer_float=value==0 ? 32'b0 : {value[21],exponent,shifted[22:0]};
        end
    endfunction
    assign query_ready=state==IDLE && !valid;
    gs_tc0610_coeff coefficients(
        .clk(clk),.reset(reset),.query(state==LAUNCH),.query_ready(coefficient_ready),
        .rzx(saved_x),.rzy(saved_y),.valid(coefficient_valid),.ready(state==WAIT_COEFF),
        .empty(coefficient_empty),.zx(coefficient_x),.zy(coefficient_y),
        .zcs(coefficient_cosine),.zsn(coefficient_sine)
    );
    assign unit_operation=multiply ? 2'd1 : 2'd0;
    assign unit_a=operand_a;
    assign unit_b=operand_b;
    assign unit_a_stb=state==SEND_A;
    assign unit_b_stb=state==SEND_B;
    assign unit_z_ack=state==WAIT_FP;
    generate if(EXTERNAL_FP) begin: external_unit
        assign mul_a_ack=unit_a_ack;
        assign add_a_ack=unit_a_ack;
        assign mul_b_ack=unit_b_ack;
        assign add_b_ack=unit_b_ack;
        assign mul_valid=unit_z_valid;
        assign add_valid=unit_z_valid;
        assign mul_z=unit_z;
        assign add_z=unit_z;
    end else begin: local_units
    multiplier multiply_unit(
        .clk(clk),.rst(reset),.input_a(operand_a),.input_b(operand_b),
        .input_a_stb(state==SEND_A && multiply),.input_b_stb(state==SEND_B && multiply),
        .input_a_ack(mul_a_ack),.input_b_ack(mul_b_ack),
        .output_z(mul_z),.output_z_stb(mul_valid),
        .output_z_ack(state==WAIT_FP && multiply)
    );
    adder add_unit(
        .clk(clk),.rst(reset),.input_a(operand_a),.input_b(operand_b),
        .input_a_stb(state==SEND_A && !multiply),.input_b_stb(state==SEND_B && !multiply),
        .input_a_ack(add_a_ack),.input_b_ack(add_b_ack),
        .output_z(add_z),.output_z_stb(add_valid),
        .output_z_ack(state==WAIT_FP && !multiply)
    );
    end endgenerate
    always @(posedge clk) begin
        if(valid && ready) valid<=0;
        case(state)
        IDLE: if(query && query_ready) begin saved_x<=rzx;saved_y<=rzy;state<=LAUNCH;end
        LAUNCH: if(coefficient_ready) state<=WAIT_COEFF;
        WAIT_COEFF: if(coefficient_valid) begin
            empty<=coefficient_empty;
            if(coefficient_empty) begin vertices<=0;valid<=1;state<=IDLE;end
            else begin
                count_x<=coefficient_x;count_y<=coefficient_y;
                cosine<=coefficient_cosine;sine<=coefficient_sine;
                vertex<=0;component<=0;operation<=0;state<=PREP;
            end
        end
        PREP: begin
            case(operation)
            0: begin operand_a<=integer_float(a_integer);operand_b<=component ? sine : cosine;end
            1: begin operand_a<=integer_float(b_integer);operand_b<=component ? cosine : sine;end
            2: begin operand_a<=product_a;operand_b<=component ? product_b : {~product_b[31],product_b[30:0]};end
            3: begin operand_a<=sum;operand_b<=component ? 32'h43480000 : 32'h43800000;end
            endcase
            state<=SEND_A;
        end
        SEND_A: if(fp_a_ack) state<=SEND_B;
        SEND_B: if(fp_b_ack) state<=WAIT_FP;
        WAIT_FP: if(fp_valid) begin
            state<=PREP;
            case(operation)
            0: begin product_a<=fp_z;operation<=1;end
            1: begin product_b<=fp_z;operation<=2;end
            2: begin sum<=fp_z;operation<=3;end
            3: begin
                vertices[{vertex,component,5'b0} +: 32]<=fp_z;
                operation<=0;
                if(!component) component<=1;
                else begin
                    component<=0;
                    if(vertex==3) begin valid<=1;state<=IDLE;end
                    else vertex<=vertex+1'b1;
                end
            end
            endcase
        end
        endcase
        if(reset) begin
            state<=IDLE;valid<=0;empty<=1;vertices<=0;
            saved_x<=0;saved_y<=0;count_x<=0;count_y<=0;cosine<=0;sine<=0;
            operand_a<=0;operand_b<=0;product_a<=0;product_b<=0;sum<=0;
            vertex<=0;component<=0;operation<=0;
        end
    end
endmodule
