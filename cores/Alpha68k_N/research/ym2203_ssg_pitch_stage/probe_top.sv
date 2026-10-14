// Observation adapter only. The current production wrapper and donors are unchanged.
module alpha68kn_ymssg_pitch_probe(
    input wire clk,reset,io_wr,io_rd,
    input wire [7:0] io_addr,io_data,read_addr,
    output wire [7:0] read_data,ssg_a,
    output wire chip_cen,ssg_cen,tone_bit,
    output wire [11:0] accepted_period,
    output wire [7:0] accepted_mixer,accepted_volume,
    output wire [1:0] accepted_prescale
);
    alpha68kn_soundchips uut(
        .clk(clk),.reset(reset),.io_wr(io_wr),.io_rd(io_rd),
        .io_addr(io_addr),.io_data(io_data),.read_addr(read_addr),.read_data(read_data),
        .fm(),.ym_psg(),.ay1_psg(),.ay2_psg(),
        .ay1_a(),.ay1_b(),.ay1_c(),.ay2_a(),.ay2_b(),.ay2_c(),
        .ym_irq_n(),.ym_sample(),.ym_writes(),.ay1_writes(),.ay2_writes()
    );
    assign ssg_a=uut.ym.psg_A;
    assign chip_cen=uut.cen;
    assign ssg_cen=uut.ym.u_jt12.clk_en_ssg;
    assign tone_bit=uut.ym.u_jt12.gen_ssg.u_psg.bitA;
    assign accepted_period=uut.ym.u_jt12.gen_ssg.u_psg.periodA;
    assign accepted_mixer=uut.ym.u_jt12.gen_ssg.u_psg.regarray[7];
    assign accepted_volume=uut.ym.u_jt12.gen_ssg.u_psg.regarray[8];
    assign accepted_prescale=uut.ym.u_jt12.div_setting;
endmodule
