// SPDX-License-Identifier: GPL-3.0-or-later
// One outstanding stereo word. The producer holds payload until the destination
// captures it and returns acknowledgement. A common reset cancels both domains.
module madmotor_audio_cdc(
    input wire src_clk, dst_clk, async_reset,
    input wire src_valid,
    input wire signed [15:0] src_left, src_right,
    output wire src_ready,
    output reg overrun,
    output reg signed [15:0] dst_left, dst_right,
    output reg dst_valid
);
    wire src_reset, dst_reset;
    madmotor_reset source_reset(src_clk,async_reset,src_reset);
    madmotor_reset destination_reset(dst_clk,async_reset,dst_reset);
    (* preserve *) reg [31:0] held_payload;
    (* preserve *) reg request_toggle, acknowledge_toggle;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
    reg [1:0] request_sync, acknowledge_sync;

    assign src_ready = !src_reset && (request_toggle == acknowledge_sync[1]);
    always @(posedge src_clk or posedge src_reset) begin
        if(src_reset) begin
            held_payload <= 0;
            request_toggle <= 0;
            acknowledge_sync <= 0;
            overrun <= 0;
        end else begin
            acknowledge_sync <= {acknowledge_sync[0],acknowledge_toggle};
            if(src_valid) begin
                if(src_ready) begin
                    held_payload <= {src_left,src_right};
                    request_toggle <= !request_toggle;
                end else overrun <= 1;
            end
        end
    end
    always @(posedge dst_clk or posedge dst_reset) begin
        if(dst_reset) begin
            request_sync <= 0;
            acknowledge_toggle <= 0;
            dst_left <= 0;
            dst_right <= 0;
            dst_valid <= 0;
        end else begin
            request_sync <= {request_sync[0],request_toggle};
            dst_valid <= 0;
            if(request_sync[1] != acknowledge_toggle) begin
                {dst_left,dst_right} <= held_payload;
                dst_valid <= 1;
                acknowledge_toggle <= request_sync[1];
            end
        end
    end
endmodule
