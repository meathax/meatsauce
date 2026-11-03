// SPDX-License-Identifier: GPL-3.0-or-later
// A manual button press toggles pause; an external owner may independently
// request it for as long as needed. A button held across reset is not a press.
module spinal_pause_policy (
    input logic clk,reset,button,external_request,
    output wire request
);
    logic previous_button=0,manual_pause=0;
    assign request=manual_pause || external_request;
    always_ff @(posedge clk) begin
        previous_button<=button;
        if(reset) manual_pause<=0;
        else if(button && !previous_button) manual_pause<=!manual_pause;
    end
endmodule
