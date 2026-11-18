// Shared sound path; real board I/O and DAC latch connect here during integration.
module alpha68kn_audio (
    input wire clk,reset,io_wr,io_rd,
    input wire [7:0] io_addr,io_data,read_addr,profile,dac,
    output wire [7:0] read_data,
    output wire signed [15:0] sample,
    output wire sample_ce,
    output wire [31:0] clipped_samples,
    output wire signed [15:0] debug_fm,
    output wire [9:0] debug_ym_psg,debug_ay1_psg,debug_ay2_psg,
    output wire [31:0] ym_writes,ay1_writes,ay2_writes
);
    alpha68kn_soundchips chips (
        .clk(clk),.reset(reset),.io_wr(io_wr),.io_rd(io_rd),.io_addr(io_addr),.io_data(io_data),
        .read_addr(read_addr),.read_data(read_data),.fm(debug_fm),
        .ym_psg(debug_ym_psg),.ay1_psg(debug_ay1_psg),.ay2_psg(debug_ay2_psg),
        .ay1_a(),.ay1_b(),.ay1_c(),.ay2_a(),.ay2_b(),.ay2_c(),.ym_irq_n(),.ym_sample(),
        .ym_writes(ym_writes),.ay1_writes(ay1_writes),.ay2_writes(ay2_writes)
    );
    alpha68kn_mixer mixer (
        .clk(clk),.reset(reset),.profile(profile),.dac(dac),.fm(debug_fm),
        .ym_psg(debug_ym_psg),.ay1_psg(debug_ay1_psg),.ay2_psg(debug_ay2_psg),
        .sample(sample),.sample_ce(sample_ce),.clipped_samples(clipped_samples)
    );
endmodule
