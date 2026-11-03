// SPDX-License-Identifier: GPL-3.0-or-later
// Candidate same-clock pause handoff. Idle/drain inputs must be derived from
// the actual owners; this block does not itself prove those conditions.
module spinal_pause_control (
    input logic clk,reset,request,
    input logic cpu_idle,sound_bus_ack,cpu_drained,sound_drained,sample_drained,
    output wire sound_bus_request,freeze_cpu,freeze_sound,paused
);
    logic cpu_latched=0,sound_latched=0,paused_latched=0;
    // Gate an eligible phase on the same edge that latches ownership, so a
    // CPU cannot start a new bus cycle between its idle test and freeze.
    assign freeze_cpu=!reset && request && (cpu_latched || cpu_idle);
    // Keep the Z80 running until it actually grants the bus; an idle-looking
    // bus alone can occur before an outstanding synchronous read completes.
    assign sound_bus_request=!reset && request;
    assign freeze_sound=!reset && request && (sound_latched || sound_bus_ack);
    assign paused=!reset && request && paused_latched && cpu_drained && sound_drained && sample_drained;
    always_ff @(posedge clk) begin
        if(reset || !request)begin cpu_latched<=0;sound_latched<=0;paused_latched<=0;end
        else begin
            if(cpu_idle)cpu_latched<=1;
            if(sound_bus_ack)sound_latched<=1;
            if(!(cpu_drained && sound_drained && sample_drained))paused_latched<=0;
            else if(cpu_latched && sound_latched)paused_latched<=1;
        end
    end
endmodule
