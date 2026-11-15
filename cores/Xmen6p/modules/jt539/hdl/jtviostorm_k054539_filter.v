// SPDX-License-Identifier: GPL-2.0-only
// Source-derived arithmetic and sequencer: furrtek, 2025.
// Based on SiliconRE/Konami/054539/hdl at the pinned commit below.
// Full license: k054539_roms.LICENSE; applies to this source and ROM assets.
//
// Exact split-product primitive from the public physical 054539 wiring.
// furrtek/SiliconRE c926ce92fdebd7613c8712b42c45a059d63548e0:
// 054539.v:767-788, 1584-1597, 1633-1644; schematic sheets20 and34.
// Physical endpoint checks: G17/C19, G20/C21, J61 and F40 in k054539.SDF.
// State operations below retain the chip's split-product ALU and slot order.
// Evidence is the public physical transcription plus inspected net endpoints;
// this does not assert agreement with a captured PCB digital output stream.
module jtviostorm_k054539_mula (
    input [7:0] coefficient,
    input [30:0] value,
    output [30:0] signed_value,
    output [30:0] unsigned_value
);
wire signed [8:0] coefficient_signed = {1'b0, coefficient};
wire signed [24:0] high_signed_full = coefficient_signed * $signed(value[30:15]);
wire [23:0] high_signed = high_signed_full[23:0];
wire [23:0] high_unsigned = coefficient * value[30:15];
wire [23:0] low_product = coefficient * {1'b0, value[14:0]};
wire [23:0] high_signed_sum = high_signed + {14'd0, low_product[23:14]};
wire [23:0] high_unsigned_sum = high_unsigned + {14'd0, low_product[23:14]};
assign signed_value = {high_signed_sum, low_product[13:7]};
assign unsigned_value = {high_unsigned_sum, low_product[13:7]};
endmodule

// Literal 384-slot voice-filter sequencer. The shared RAM word interface uses
// RAMB as bits7:0 and RAMA as bits15:8. Internal words0B/0C contain p,0D/0E q;
// each low word is {state[14:0],0}, each high word is state[30:15]. Do not clear
// these words at key-off: the physical late writes continue for inactive voices.
// The decoder determines the inactive input (PCM zero; DPCM previous sample).
//
// cen is the native 18.432MHz positive-edge enable in the faster host clock.
// Its negative half is serviced on the following host edge. Enables must have
// at least one intervening host cycle. This preserves edge order, not analog
// clock duty. The 384-slot counter makes one frame per 48kHz nominal interval.
// A missing decode response stalls at slot25/26 without losing state or a write;
// this integration accommodation is not a measured external-ROM wait protocol.
//
// Sources: public 054539.v:299-332,763-788,979-1123,1134-1139,1567-1737;
// ROMA is the public chip dump. E51 uses delayed bit3, as wired physically in
// E52/E53, rather than the undelayed bit3 in the published functional HDL.
// Software mode {CPU5,CPU4}:0=C,1=Q,2=B,3=A; both physical mux outputs invert
// in the two-mux mode path (schematic sheet18), so these inversions cancel.
module jtviostorm_k054539_filter_slots #(
    parameter ROMA_FILE = "k054539_roma.hex"
) (
    input             clk,
    input             rst,
    input             cen,
    input             inhibit_state_write,
    input      [7:0]  active_channels,
    output reg        decoded_sample_request,
    output reg [2:0]  decoded_sample_channel,
    input             decoded_sample_valid,
    input      [15:0] decoded_sample,
    output            stalled,
    output reg [6:0]  ram_address,
    input      [15:0] ram_word,
    output reg        ram_write,
    output reg [6:0]  ram_write_address,
    output reg [15:0] ram_write_word,
    output reg        raw_ram_write,
    output reg [6:0]  raw_ram_write_address,
    output     [2:0]  tap_channel,
    input      [1:0]  tap_mode,
    output reg        sample_valid,
    output reg [2:0]  sample_channel,
    output reg [15:0] sample_value,
    output reg [8:0]  raw_slot,
    output reg [8:0]  delayed_slot
);
    // The public image includes 128 padding words after the 384 chip steps.
    reg [6:0] roma [0:511];
    initial $readmemh(ROMA_FILE, roma);
    reg [6:0] roma_data;
    reg negative_due;
    reg decoded_ready;
    reg [15:0] decoded_buffer;
    reg [15:0] sample_latch;
    reg [7:0] coefficient_even, coefficient_odd;
    reg [30:0] state_a,state_b,state_c,state_d,state_p,state_q;
    reg [23:0] product_previous, product_sum;
    reg [6:0] product_fraction;
    reg e51,e54,f68,f73,f66,f71,d62,d67;
    reg trig_a,trig_b,trig_c,trig_d,trig_e,trig_f,trig_g,trig_j;
    reg p91,write_due,raw_write_due;
    reg [15:0] p_low,p_high,q_low,q_high,write_data;

    wire need_decode = delayed_slot[8:5] < 4'd8 &&
                       (delayed_slot[4:0] == 5'd25 || delayed_slot[4:0] == 5'd26);
    assign stalled = negative_due && need_decode && !decoded_ready;
    assign tap_channel = raw_slot[7:5] - 3'd1;
    wire [8:0] next_raw = raw_slot == 9'd383 ? 9'd0 : raw_slot + 9'd1;
    wire edge_d0 = !delayed_slot[0] && raw_slot[0];
    wire edge_d1 = !delayed_slot[1] && raw_slot[1];
    wire edge_d4 = !delayed_slot[4] && raw_slot[4];
    wire select_lower = raw_slot[1] ^ e54;
    wire [30:0] multiply_state = e51 ? state_a : state_d;
    wire signed [15:0] multiply_word = select_lower ?
                        {1'b0,multiply_state[14:0]} : multiply_state[30:15];
    wire signed [8:0] multiply_coefficient =
                        {1'b0,trig_e ? coefficient_even : coefficient_odd};
    wire signed [24:0] multiply_full = multiply_word * multiply_coefficient;
    wire [23:0] multiply_product = multiply_full[23:0];
    wire [30:0] alu_result;
    wire [15:0] tap_sample,alu_low,alu_high;
    jtviostorm_k054539_filter_alu alu(
        .previous_product(product_sum),
        .current_product({10'd0,product_fraction,7'd0}),
        .state_a(state_a),.state_b(state_b),.state_c(state_c),
        .state_d(state_d),.state_p(state_p),.state_q(state_q),
        .sample(sample_latch),.select_f3(!f66),.select_f17(!f71),
        .select_d62(d62),.trig_f(trig_f),.trig_g(trig_g),
        .invert_b(!(trig_a && trig_j)),
        .tap_select({tap_mode[0],tap_mode[1]}),
        .recombined_product(),.adder_result(alu_result),
        .tap_sample(tap_sample),.result_low_word(alu_low),
        .result_high_word(alu_high));
    wire h69 = raw_slot[2] && !raw_slot[1];
    wire h70 = raw_slot[2] && !raw_slot[0];
    wire [15:0] next_write_data = h69 ? (h70 ? p_high : q_low) :
                                                     (h70 ? q_high : p_low);
    wire filter_write_phase = raw_slot[4] && raw_slot[3] &&
                              (raw_slot[2] || raw_slot[1]);
    // P89B raw writes are active-only and restricted to voice groups0..7.
    // P87 samples that gate on the positive native edge; P86 applies D7
    // live during the following negative half. Data/address register delays
    // give word06/07/08/09/0A at delayed phases20/21/22/24/25. Phase23 is
    // CPU access. The caller supplies the word from its decoded voice buffer.
    wire raw_write_phase = !raw_slot[8] && raw_slot[4] &&
                           (raw_slot[3] || raw_slot[2]) && !filter_write_phase;

    always @(posedge clk) begin
        decoded_sample_request <= 1'b0;
        ram_write <= 1'b0;
        raw_ram_write <= 1'b0;
        sample_valid <= 1'b0;
        if (rst) begin
            raw_slot<=0;delayed_slot<=0;roma_data<=0;ram_address<=0;
            negative_due<=0;decoded_ready<=0;decoded_buffer<=0;
            sample_latch<=0;coefficient_even<=0;coefficient_odd<=0;
            state_a<=0;state_b<=0;state_c<=0;state_d<=0;state_p<=0;state_q<=0;
            product_previous<=0;product_sum<=0;product_fraction<=0;
            e51<=0;e54<=1;f68<=0;f73<=0;f66<=0;f71<=0;d62<=0;d67<=1;
            trig_a<=1;trig_b<=1;trig_c<=1;trig_d<=1;trig_e<=1;
            trig_f<=1;trig_g<=1;trig_j<=1;
            p91<=0;write_due<=0;raw_write_due<=0;write_data<=0;
            p_low<=0;p_high<=0;q_low<=0;q_high<=0;
            decoded_sample_channel<=0;ram_write_address<=0;ram_write_word<=0;
            raw_ram_write_address<=0;
            sample_channel<=0;sample_value<=0;
        end else begin
            if (decoded_sample_valid) begin
                decoded_buffer <= decoded_sample;
                decoded_ready <= 1'b1;
            end
            if (negative_due) begin
                if (!stalled) begin
                    negative_due <= 1'b0;
                    case (delayed_slot[4:0])
                        5'd13: begin
                            coefficient_even<=ram_word[7:0];
                            coefficient_odd<=ram_word[15:8];
                        end
                        5'd14: state_p[14:0]<=ram_word[15:1];
                        5'd16: state_p[30:15]<=ram_word;
                        5'd17: state_q[14:0]<=ram_word[15:1];
                        5'd18: state_q[30:15]<=ram_word;
                        5'd26: begin
                            sample_latch<=delayed_slot[8:5]<4'd8 ? decoded_buffer : 16'd0;
                            decoded_ready<=1'b0;
                        end
                        default: ;
                    endcase
                    if (!(trig_j && d67)) state_a<=alu_result;
                    if (!trig_d) state_b<=alu_result;
                    if (!trig_a) state_c<=alu_result;
                    if (!trig_f) state_d<=alu_result;
                    if (!trig_b) begin p_low<=alu_low;p_high<=alu_high;end
                    if (!trig_c) begin q_low<=alu_low;q_high<=alu_high;end
                    if (write_due && !inhibit_state_write &&
                        ram_address[3:0]>=4'hb && ram_address[3:0]<=4'he) begin
                        ram_write<=1'b1;ram_write_address<=ram_address;
                        ram_write_word<=write_data;
                    end
                    if (raw_write_due && !inhibit_state_write &&
                        ram_address[3:0]>=4'h6 && ram_address[3:0]<=4'ha) begin
                        raw_ram_write<=1'b1;raw_ram_write_address<=ram_address;
                    end
                end
            end else if (cen) begin
                negative_due<=1'b1;
                raw_slot<=next_raw;
                delayed_slot<=raw_slot;
                roma_data<=roma[raw_slot];
                ram_address<=delayed_slot[1] && !delayed_slot[0] ? 7'd0 : roma_data;
                write_data<=next_write_data;
                write_due<=filter_write_phase && p91;
                raw_write_due<=raw_write_phase && active_channels[delayed_slot[7:5]];
                if (!raw_slot[5] && next_raw[5]) p91<=!next_raw[8];
                if (raw_slot[4:0]==0 && raw_slot[8:5]<4'd8) begin
                    decoded_sample_request<=1'b1;
                    decoded_sample_channel<=raw_slot[7:5];
                    // A response belongs to this request, not an earlier voice.
                    decoded_ready<=1'b0;
                end
                if (edge_d1) begin
                    f68<=!raw_slot[4] || !(|raw_slot[3:2]);
                    f73<=raw_slot[3];
                end
                if (edge_d0) begin
                    // E51 D input is delayed counter bit3, unlike public HDL.
                    e51<=(raw_slot[4]^raw_slot[2]) | raw_slot[3];
                    f66<=f68;f71<=f73;
                    d62<=((raw_slot[1] && raw_slot[3]) || !raw_slot[4]) &&
                          (raw_slot[1] || raw_slot[4]);
                    trig_a<=raw_slot[4:1]!=4'b0000;
                    trig_b<=raw_slot[4:1]!=4'b0101;
                    trig_c<=raw_slot[4:1]!=4'b0010;
                    trig_d<=raw_slot[4:1]!=4'b1000;
                    trig_e<=raw_slot[4:1]!=4'b0011;
                    trig_f<=raw_slot[4:1]!=4'b1001;
                    trig_g<=raw_slot[4] && raw_slot[1];
                    e54<=(raw_slot[4:1]!=4'b0011) && (raw_slot[4:1]!=4'b0100);
                    d67<=raw_slot[4:1]!=4'b1101;
                    trig_j<=raw_slot[4:1]!=4'b0001;
                    product_previous<=multiply_product;
                    product_sum<=product_previous+{14'd0,multiply_product[23:14]};
                    product_fraction<=multiply_product[13:7];
                end
                if (edge_d4 && raw_slot[8:5]>=4'd1 && raw_slot[8:5]<=4'd8) begin
                    sample_valid<=1'b1;sample_channel<=raw_slot[7:5]-3'd1;
                    sample_value<=tap_sample;
                end
            end
        end
    end
endmodule

// One operation of the shared filter datapath. This is the physical ALU,
// independent of the sequencer's generated-clock timing. A controller must
// present the chip's F3/F17/D62/TRIGF/TRIGG/D11 values and latch the result
// at the original slot boundaries. It must not treat each operation as a
// complete per-voice filter update.
//
// Public evidence: 054539.v:1601-1644. Both products are raw low24 MULA
// outputs. The earlier product occupies bits30:7; the current product
// contributes bits23:7. Overflow is discarded at the 24- and 31-bit stages.
module jtviostorm_k054539_filter_alu (
    input  [23:0] previous_product,
    input  [23:0] current_product,
    input  [30:0] state_a,
    input  [30:0] state_b,
    input  [30:0] state_c,
    input  [30:0] state_d,
    input  [30:0] state_p,
    input  [30:0] state_q,
    input  [15:0] sample,
    input         select_f3,
    input         select_f17,
    input         select_d62,
    input         trig_f,
    input         trig_g,
    input         invert_b,
    input  [1:0]  tap_select,
    output [30:0] recombined_product,
    output [30:0] adder_result,
    output [15:0] tap_sample,
    output [15:0] result_low_word,
    output [15:0] result_high_word
);
    wire [23:0] product_sum = previous_product +
                             {14'd0, current_product[23:14]};
    assign recombined_product = {product_sum, current_product[13:7]};

    wire [30:0] sample_word = {sample[15], sample, 14'd0};
    wire [30:0] operand_a = select_f3 ?
                            (select_f17 ? state_d : sample_word) :
                            (select_f17 ? state_p : recombined_product);
    wire [30:0] operand_b = trig_g ?
                            (select_d62 ? state_b : state_q) :
                            (select_d62 ? state_c : recombined_product);
    wire [30:0] adder_a = trig_f ? operand_a : ~operand_a;
    wire [30:0] adder_b = invert_b ? ~operand_b : operand_b;
    // Physical common carry is an OR. Complementing both operands still
    // adds only one, a case conventional signed-expression rewrites miss.
    wire carry = invert_b | ~trig_f;
    assign adder_result = adder_a + adder_b + {30'd0, carry};

    assign tap_sample = tap_select == 2'd0 ? state_c[30:15] :
                        tap_select == 2'd1 ? state_b[30:15] :
                        tap_select == 2'd2 ? state_q[30:15] :
                                            state_a[30:15];
    // RAMA stores the upper byte of each word. RAMB stores its lower byte.
    // p lives at internal words0B/0C, q at0D/0E. The low-word bit0 is zero.
    assign result_low_word = {adder_result[14:0], 1'b0};
    assign result_high_word = adder_result[30:15];
endmodule
