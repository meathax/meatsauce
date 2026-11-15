// ES5510 ESP Rev.2.4, printed pp7-10,19. No MAME/donor implementation.
// CCR bits: N C V LT Z in [7:3]; other bits are preserved here.
// Carry on subtraction follows the unsigned comparison/mask tables pp24-25
// (borrow). p9's parenthetical "no-borrow" conflicts with those tables;
// parameterize that unresolved silicon question instead of hiding it.
module rf_es5510_alu #(
    parameter SUB_CARRY_IS_BORROW = 1
)(
    input wire [3:0] opcode,
    input wire signed [23:0] a,b,
    input wire [7:0] ccr,
    output reg [23:0] result,
    output reg [7:0] next_ccr,
    output wire write_result
);
    reg [24:0] unsigned_sum;
    reg signed [31:0] wide;
    reg [23:0] lhs;
    reg overflow,carry,arithmetic;
    assign write_result = opcode != 4'h4 && opcode != 4'hf;
    always @* begin
        result=b;next_ccr=ccr;wide=0;unsigned_sum=0;
        lhs=a;overflow=0;carry=0;arithmetic=0;
        case(opcode)
            4'h0,4'h2:begin
                unsigned_sum={1'b0,a}+{1'b0,b};
                wide={{8{a[23]}},a};wide=wide+$signed(b);
                overflow=(wide>32'sd8388607 || wide < -32'sd8388608);
                carry=unsigned_sum[24];result=wide[23:0];arithmetic=1;
                if(opcode==0 && overflow)result=wide[31]?24'h800000:24'h7fffff;
            end
            4'h1,4'h3,4'h4,4'hd:begin
                // DIFF is unsaturated per its detailed description p9 and
                // opcode table p19; the summary table p7 says otherwise.
                if(opcode==4'hd)lhs=24'h7fffff;
                wide={{8{lhs[23]}},lhs};wide=wide-$signed(b);
                overflow=(wide>32'sd8388607 || wide < -32'sd8388608);
                carry=SUB_CARRY_IS_BORROW ? (lhs < $unsigned(b)) : (lhs >= $unsigned(b));
                result=wide[23:0];arithmetic=1;
                if(opcode==1 && overflow)result=wide[31]?24'h800000:24'h7fffff;
            end
            4'h5:begin result=a&b;next_ccr[7]=result[23];next_ccr[3]=(result==0);end
            4'h6:begin result=a|b;next_ccr[7]=result[23];next_ccr[3]=(result==0);end
            4'h7:begin result=a^b;next_ccr[7]=result[23];next_ccr[3]=(result==0);end
            4'h8:begin result=b[23]?~b:b;next_ccr[7]=0;next_ccr[6]=b[23];end
            4'h9:result=b;
            4'ha,4'hb:begin
                wide={{8{b[23]}},b};wide=wide <<< (opcode==4'ha ? 2 : 8);
                overflow=(wide>32'sd8388607 || wide < -32'sd8388608);
                result=overflow?(wide[31]?24'h800000:24'h7fffff):wide[23:0];
                next_ccr[7]=result[23];next_ccr[5]=overflow;next_ccr[3]=(result==0);
            end
            4'hc:begin result={1'b0,b[7:0],15'd0};next_ccr[7]=0;next_ccr[6]=b[8];end
            4'he:begin result={b[23],b[23:1]};next_ccr[7]=b[23];next_ccr[6]=b[0];end
            default:result=0;
        endcase
        if(arithmetic)begin
            next_ccr[7]=result[23];next_ccr[6]=carry;next_ccr[5]=overflow;
            next_ccr[4]=result[23]^overflow;next_ccr[3]=(result==0);
        end
    end
endmodule
