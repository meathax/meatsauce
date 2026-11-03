// SPDX-License-Identifier: GPL-3.0-or-later
// One coherent source snapshot per serviced frame event. Request/address phase
// persists across soft resets, matching ddr_svc's persistent acknowledgement.
// Multiple frame events during a blocked burst coalesce into one latest retry.
module madmotor_palette_cdc (
    input wire src_clk, dst_clk,
    input wire [28:0] src_addr,
    input wire src_enabled, frame_vs,
    input wire palette_beat,
    output reg [28:0] palette_addr = 0,
    output reg palette_req = 0,
    output wire src_capture,
    output reg dst_capture = 0,
    output wire busy
);
    (* preserve *) reg [29:0] held_context = 0;
    (* preserve *) reg request_toggle = 0, response_toggle = 0;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
    reg [1:0] request_sync = 0, response_sync = 0, vs_sync = 0;
    reg response_seen = 0, vs_seen = 0;
    reg awaiting_snapshot = 0, burst_busy = 0, frame_pending = 0;
    reg [6:0] beat_count = 0;
    wire frame_edge = vs_sync[1] && !vs_seen;
    assign src_capture = request_sync[1] != response_toggle;
    assign busy = awaiting_snapshot || burst_busy || frame_pending;

    // Same held-payload/two-stage acknowledgement topology as audio_cdc,
    // with the destination requesting a snapshot of source-owned state.
    always @(posedge src_clk) begin
        request_sync <= {request_sync[0], request_toggle};
        if(src_capture) begin
            held_context <= {src_enabled, src_addr};
            response_toggle <= request_sync[1];
        end
    end

    always @(posedge dst_clk) begin
        vs_sync <= {vs_sync[0], frame_vs};
        vs_seen <= vs_sync[1];
        response_sync <= {response_sync[0], response_toggle};
        dst_capture <= 0;
        if(frame_edge) frame_pending <= 1;
        if(!awaiting_snapshot && !burst_busy && (frame_pending || frame_edge)) begin
            request_toggle <= !request_toggle;
            awaiting_snapshot <= 1;
            frame_pending <= 0;
        end
        if(awaiting_snapshot && response_sync[1] != response_seen) begin
            response_seen <= response_sync[1];
            awaiting_snapshot <= 0;
            dst_capture <= 1;
            if(held_context[29]) begin
                palette_addr <= held_context[28:0];
                palette_req <= !palette_req;
                burst_busy <= 1;
                beat_count <= 0;
            end
        end
        // ddr_svc ready is one pulse per returned palette beat. Retire only
        // after all128, independent of command waitrequest and other clients.
        if(burst_busy && palette_beat) begin
            if(beat_count == 127) burst_busy <= 0;
            else beat_count <= beat_count + 1'b1;
        end
    end
endmodule
