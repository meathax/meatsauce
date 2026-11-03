// SPDX-License-Identifier: GPL-3.0-or-later
// Parameterized adaptation of the tested madmotor_audio_cdc stereo protocol.
// One outstanding configuration word. The producer holds payload until the destination
// captures it and returns acknowledgement. A common reset cancels both domains.
module spinal_metrics_cdc #(parameter integer WIDTH=32, parameter logic [WIDTH-1:0] RESET_VALUE='0)(
    input wire src_clk, dst_clk, async_reset,
    input wire src_valid,
    input wire [WIDTH-1:0] src_data,
    output wire src_ready,
    output reg overrun,
    // This is the protocol capture boundary. Retiming/merging it into a
    // downstream DSP creates differently named physical receivers outside the
    // source-bound held-bus budget. Keep the actual capture flops here.
    (* preserve, dont_merge, dont_retime *) output reg [WIDTH-1:0] dst_data,
    output reg dst_valid
);
    wire src_reset, dst_reset;
    spinal_metrics_reset source_reset(src_clk,async_reset,src_reset);
    spinal_metrics_reset destination_reset(dst_clk,async_reset,dst_reset);
    (* preserve, dont_retime *) reg [WIDTH-1:0] held_payload;
    (* preserve *) reg request_toggle, acknowledge_toggle;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
    reg [1:0] request_sync, acknowledge_sync;

    assign src_ready = !src_reset && (request_toggle == acknowledge_sync[1]);
    always @(posedge src_clk or posedge src_reset) begin
        if(src_reset) begin
            held_payload <= RESET_VALUE;
            request_toggle <= 0;
            acknowledge_sync <= 0;
            overrun <= 0;
        end else begin
            acknowledge_sync <= {acknowledge_sync[0],acknowledge_toggle};
            if(src_valid) begin
                if(src_ready) begin
                    held_payload <= src_data;
                    request_toggle <= !request_toggle;
                end else overrun <= 1;
            end
        end
    end
    always @(posedge dst_clk or posedge dst_reset) begin
        if(dst_reset) begin
            request_sync <= 0;
            acknowledge_toggle <= 0;
            dst_data <= RESET_VALUE;
            dst_valid <= 0;
        end else begin
            request_sync <= {request_sync[0],request_toggle};
            dst_valid <= 0;
            if(request_sync[1] != acknowledge_toggle) begin
                dst_data <= held_payload;
                dst_valid <= 1;
                acknowledge_toggle <= request_sync[1];
            end
        end
    end
endmodule
