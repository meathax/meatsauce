/*
 * Konami 054000 collision/security device - Bucky O'Hare integration model.
 *
 * This is an independent behavioral implementation based on the documented
 * register interface, the GX173 software-visible behavior and MAME's BSD-3
 * behavioral contract. It does not copy or link SiliconRE's GPL-2.0 HDL.
 *
 * The physical part has no reset pin. The game writes all eighteen mapped
 * bytes before relying on the result, so this model deliberately has no reset.
 */
module bucky_k054000(
    input             clk,
    input             cs,
    input             we,
    input      [ 4:0] addr,
    input      [ 7:0] din,
    output     [ 7:0] dout
);

reg [7:0] r01, r02, r03, r04, r06, r07;
reg [7:0] r09, r0a, r0b, r0c, r0e, r0f;
reg [7:0] r11, r12, r13, r15, r16, r17;

always @(posedge clk) begin
    if (cs && we) begin
        case (addr)
            5'h01: r01 <= din;
            5'h02: r02 <= din;
            5'h03: r03 <= din;
            5'h04: r04 <= din;
            5'h06: r06 <= din;
            5'h07: r07 <= din;
            5'h09: r09 <= din;
            5'h0a: r0a <= din;
            5'h0b: r0b <= din;
            5'h0c: r0c <= din;
            5'h0e: r0e <= din;
            5'h0f: r0f <= din;
            5'h11: r11 <= din;
            5'h12: r12 <= din;
            5'h13: r13 <= din;
            5'h15: r15 <= din;
            5'h16: r16 <= din;
            5'h17: r17 <= din;
            default: ;
        endcase
    end
end

wire signed [24:0] acx = $signed({1'b0,r01,r02,r03}) + $signed({{17{r04[7]}},r04});
wire signed [24:0] acy = $signed({1'b0,r09,r0a,r0b}) + $signed({{17{r0c[7]}},r0c});
wire signed [24:0] bcx = $signed({1'b0,r15,r16,r17});
wire signed [24:0] bcy = $signed({1'b0,r11,r12,r13});
wire signed [24:0] dx  = acx - bcx;
wire signed [24:0] dy  = acy - bcy;

function axis_miss;
    input signed [24:0] delta;
    input        [ 7:0] axis_a;
    input        [ 7:0] axis_b;
    reg          [24:0] magnitude;
    reg          [ 8:0] extent;
    begin
        magnitude = delta[24] ? -delta : delta;
        extent    = {1'b0,axis_a} + {1'b0,axis_b};
        axis_miss = (delta > 25'sd511) || (delta <= -25'sd1024) ||
                    (magnitude[8:0] > extent[8:0]);
    end
endfunction

wire miss = axis_miss(dx,r06,r0e) | axis_miss(dy,r07,r0f);

// Only D0 is driven by the physical chip. The GX173 low-byte bus wrapper
// supplies defined zeroes for the otherwise unused bits presented to the CPU.
assign dout = (cs && !we && addr==5'h18) ? {7'd0,miss} : 8'h00;

endmodule
