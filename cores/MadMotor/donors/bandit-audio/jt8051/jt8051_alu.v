/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later */

module jt8051_alu(
    input      [ 4:0] alu_sel,
    input      [ 7:0] lhs,
    input      [ 7:0] rhs,
    input             carry,
    input             aux_carry,
    input      [ 2:0] bitno,
    output reg [ 7:0] result,
    output reg [ 7:0] aux,
    output reg        cy,
    output reg        ac,
    output reg        ov,
    output reg        neq
);

`include "jt8051_param.vh"

reg [ 8:0] sum;
reg [15:0] product;
reg [ 7:0] rem8;
reg [ 7:0] quo;
reg [ 9:0] div1, div2, div3;

function [9:0] div_step;
    input [7:0] rem_in;
    input [1:0] in_bits;
    input [9:0] d1;
    input [9:0] d2;
    input [9:0] d3;
    reg   [9:0] partial;
    reg   [10:0] diff1, diff2, diff3;
    reg   [7:0] rem_out;
    reg          ge1, ge2, ge3;
    reg   [1:0] quotient_digit;
    begin
        partial = {rem_in,in_bits};
        // The extended MSB is borrow, so compare and difference share each
        // subtraction instead of serializing compare, priority select and subtract.
        diff1 = {1'b0,partial} - {1'b0,d1};
        diff2 = {1'b0,partial} - {1'b0,d2};
        diff3 = {1'b0,partial} - {1'b0,d3};
        ge1 = !diff1[10];
        ge2 = !diff2[10];
        ge3 = !diff3[10];
        if (ge3) begin
            rem_out = diff3[7:0];
            quotient_digit = 2'd3;
        end else if (ge2) begin
            rem_out = diff2[7:0];
            quotient_digit = 2'd2;
        end else if (ge1) begin
            rem_out = diff1[7:0];
            quotient_digit = 2'd1;
        end else begin
            rem_out = partial[7:0];
            quotient_digit = 2'd0;
        end
        div_step = {rem_out,quotient_digit};
    end
endfunction

always @* begin
    result  = lhs;
    aux     = 8'd0;
    sum     = 9'd0;
    product = 16'd0;
    rem8    = 8'd0;
    quo     = 8'd0;
    div1    = 10'd0;
    div2    = 10'd0;
    div3    = 10'd0;
    cy      = 1'b0;
    ac      = 1'b0;
    ov      = 1'b0;
    neq     = lhs != rhs;
    case (alu_sel)
        ADD_ALU: begin
            sum    = {1'b0,lhs}+{1'b0,rhs};
            result = sum[7:0];
            cy     = sum[8];
            ac     = {1'b0,lhs[3:0]}+{1'b0,rhs[3:0]} > 5'h0f;
            ov     = ~(lhs[7]^rhs[7]) & (lhs[7]^result[7]);
        end
        ADDC_ALU: begin
            sum    = {1'b0,lhs}+{1'b0,rhs}+{8'd0,carry};
            result = sum[7:0];
            cy     = sum[8];
            ac     = {1'b0,lhs[3:0]}+{1'b0,rhs[3:0]}+{4'd0,carry} > 5'h0f;
            ov     = ~(lhs[7]^rhs[7]) & (lhs[7]^result[7]);
        end
        SUBB_ALU: begin
            sum    = {1'b0,lhs}-{1'b0,rhs}-{8'd0,carry};
            result = sum[7:0];
            cy     = sum[8];
            ac     = {1'b0,lhs[3:0]} < ({1'b0,rhs[3:0]}+{4'd0,carry});
            ov     = (lhs[7]^rhs[7]) & (lhs[7]^result[7]);
        end
        OR_ALU:    result = lhs | rhs;
        AND_ALU:   result = lhs & rhs;
        XOR_ALU:   result = lhs ^ rhs;
        INC_ALU:   result = lhs + 8'd1;
        DEC_ALU:   result = lhs - 8'd1;
        RR_ALU:    result = {lhs[0],lhs[7:1]};
        RL_ALU:    result = {lhs[6:0],lhs[7]};
        RRC_ALU: begin result = {carry,lhs[7:1]}; cy = lhs[0]; end
        RLC_ALU: begin result = {lhs[6:0],carry}; cy = lhs[7]; end
        SWAP_ALU:  result = {lhs[3:0],lhs[7:4]};
        XCHD_ALU: begin
            result = {rhs[7:4],lhs[3:0]};
            aux    = {lhs[7:4],rhs[3:0]};
        end
        CPL_ALU:   result = ~lhs;
        CMP_ALU: begin
            sum = {1'b0,lhs}-{1'b0,rhs};
            result = sum[7:0];
            cy = sum[8];
        end
        DA_ALU: begin
            sum = {1'b0,lhs};
            if (aux_carry || lhs[3:0]>4'd9) sum = sum+9'h006;
            if (carry || sum>9'h099) sum = sum+9'h060;
            result = sum[7:0];
            cy = carry | sum[8];
        end
        MUL_ALU: begin
            product = lhs*rhs;
            result  = product[7:0];
            aux     = product[15:8];
            ov      = |product[15:8];
        end
        DIV_ALU: begin
            if (rhs==0) begin
                result = lhs;
                aux    = rhs;
                ov     = 1'b1;
            end else begin
                div1 = {2'b00,rhs};
                div2 = div1 << 1;
                div3 = div1 + div2;
                {rem8,quo[7:6]} = div_step(8'd0,lhs[7:6],div1,div2,div3);
                {rem8,quo[5:4]} = div_step(rem8,lhs[5:4],div1,div2,div3);
                {rem8,quo[3:2]} = div_step(rem8,lhs[3:2],div1,div2,div3);
                {rem8,quo[1:0]} = div_step(rem8,lhs[1:0],div1,div2,div3);
                result = quo;
                aux    = rem8;
            end
        end
        default: ;
    endcase
end

endmodule
