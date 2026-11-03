// SPDX-License-Identifier: GPL-3.0-or-later
// Air Buster sound chips (airbustr.cpp:784-793): YM2203 at 3 MHz (ports A/B
// read DSW1/DSW2, IRQ to the sound Z80) and an OKI M6295 at 3 MHz, pin7 low.
// Donors: unmodified JT03/JT12/JT49 (HeavyUnit core) and JT6295 (BloodBros).
// Mix follows the MAME routes: SSG A/B/C 0.25 each, FM 0.50, OKI 0.80, with
// each source normalized like the MAME streams (FM/32768, SSG/255, OKI/2048).
module airbustr_audio (
    input logic clk, input logic reset, input logic mute,
    input logic req, input logic oki_sel, input logic write, input logic addr,
    input logic [7:0] din,
    output logic ack, output logic [7:0] dout,
    input logic [7:0] dsw1, dsw2,
    output wire irq_n,
    // OKI sample ROM (256 KB) behind a byte request port
    output logic [17:0] oki_rom_addr,
    output logic oki_rom_req,
    input logic oki_rom_ok,
    input logic [7:0] oki_rom_data,
    output logic signed [15:0] audio,
    output logic sample,
    output wire cen_3m, output wire ready
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
    logic bus_write, bus_addr, bus_oki;
    logic [7:0] bus_din;
    wire [7:0] ym_dout, oki_dout;
    wire signed [15:0] fm_snd;
    wire [9:0] psg_snd;
    wire signed [13:0] oki_snd;
    wire oki_sample;
    jt03 #(.YM2203_LUMPED(0)) u_ym (
        .rst(chip_reset), .clk(clk), .cen(cen_3m),
        .din(bus_din), .addr(bus_addr),
        .cs_n(!(state == ACCESS && !bus_oki) || chip_reset),
        .wr_n(!bus_write), .dout(ym_dout), .irq_n(irq_n),
        .IOA_in(dsw1), .IOB_in(dsw2), .IOA_out(), .IOB_out(),
        .IOA_oe(), .IOB_oe(), .psg_A(), .psg_B(), .psg_C(),
        .fm_snd(fm_snd), .psg_snd(psg_snd), .snd(),
        .snd_sample(), .debug_view()
    );
    jt6295 #(.INTERPOL(0)) u_oki (
        .rst(chip_reset), .clk(clk), .cen(cen_3m), .ss(1'b0),
        .wrn(!(state == ACCESS && bus_oki && bus_write)), .din(bus_din), .dout(oki_dout),
        .rom_addr(oki_rom_addr), .rom_data(oki_rom_data), .rom_ok(oki_rom_ok),
        .sound(oki_snd), .sample(oki_sample)
    );
    assign oki_rom_req = !chip_reset;
    always_ff @(posedge clk) begin
        ack <= 0;
        if (chip_reset) begin
            state <= IDLE; dout <= 0;
            bus_write <= 0; bus_addr <= 0; bus_din <= 0; bus_oki <= 0;
        end else case (state)
            IDLE: if (req) begin
                bus_write <= write; bus_addr <= addr; bus_din <= din; bus_oki <= oki_sel;
                state <= ACCESS;
            end
            ACCESS: state <= RETURN_DATA;
            RETURN_DATA: begin
                dout <= bus_oki ? oki_dout : ym_dout; ack <= 1; state <= WAIT_RELEASE;
            end
            WAIT_RELEASE: if (!req) state <= IDLE;
            default: state <= IDLE;
        endcase
    end
    airbustr_audio_mixer mixer(.clk,.reset(chip_reset || mute),.ce(cen_3m),
        .fm(fm_snd),.psg(psg_snd),.oki(oki_snd),.audio);
    always_ff @(posedge clk) sample <= cen_3m;
endmodule

// MAME chip-route ratios with a common 1/5 master gain. The OKI input is the
// SUM of four signed 12-bit voices. Even full-scale FM, all PSG channels and
// all four OKI voices fit: every representable input maps to -24248..30818.
// Hold each output between enables for sys/audio_out's stable-sample CDC.
module airbustr_audio_mixer(
    input logic clk,reset,ce,
    input logic signed [15:0] fm,
    input logic [9:0] psg,
    input logic signed [13:0] oki,
    output logic signed [15:0] audio
);
    // Exact rational form of 32768/5 * (FM*.5/32768 + PSG*.25/255 + OKI*.8/2048).
    wire signed [31:0] mix = $signed({{16{fm[15]}},fm}) * 32'sd255 +
                             $signed({22'd0,psg}) * 32'sd16384 +
                             $signed({{18{oki[13]}},oki}) * 32'sd6528;
    // Exact truncation toward zero, without a fabric restoring divider.
    // For all input codes, -61833216 <= mix <= 78587265. With
    // M=ceil(2^38/2550)=107795258 and M*2550-2^38=956,
    // |mix|*956 < 2^38. Thus floor(|mix|*M/2^38)=floor(|mix|/2550):
    // the reciprocal error cannot cross even the closest 1/2550 boundary.
    // Both multiplier operands fit one Cyclone V 27x27 DSP multiplier.
    wire [26:0] magnitude = mix[31] ? -mix : mix;
    wire [53:0] reciprocal_product = magnitude * 27'd107795258;
    wire signed [16:0] quotient = $signed({1'b0,reciprocal_product[53:38]});
    wire signed [31:0] scaled = mix[31] ? -quotient : quotient;
    always_ff @(posedge clk) begin
        if(reset) audio <= 0;
        else if(ce) audio <= scaled > 32'sd32767 ? 16'sh7fff :
                            scaled < -32'sd32768 ? 16'sh8000 : scaled[15:0];
    end
endmodule
