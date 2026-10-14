// Scoped native-video unit test: sound outputs are fixed at zero.
// Real board memory, pixel timing, renderer and 8080 OUT6 remain in this test.
module n8080_mcs48 (
    input wire clk, reset, pause,
    input wire [7:0] sound1, sound2,
    input wire load_wr,
    input wire [9:0] load_addr,
    input wire [7:0] load_data,
    output wire dac_bit,
    output wire [7:0] p1_out, p2_out,
    output wire [11:0] program_address,
    output wire [7:0] program_data,
    output wire irq_n,
    output wire [12:0] pins,
    output wire mono0, mono1,
    output wire ce_crystal, ce_state,
    output wire [7:0] ram_address,
    output wire ram_write,
    output wire [7:0] ram_dout,
    output wire sn_enable, sn_vco_mode, sn_mixer_b, sn_vco_5v
);
assign {dac_bit,p1_out,p2_out,program_address,program_data,irq_n,pins,mono0,mono1,ce_crystal,ce_state,ram_address,ram_write,ram_dout,sn_enable,sn_vco_mode,sn_mixer_b,sn_vco_5v} = '0;
endmodule
module sheriff_sn76477 (
    input wire clk, reset, pause,
    input wire enabled, vco_mode, mixer_b, vco_5v,
    output reg sample_ce,
    output reg signed [15:0] sample,
    output reg [35:0] slf_voltage, vco_voltage, noise_voltage, ad_voltage,
    output reg slf_bit, vco_bit, filtered_noise
);
assign {sample_ce,sample,slf_voltage,vco_voltage,noise_voltage,ad_voltage,slf_bit,vco_bit,filtered_noise} = '0;
endmodule
