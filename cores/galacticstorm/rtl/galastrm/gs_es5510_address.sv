// SPDX-License-Identifier: BSD-3-Clause
// Exact MAME ES5510 RAM-cycle addresses; copyright Christian Brunschen.
// Cache floor(2^32 / denominator) for non-power-of-two delay rings. A 25-bit
// numerator's approximate quotient underestimates by at most one; one exact
// subtraction corrects it. Recompute only when the denominator changes.
module gs_es5510_address(
    input wire clk,reset,start,
    output wire ready,
    input wire [2:0] control,
    input wire [23:0] offset,dbase,dlength,abase,bbase,
    input wire [4:0] memshift,
    output reg valid,supported,io,
    output reg [1:0] cycle,
    output reg [23:0] address
);
    localparam [3:0] IDLE=0,CHOOSE=1,RECIPROCAL=2,MULTIPLY=3,QUOTIENT=4,
        REDUCE=5,CORRECT=6,PACK=7;
    reg [3:0] state=IDLE;
    reg [4:0] saved_shift;
    reg [23:0] saved_mask;
    reg [24:0] numerator,denominator,remainder;
    reg reciprocal_valid;
    reg [24:0] cached_denominator,reciprocal_remainder;
    reg [32:0] reciprocal,reciprocal_bits,reciprocal_quotient;
    reg [5:0] remaining;
    reg [57:0] product;
    reg [50:0] quotient_product;
    wire delay_access=control==0 || control==1 || control==5;
    wire [23:0] base=delay_access ? dbase:(control==4 ? bbase:abase);
    wire [24:0] input_numerator={1'b0,base}+{1'b0,offset};
    wire [24:0] input_denominator={1'b0,dlength}+(25'd1 << memshift);
    wire [24:0] denominator_mask=denominator-25'd1;
    wire power_two=(denominator & denominator_mask)==0;
    wire [25:0] reciprocal_trial={reciprocal_remainder,reciprocal_bits[32]};
    wire [25:0] reciprocal_subtract=reciprocal_trial-{1'b0,denominator};
    wire [32:0] next_reciprocal={reciprocal_quotient[31:0],!reciprocal_subtract[25]};
    wire [25:0] correction={1'b0,remainder}-{1'b0,denominator};
    assign ready=state==IDLE && !reset;
    always @(posedge clk)begin
        valid<=0;
        case(state)
            IDLE:if(start && ready)begin
                io<=control>=6;
                cycle<=control==5 ? 2'd2:((control==1 || control==3 || control==7) ? 2'd1:2'd0);
                supported<=memshift<=24;saved_shift<=memshift;saved_mask<=24'hffffff << memshift;
                numerator<=input_numerator;denominator<=input_denominator;
                if(memshift>24)begin address<=0;valid<=1;end
                else if(control>=6)begin address<=offset & 24'hfffff0;valid<=1;end
                else if(!delay_access)begin remainder<=input_numerator;state<=PACK;end
                else state<=CHOOSE;
            end
            CHOOSE:begin
                if(power_two)begin remainder<=numerator & denominator_mask;state<=PACK;end
                else if(reciprocal_valid && cached_denominator==denominator)state<=MULTIPLY;
                else begin
                    reciprocal_bits<=33'h100000000;reciprocal_quotient<=0;
                    reciprocal_remainder<=0;remaining<=33;state<=RECIPROCAL;
                end
            end
            RECIPROCAL:begin
                reciprocal_remainder<=reciprocal_subtract[25] ? reciprocal_trial[24:0]:reciprocal_subtract[24:0];
                reciprocal_quotient<=next_reciprocal;reciprocal_bits<={reciprocal_bits[31:0],1'b0};
                remaining<=remaining-1'b1;
                if(remaining==1)begin
                    reciprocal<=next_reciprocal;cached_denominator<=denominator;
                    reciprocal_valid<=1;state<=MULTIPLY;
                end
            end
            MULTIPLY:begin product<=numerator*reciprocal;state<=QUOTIENT;end
            QUOTIENT:begin quotient_product<=product[57:32]*denominator;state<=REDUCE;end
            REDUCE:begin remainder<=numerator-quotient_product[24:0];state<=CORRECT;end
            CORRECT:begin
                if(!correction[25])remainder<=correction[24:0];
                state<=PACK;
            end
            PACK:begin address<=(remainder[23:0] & saved_mask)>>saved_shift;valid<=1;state<=IDLE;end
            default:state<=IDLE;
        endcase
        if(reset)begin
            state<=IDLE;saved_shift<=0;saved_mask<=0;numerator<=0;denominator<=0;remainder<=0;
            reciprocal_valid<=0;cached_denominator<=0;reciprocal<=0;reciprocal_bits<=0;
            reciprocal_quotient<=0;reciprocal_remainder<=0;remaining<=0;product<=0;quotient_product<=0;
            valid<=0;supported<=1;io<=0;cycle<=0;address<=0;
        end
    end
endmodule
