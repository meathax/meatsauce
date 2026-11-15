// SPDX-License-Identifier: GPL-3.0-or-later
// Heavy Unit's 3 MHz YM2203, using the unmodified pinned JT03/JT12/JT49.
// One request per req-high interval. Both bus ports use sound I/O A0.
module heavyunit_audio (
    input logic clk, input logic reset, input logic mute,
    input logic req, input logic write, input logic addr,
    input logic [7:0] din,
    output logic ack, output logic [7:0] dout,
    output wire irq_n,
    output logic signed [15:0] audio,
    output logic sample,
    output wire cen_3m, output wire ready,
    output wire signed [15:0] fm_debug,
    output wire [9:0] psg_debug
);
    logic [3:0] divider = 0;
    logic [3:0] reset_enables = 0;
    // Never gate this clock with pause, CPU waits, OSD, or SDRAM traffic.
    always_ff @(posedge clk) divider <= divider + 4'd1;
    assign cen_3m = divider == 4'd15;
    always_ff @(posedge clk) begin
        if (reset) reset_enables <= 0;
        else if (cen_3m && reset_enables != 4'd8)
            reset_enables <= reset_enables + 4'd1;
    end
    wire chip_reset = reset || reset_enables != 4'd8;
    assign ready = !chip_reset;

    typedef enum logic [1:0] {IDLE, ACCESS, RETURN_DATA, WAIT_RELEASE} state_t;
    state_t state = IDLE;
    logic bus_write, bus_addr;
    logic [7:0] bus_din;
    wire [7:0] chip_dout;
    wire chip_sample;
    logic chip_sample_q = 0;
    // JT12's combined snd port is a 16-bit addition, which can wrap before
    // attenuation. Widen first: (-32768..32767)+(0..32736), then divide by2.
    // The exact resulting range -16384..32751 fits signed16 without clipping.
    wire signed [16:0] wide_fm = {fm_debug[15],fm_debug};
    wire signed [16:0] wide_psg = $signed({2'd0,psg_debug,5'd0});
    wire signed [16:0] mixed_snd = wide_fm + wide_psg;
    // JT12 MMR consumes writes at master-clock speed, independent of cen.
    // A single ACCESS edge prevents repeated writes/busy counter restarts.
    // Its registered data mux and JT49 read path settle before RETURN_DATA.
    jt03 #(.YM2203_LUMPED(0)) u_ym (
        .rst(chip_reset), .clk(clk), .cen(cen_3m),
        .din(bus_din), .addr(bus_addr),
        .cs_n(state != ACCESS || chip_reset),
        .wr_n(!bus_write), .dout(chip_dout), .irq_n(irq_n),
        .IOA_in(8'hff), .IOB_in(8'hff), .IOA_out(), .IOB_out(),
        .IOA_oe(), .IOB_oe(), .psg_A(), .psg_B(), .psg_C(),
        .fm_snd(fm_debug), .psg_snd(psg_debug), .snd(),
        .snd_sample(chip_sample), .debug_view()
    );
    always_ff @(posedge clk) begin
        ack <= 0;
        if (chip_reset) begin
            state <= IDLE; dout <= 0;
            bus_write <= 0; bus_addr <= 0; bus_din <= 0;
        end else case (state)
            IDLE: if (req) begin
                bus_write <= write; bus_addr <= addr; bus_din <= din;
                state <= ACCESS;
            end
            ACCESS: state <= RETURN_DATA;
            RETURN_DATA: begin
                dout <= chip_dout; ack <= 1; state <= WAIT_RELEASE;
            end
            WAIT_RELEASE: if (!req) state <= IDLE;
            default: state <= IDLE;
        endcase
        // The donor's zero/sample is a multi-master-edge FM phase level.
        // Keep PSG changes continuous, with one diagnostic FM sample strobe.
        chip_sample_q <= chip_sample;
        sample <= chip_sample && !chip_sample_q && !chip_reset;
        if (chip_reset || mute) audio <= 0;
        else audio <= mixed_snd[16:1];
    end
endmodule
