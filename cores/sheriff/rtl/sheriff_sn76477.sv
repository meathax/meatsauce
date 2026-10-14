// SPDX-License-Identifier: GPL-2.0-or-later
// Original fixed point RTL, Sheriff component values only.
// Equations and measured gain table derived from MAME 0.289 SN76477 (BSD-3-Clause),
// Copyright Zsolt Vasvari; thanks to Derrick Renaud.
// Preserve docs/licenses/MAME-BSD-3-Clause.txt.
module sheriff_sn76477 (
    input wire clk, reset, pause,
    input wire enabled, vco_mode, mixer_b, vco_5v,
    output reg sample_ce,
    output reg signed [15:0] sample,
    output reg [35:0] slf_voltage, vco_voltage, noise_voltage, ad_voltage,
    output reg slf_bit, vco_bit, filtered_noise
);
    `include "sheriff_sn_constants.svh"
    reg [10:0] divider=0;
    wire tick = divider==1049;
    reg [35:0] shot_voltage=0;
    reg shot_running=0, previous_enabled=0;
    reg [30:0] rng=0;
    reg real_noise=0;
    reg [16:0] noise_count=0;
    wire noise_feedback = (rng[28]^rng[0]) || ((rng & 31'h1000001f)==0);
    // Combinational next capacitor values reproduce MAME's ordered update:
    // new SLF controls VCO, new noise drives filter, new envelope drives gain.
    wire [35:0] slf_next = !slf_bit ?
        (slf_voltage+SLF_UP >= SLF_MAX ? SLF_MAX : slf_voltage+SLF_UP) :
        (slf_voltage <= SLF_MIN+SLF_DOWN ? SLF_MIN : slf_voltage-SLF_DOWN);
    wire [35:0] vco_limit = vco_mode ? slf_next+VCO_OFFSET :
        (vco_5v ? VCO_5V_MAX : VCO_OFFSET);
    wire [35:0] vco_up = vco_5v ? VCO_UP_5V : VCO_UP;
    wire [35:0] vco_down = vco_5v ? VCO_DOWN_5V : VCO_UP;
    wire [35:0] vco_next = !vco_bit ?
        (vco_voltage+vco_up >= vco_limit ? vco_limit : vco_voltage+vco_up) :
        (vco_voltage <= SLF_MIN+vco_down ? SLF_MIN : vco_voltage-vco_down);
    wire vco_bit_next = vco_next>=vco_limit ? 1'b1 : vco_next<=SLF_MIN ? 1'b0 : vco_bit;
    wire new_noise = noise_count<=NOISE_HZ ? noise_feedback : real_noise;
    wire [35:0] noise_next = new_noise ?
        (noise_voltage+NOISE_UP >= NOISE_MAX ? NOISE_MAX : noise_voltage+NOISE_UP) :
        (noise_voltage<=NOISE_DOWN ? 36'd0 : noise_voltage-NOISE_DOWN);
    wire filter_next = noise_next>=NOISE_HIGH ? 1'b0 : noise_next<=NOISE_LOW ? 1'b1 : filtered_noise;
    wire [35:0] shot_next = shot_running ?
        (shot_voltage+SHOT_UP>=SHOT_MAX ? SHOT_MAX : shot_voltage+SHOT_UP) :
        (shot_voltage<=SHOT_DOWN ? 36'd0 : shot_voltage-SHOT_DOWN);
    wire shot_next_running = shot_running && shot_next<SHOT_MAX;
    wire [35:0] ad_next = shot_next_running ?
        (ad_voltage+AD_UP>=AD_MAX ? AD_MAX : ad_voltage+AD_UP) :
        (ad_voltage<=AD_DOWN ? 36'd0 : ad_voltage-AD_DOWN);
    wire [39:0] gain_index_scaled = ad_next*40'd10;
    wire [5:0] gain_index = gain_index_scaled[37:32];
    always @(posedge clk) begin
        sample_ce<=0;
        if(reset) begin
            divider<=0; sample<=0; previous_enabled<=enabled;
            slf_voltage<=SLF_MIN; vco_voltage<=SLF_MIN; noise_voltage<=0; ad_voltage<=0;
            shot_voltage<=0; shot_running<=0; slf_bit<=0; vco_bit<=0;
            rng<=0; real_noise<=0; filtered_noise<=0; noise_count<=0;
        end else if(!pause) begin
            divider<=tick ? 11'd0 : divider+1'b1;
            previous_enabled<=enabled;
            if(tick) begin
                sample_ce<=1;
                slf_voltage<=slf_next;
                slf_bit<=slf_next>=SLF_MAX ? 1'b1 : slf_next<=SLF_MIN ? 1'b0 : slf_bit;
                vco_voltage<=vco_next; vco_bit<=vco_bit_next;
                if(noise_count<=NOISE_HZ) begin
                    noise_count<=noise_count+48000-NOISE_HZ;
                    rng<={noise_feedback,rng[30:1]}; real_noise<=noise_feedback;
                end else noise_count<=noise_count-NOISE_HZ;
                noise_voltage<=noise_next; filtered_noise<=filter_next;
                shot_voltage<=shot_next; shot_running<=shot_next_running; ad_voltage<=ad_next;
                sample <= enabled && vco_next<=VCO_MAX ? gain_sample(gain_index,mixer_b ? filter_next : vco_bit_next) : 16'sd0;
            end
            // SN enable is active low on the physical chip. The board wrapper
            // exposes active-high enabled; an enabling edge starts its one-shot.
            if(enabled && !previous_enabled) begin ad_voltage<=0; shot_running<=1; end
        end
    end
endmodule
