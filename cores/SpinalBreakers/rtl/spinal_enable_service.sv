// SPDX-License-Identifier: GPL-3.0-or-later
// Candidate common-clock enables and experimental sound-reset extension.
// CPU bus inputs must come from the connected fx68k and ROM request path.
module spinal_enable_service (
    input logic clk,platform_reset,game_reset,freeze_cpu,freeze_sound,
    input logic as_n,uds_n,lds_n,dtack_n,rom_wait,
    output wire phi1,phi2,sound_ce,ym_ce,sound_hold,
    output wire cpu_debt_overflow,output wire [15:0] cpu_debt
);
    logic [11:0] sound_reset_age=0;
    always_ff @(posedge clk) begin
        if(game_reset || platform_reset)sound_reset_age<=0;
        else if(!freeze_sound && sound_reset_age<12'd3072)sound_reset_age<=sound_reset_age+1'b1;
    end
    assign sound_hold=game_reset || platform_reset || sound_reset_age<12'd3072;
    spinal_cpu_enable cpu_enable(.clk(clk),.reset(game_reset || platform_reset),.freeze(freeze_cpu),.as_n(as_n),.uds_n(uds_n),.lds_n(lds_n),
        .dtack_n(dtack_n),.rom_wait(rom_wait),.phi1(phi1),.phi2(phi2),.overflow(cpu_debt_overflow),.debt(cpu_debt));
    wire raw_sound_ce,raw_ym_ce;
    spinal_sound_enable sound_enable(.clk(clk),.reset(platform_reset),.sound_ce(raw_sound_ce),.ym_ce(raw_ym_ce));
    assign sound_ce=raw_sound_ce && !freeze_sound;
    assign ym_ce=raw_ym_ce && !freeze_sound;
endmodule
