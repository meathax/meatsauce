// SPDX-License-Identifier: BSD-3-Clause
// ES5510 ALU behavior derived from MAME 0.289 es5510.cpp,
// copyright Christian Brunschen. Execution scheduling and END are external.
module gs_es5510_alu(
    input wire [3:0] op,
    // Serial/DIL reads sign-extend to 32 bits in native MAME. Do not mask
    // them before flag calculation; destination register writes mask later.
    input wire [31:0] a,b,
    input wire [7:0] flags_in,
    output reg [31:0] result,
    output reg [7:0] flags_out
);
    reg [31:0] lhs,rhs,sum;
    reg overflow,negative;
    reg signed [31:0] shifted,shifted_right;
    always @* begin
        lhs=op==4'hd ? 32'h007fffff : a;
        rhs=(op==1 || op==3 || op==4 || op==13) ? {8'b0,(~b[23:0]+24'd1)} : b;
        sum=lhs+rhs;
        overflow=(lhs[23]==rhs[23]) && (lhs[23]!=sum[23]);
        negative=sum[23];
        shifted=$signed({{8{b[23]}},b[23:0]}) <<< (op==10 ? 2 : 8);
        shifted_right=$signed(b) >>> 1;
        result=0;flags_out=flags_in;
        case(op)
        0,1,2,3,4,13: begin
            result={8'b0,sum[23:0]};
            flags_out[7]=negative;
            flags_out[6]=sum[24];
            flags_out[5]=overflow;
            flags_out[4]=overflow ^ negative;
            flags_out[3]=sum[23:0]==0;
            if((op==0 || op==1) && overflow) begin
                result=a[23] ? 24'h800000 : 24'h7fffff;
                flags_out[7]=a[23];flags_out[3]=0;
            end
            if(op==4) result=a;
        end
        5,6,7: begin
            case(op)
            5: result=a & b;
            6: result=a | b;
            default: result=a ^ b;
            endcase
            flags_out[7]=result[23];flags_out[3]=result==0;
        end
        8: begin
            // Native ABS uses one's complement, not two's complement.
            result=b[23] ? (32'h00ffffff ^ b) : b;
            flags_out[7]=0;flags_out[6]=b[23];flags_out[3]=result[23:0]==0;
        end
        9: result=b;
        10,11: begin
            overflow=shifted>32'sh007fffff || shifted< -32'sh00800000;
            result=overflow ? (b[23] ? 24'h800000 : 24'h7fffff) : shifted[23:0];
            flags_out[6]=op==10 ? b[22] : b[16];
            flags_out[5]=overflow;
            flags_out[7]=result[23];flags_out[3]=result==0;
        end
        12: begin
            result={9'b0,b[7:0],15'b0};
            flags_out[7]=0;flags_out[6]=b[23];
        end
        14: begin
            result=shifted_right | {8'b0,b[23],23'b0};
            flags_out[7]=b[23];flags_out[6]=b[0];
        end
        default: result=0;
        endcase
    end
endmodule
