// Gaiapolis adapter. Source provenance: rtl/vendor/violent_storm_k054539/source.json
// Konami 054539 effects combinational datapath, reconstructed from wiring.
// Authority: SiliconRE c926ce92fdebd7613c8712b42c45a059d63548e0,
// gaiapolis_pause_pcm.SDF and schematic sheets 43/44; public hdl/054539.v:340-424,
// 673,827-833,1747 corroborate routing and wrapping adders. The public ACCC
// case table at363-370 contradicts the physical AD45B/AD46B mux inputs.
//
// This module deliberately has no accumulator reset/capture sequencer. Its
// pointer_acc, address_sum and feedback_hold inputs are externally held words.
// AG116 normal-Q polarity is physically confirmed; its D contact and exact
// PRE/capture chronology remain unresolved. effects.v isolates a functional
// head reconstruction rather than importing either unproved polarity flip.
// The 17-bit address is the chip's raw byte-address bus, before PCB decoding.
// mode224/mode225 are CPU-visible bits. offset_* and gain_* are already the
// chip-stored INVERTED register bytes, not the CPU-written byte values.
// Normal operation is assumed: TESTREG2.D7=0. CNTC bit15 is physically NC.
module gaiapolis_k054539_effects_decode (
    input      [8:0]  count,
    input      [8:0]  count_delayed,
    input      [6:0]  mode224,
    input      [5:0]  mode225,
    input      [14:0] frame_counter,
    input      [7:0]  lfo_a,
    input      [7:0]  lfo_b,
    input      [15:0] offset_a0,        // {REG217,REG216}
    input      [15:0] offset_a1,        // {REG219,REG218}
    input      [15:0] offset_b0,        // {REG21E,REG21D}
    input      [15:0] offset_b1,        // {REG220,REG21F}
    input      [15:0] pointer_acc,
    input      [15:0] address_sum,
    input      [15:0] send_a,
    input      [15:0] send_b,
    input      [15:0] delay_a,
    input      [15:0] delay_b,
    input      [15:0] ram_read_word,
    input      [15:0] feedback_product,
    input      [15:0] feedback_hold,
    input      [7:0]  gain_a,           // REG21A (stored inverted)
    input      [7:0]  gain_b,           // REG221 (stored inverted)
    input             cpu_write_override, // REG22F.D4
    input      [7:0]  cpu_data,
    output reg [15:0] address_operand,
    output            subtract_operand,
    output     [15:0] pointer_next,
    output     [16:0] memory_byte_addr,
    output            half_rate_skip,
    output     [7:0]  memory_write_byte,
    output     [15:0] feedback_sum,
    output     [15:0] loop_source,
    output     [15:0] feedback_coefficient
);
    wire half_select = count[6] ? mode224[6] : mode224[2];
    wire ae131 = ~(count_delayed[3] & ~count_delayed[4]);
    wire ab178 = count_delayed[3] & count_delayed[1];
    wire ad69  = ~(ae131 | ~count_delayed[6]);
    wire ae53  = ~(ab178 & count_delayed[6]);

    always @* begin
        address_operand = 16'd0;
        casez ({ae131,ab178,ad69,ae53})
            4'b??00: address_operand = offset_a0;
            4'b??10: address_operand = offset_b1;
            4'b0001: address_operand = mode224[1] ? {7'd0,lfo_a,1'b0} : {8'd0,lfo_a};
            4'b0101: address_operand = offset_a1;
            4'b1001: address_operand = half_select ? {2'd0,frame_counter[14:1]} : {1'b0,frame_counter};
            4'b1101: address_operand = offset_b0;
            4'b??11: address_operand = mode224[5] ? {7'd0,lfo_b,1'b0} : {8'd0,lfo_b};
            default: address_operand = 16'd0;
        endcase
    end

    // AE119/AE120 NAND is high only in the four-clock subtraction window.
    assign subtract_operand = count_delayed[5:2] == 4'b0011;
    // Physical 16-bit XOR bank plus carry-in; overflow is discarded.
    assign pointer_next = pointer_acc + (subtract_operand ? ~address_operand : address_operand)
                                      + {15'd0,subtract_operand};

    reg address_bank;
    always @* begin
        if (!mode224[3]) address_bank = count_delayed[6];
        else case (mode225[5:4])
            2'd0: address_bank = address_sum[9];
            2'd1: address_bank = address_sum[11];
            2'd2: address_bank = address_sum[13];
            2'd3: address_bank = address_sum[15];
        endcase
    end
    assign memory_byte_addr = {address_bank,address_sum[14:0],count_delayed[3]};
    assign half_rate_skip = half_select & ~frame_counter[0];

    wire [15:0] selected_send = (count[6] ? mode224[4] : mode224[0]) ? send_b : send_a;
    wire [15:0] selected_write = count_delayed[4] ? feedback_hold : selected_send;
    assign memory_write_byte = cpu_write_override ? cpu_data :
                               count_delayed[3] ? selected_write[15:8] : selected_write[7:0];
    // ACCD uses a separate 16-bit wrapping adder, without saturation.
    assign feedback_sum = ram_read_word + feedback_product;
    assign loop_source = count[5] ? (mode225[0] ? send_b : delay_b) :
                                   (mode225[1] ? send_a : delay_a);
    assign feedback_coefficient = {1'b0,(count_delayed[6] ? gain_b : gain_a),7'd0};
endmodule
