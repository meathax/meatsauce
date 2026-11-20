// SPDX-License-Identifier: GPL-3.0-or-later
// Keep a momentary OSD test command alive while the game is paused. The
// CPU releases it only after sampling the cabinet's IN2 low byte.
module gs_osd_controls (
    input wire clk,reset,osd_open,service_trigger,pause_button,
    input wire ram_clk,manual_pause,osd_pause_disabled,
    input wire cpu_req,cpu_ack,cpu_write,
    input wire [31:0] cpu_addr,
    input wire [1:0] cpu_bytes,
    output reg service_active=0,output reg button_paused=0,
    output wire pause_game
);
    // HPS/OSD commands and the CPU-clocked button latch are held levels. Capture
    // their combined request locally before it fans out to the RAM frame logic.
    // Keep both stages; the related clocks remain fully timed by TimeQuest.
    (* preserve *) reg [1:0] pause_ram_s=2'b00;
    always @(posedge ram_clk)
        pause_ram_s<={pause_ram_s[0],manual_pause || button_paused || (osd_open && !osd_pause_disabled)};
    assign pause_game=pause_ram_s[1];
    reg service_previous=0,pause_previous=0;
    always @(posedge clk) begin
        service_previous<=service_trigger;
        pause_previous<=pause_button;
        if(reset) begin
            service_active<=0;
            button_paused<=0;
        end else begin
            if(!osd_open && cpu_req && cpu_ack && !cpu_write &&
                cpu_addr[23:1]==23'h200003 && cpu_bytes[0]) service_active<=0;
            if(service_trigger && !service_previous) service_active<=1;
            if(pause_button && !pause_previous) button_paused<=!button_paused;
        end
    end
endmodule
