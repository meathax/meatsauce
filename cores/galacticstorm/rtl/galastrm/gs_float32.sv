// SPDX-License-Identifier: BSD-3-Clause
// Held-command wrapper for immutable MIT donor scalar binary32 operations.
module gs_float32 #(parameter EXTERNAL_FP=0) (
    input wire clk,reset,request,
    output wire request_ready,
    input wire [1:0] operation, // 0 add, 1 multiply, 2 divide
    input wire [31:0] a,b,
    output reg valid,
    input wire ready,
    output reg [31:0] result,
    output wire [1:0] unit_operation,
    output wire [31:0] unit_a,unit_b,
    output wire unit_a_stb,unit_b_stb,unit_z_ack,
    input wire unit_a_ack,unit_b_ack,unit_z_valid,
    input wire [31:0] unit_z
);
    localparam IDLE=0,SEND_A=1,SEND_B=2,WAIT_RESULT=3;
    reg [1:0] state,op;
    reg [31:0] saved_a,saved_b;
    wire [2:0] a_ack,b_ack,z_valid;
    wire [31:0] z[0:2];
    assign request_ready=state==IDLE && !valid;
    assign unit_operation=op;
    assign unit_a=saved_a;
    assign unit_b=saved_b;
    assign unit_a_stb=state==SEND_A;
    assign unit_b_stb=state==SEND_B;
    assign unit_z_ack=state==WAIT_RESULT;
    generate if(EXTERNAL_FP) begin: external_unit
        assign a_ack={3{unit_a_ack}};
        assign b_ack={3{unit_b_ack}};
        assign z_valid={3{unit_z_valid}};
        assign z[0]=unit_z;
        assign z[1]=unit_z;
        assign z[2]=unit_z;
    end else begin: local_units
    adder addition(
        .clk(clk),.rst(reset),.input_a(saved_a),.input_b(saved_b),
        .input_a_stb(state==SEND_A && op==0),.input_b_stb(state==SEND_B && op==0),
        .input_a_ack(a_ack[0]),.input_b_ack(b_ack[0]),.output_z(z[0]),
        .output_z_stb(z_valid[0]),.output_z_ack(state==WAIT_RESULT && op==0));
    multiplier multiplication(
        .clk(clk),.rst(reset),.input_a(saved_a),.input_b(saved_b),
        .input_a_stb(state==SEND_A && op==1),.input_b_stb(state==SEND_B && op==1),
        .input_a_ack(a_ack[1]),.input_b_ack(b_ack[1]),.output_z(z[1]),
        .output_z_stb(z_valid[1]),.output_z_ack(state==WAIT_RESULT && op==1));
    divider division(
        .clk(clk),.rst(reset),.input_a(saved_a),.input_b(saved_b),
        .input_a_stb(state==SEND_A && op==2),.input_b_stb(state==SEND_B && op==2),
        .input_a_ack(a_ack[2]),.input_b_ack(b_ack[2]),.output_z(z[2]),
        .output_z_stb(z_valid[2]),.output_z_ack(state==WAIT_RESULT && op==2));
    end endgenerate
    always @(posedge clk) begin
        if(valid && ready) valid<=0;
        case(state)
        IDLE: if(request && request_ready) begin
            op<=operation;saved_a<=a;saved_b<=b;state<=SEND_A;
        end
        SEND_A: if(a_ack[op]) state<=SEND_B;
        SEND_B: if(b_ack[op]) state<=WAIT_RESULT;
        WAIT_RESULT: if(z_valid[op]) begin result<=z[op];valid<=1;state<=IDLE;end
        endcase
        if(reset) begin state<=IDLE;op<=0;saved_a<=0;saved_b<=0;result<=0;valid<=0;end
    end
endmodule
