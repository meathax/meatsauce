// Adapted from MAD MOTOR palette CDC, 2026-10-22; see scripts/prepare_palette_candidate.py
// SPDX-License-Identifier: GPL-3.0-or-later
// One coherent source snapshot per serviced frame event. Request/address phase
// persists across soft resets, matching ddr_svc's persistent acknowledgement.
// Multiple frame events during a blocked burst coalesce into one latest retry.
module madmotor_palette_cdc (
    input wire src_clk, dst_clk, frame_clk,
    input wire [28:0] src_addr,
    input wire src_enabled, frame_vs, src_valid,
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
    reg [1:0] request_sync = 0, response_sync = 0;
    reg response_seen = 0;
    reg awaiting_snapshot = 0, burst_busy = 0, frame_pending = 0;
    reg [6:0] beat_count = 0;
    // Source-owned event persists until acknowledged. Blocked frame events
    // coalesce into one latest retry, matching the existing burst policy.
    (* preserve, dont_merge *) reg frame_req = 0, frame_ack = 0;
    reg frame_vs_d = 0, frame_pending_src = 0;
    (* preserve, dont_merge, altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
    reg [1:0] frame_req_sync = 0, frame_ack_sync = 0;
    wire frame_rise_src = frame_vs && !frame_vs_d;
    wire frame_edge = frame_req_sync[1] != frame_ack;
    always @(posedge frame_clk) begin
        frame_ack_sync <= {frame_ack_sync[0], frame_ack};
        frame_vs_d <= frame_vs;
        if(frame_rise_src) frame_pending_src <= 1;
        if(frame_ack_sync[1] == frame_req && (frame_pending_src || frame_rise_src)) begin
            frame_req <= !frame_req;
            frame_pending_src <= 0;
        end
    end
    assign src_capture = src_valid && (request_sync[1] != response_toggle);
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
        frame_req_sync <= {frame_req_sync[0], frame_req};
        if(frame_edge) frame_ack <= frame_req_sync[1];
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
