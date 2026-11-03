// SPDX-License-Identifier: GPL-3.0-or-later
// MAME0.289 plain WATCHDOG_TIMER: reset disarms; first service starts3seconds.
// Reviewed pwb_watchdog.sv (lesson14863), SHA256
// 5166C6AE8C4F0681A1426317BCE4705E617D90CC5A5A01B55F2A5D2BD1FEDC57.
// Target PLL=50MHz*189/220. ceil(3*50,000,000*189/220)=128,863,637.
// No physical PCB timeout measurement is claimed. Full-rate same-clock counter;
// pause holds elapsed game time. Expiry is one pulse for a reset sequencer.
module thunderjaws_watchdog #(
    parameter integer TIMEOUT_CYCLES=128_863_637
)(
    input wire clk_sys,reset,pause,service,
    output reg expired,armed
);
    localparam integer WIDTH=TIMEOUT_CYCLES>1 ? $clog2(TIMEOUT_CYCLES) : 1;
    localparam [WIDTH-1:0] RELOAD=TIMEOUT_CYCLES-1;
    reg [WIDTH-1:0] remaining;
    always @(posedge clk_sys)begin
        expired<=0;
        if(reset)begin armed<=0;remaining<=0;end
        else if(service)begin armed<=1;remaining<=RELOAD;end
        else if(armed && !pause)begin
            if(remaining==0)begin expired<=1;armed<=0;end
            else remaining<=remaining-1'b1;
        end
    end
endmodule
