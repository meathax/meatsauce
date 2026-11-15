// Adapted from fromjail/core/rtl/dfjail_audio_cdc.sv; source hash in preparation.json
// Coherent latest-sample stereo transfer. The producer holds the entire word
// until the receiver acknowledges it; sample-rate conversion remains downstream.
module seicro_audio_cdc #(
    parameter WIDTH = 32
) (
    input  wire        reset,
    input  wire        src_valid,
    input  wire        src_clk,
    input  wire        dst_clk,
    input  wire [WIDTH-1:0] src_sample,
    output reg  [WIDTH-1:0] dst_sample = {WIDTH{1'b0}},
    output reg dst_valid = 1'b0
);
    // Assert even with a stopped clock, release only on the local clock.
    (* preserve, altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [23:0] src_reset_pipe = 24'hffffff;
    (* preserve, altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] dst_reset_pipe = 2'b11;
    always @(posedge src_clk or posedge reset)
        if (reset) src_reset_pipe <= 24'hffffff;
        else src_reset_pipe <= {src_reset_pipe[22:0], 1'b0};
    // Early request and later source-bank release use separate registered nets.
    // Stages are fixed for this core's nominal49.15MHz source clock. Physical reset
    // arrival/pulse bounds and all-corner timing remain admission requirements.
    wire dst_reset_request = src_reset_pipe[15];
    wire src_reset = src_reset_pipe[23];
    always @(posedge dst_clk or posedge dst_reset_request)
        if (dst_reset_request) dst_reset_pipe <= 2'b11;
        else dst_reset_pipe <= {dst_reset_pipe[0], 1'b0};
    wire dst_reset = dst_reset_pipe[1];

    (* preserve *) reg [WIDTH-1:0] samples_hold = {WIDTH{1'b0}};
    (* preserve *) reg req_toggle = 1'b0, ack_toggle = 1'b0;
    (* preserve, altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg ack_meta = 1'b0, ack_sync = 1'b0;
    (* preserve, altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg req_meta = 1'b0, req_sync = 1'b0;

    // Raw reset reaches only asynchronous reset-pipeline pins. These two
    // pairs bring their extended levels into ordinary source-clock control.
    (* preserve, dont_merge, dont_replicate, dont_retime, altera_attribute = "-name ADV_NETLIST_OPT_ALLOWED NEVER_ALLOW; -name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg src_request_meta=0, src_request_sync=0;
    (* preserve, dont_merge, dont_replicate, dont_retime, altera_attribute = "-name ADV_NETLIST_OPT_ALLOWED NEVER_ALLOW; -name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg src_release_meta=0, src_release_sync=0;
    always @(posedge src_clk) begin
        src_request_meta <= src_reset_pipe[15];
        src_request_sync <= src_request_meta;
        src_release_meta <= src_reset_pipe[23];
        src_release_sync <= src_release_meta;
    end

    localparam RUN=2'd0, GUARD=2'd1, CLEAR=2'd2;
    (* preserve *) reg [1:0] src_state=RUN;
    (* preserve *) reg [3:0] src_guard_count=0;
    // A synchronized assertion starts ten full source-clock guard intervals.
    // Payload and request retain their old coherent value until their expiry.
    // The remote reset request releases at edge16; local release at edge24.
    // Exact reset/Q/clock/control propagation and primitive ACLR minima must
    // still be qualified; cycle counts alone do not admit hardware.
    always @(posedge src_clk) begin
        case(src_state)
        RUN: begin
            if(src_request_sync || src_release_sync) begin
                src_guard_count <= 0;
                src_state <= GUARD;
            end else begin
                ack_meta <= ack_toggle;
                ack_sync <= ack_meta;
                if(src_valid && ack_sync==req_toggle) begin
                    samples_hold <= src_sample;
                    req_toggle <= ~req_toggle;
                end
            end
        end
        GUARD: begin
            if(src_guard_count==9) begin
                samples_hold <= {WIDTH{1'b0}};
                req_toggle <= 0;
                ack_meta <= 0;
                ack_sync <= 0;
                src_state <= CLEAR;
            end else src_guard_count <= src_guard_count+1'b1;
        end
        CLEAR: begin
            if(!src_request_sync && !src_release_sync) src_state <= RUN;
        end
        default: begin src_state <= GUARD; src_guard_count <= 0; end
        endcase
    end

    always @(posedge dst_clk or posedge dst_reset) begin
        if (dst_reset) begin
            req_meta <= 1'b0;
            req_sync <= 1'b0;
            ack_toggle <= 1'b0;
            dst_sample <= {WIDTH{1'b0}};
            dst_valid <= 1'b0;
        end else begin
            req_meta <= req_toggle;
            req_sync <= req_meta;
            // With two request stages the held word has at least two complete
            // destination periods to settle before this capture. Acknowledgement
            // then needs two source stages before samples_hold can change.
            if (req_sync != ack_toggle) begin
                dst_sample <= samples_hold;
                dst_valid <= 1'b1;
                ack_toggle <= req_sync;
            end
        end
    end
endmodule
