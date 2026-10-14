// Bundled-data toggle CDC for the ES5506 stereo sample stream.
// The source holds both words until the destination acknowledges the toggle.
module ssv_audio_cdc (
    input  logic               src_clk,
    input  logic               src_rst,
    input  logic               src_valid,
    input  logic signed [15:0] src_l,
    input  logic signed [15:0] src_r,
    output logic               src_ready,

    input  logic               dst_clk,
    input  logic               dst_rst,
    output logic signed [15:0] dst_l,
    output logic signed [15:0] dst_r,
    output logic               dst_valid
);

(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic [1:0] src_reset_pipe;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic [1:0] dst_reset_pipe;
logic src_reset_active;
logic dst_reset_active;

logic src_toggle;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic src_ack_meta;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic src_ack_sync;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic dst_req_meta;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic dst_req_sync;
logic dst_req_seen;
logic dst_ack_toggle;
logic signed [15:0] src_l_hold;
logic signed [15:0] src_r_hold;

assign src_reset_active = src_reset_pipe[1];
assign dst_reset_active = dst_reset_pipe[1];

always_comb begin
    src_ready = !src_reset_active && (src_ack_sync == src_toggle);
end

always_ff @(posedge src_clk or posedge src_rst) begin
    if (src_rst)
        src_reset_pipe <= 2'b11;
    else
        src_reset_pipe <= {src_reset_pipe[0], 1'b0};
end

always_ff @(posedge dst_clk or posedge dst_rst) begin
    if (dst_rst)
        dst_reset_pipe <= 2'b11;
    else
        dst_reset_pipe <= {dst_reset_pipe[0], 1'b0};
end

// Only the request and acknowledgement toggles cross through synchronizers.
always_ff @(posedge src_clk or posedge src_rst) begin
    if (src_rst) begin
        src_ack_meta <= 1'b0;
        src_ack_sync <= 1'b0;
    end else if (src_reset_active) begin
        src_ack_meta <= 1'b0;
        src_ack_sync <= 1'b0;
    end else begin
        src_ack_meta <= dst_ack_toggle;
        src_ack_sync <= src_ack_meta;
    end
end

always_ff @(posedge dst_clk or posedge dst_rst) begin
    if (dst_rst) begin
        dst_req_meta <= 1'b0;
        dst_req_sync <= 1'b0;
    end else if (dst_reset_active) begin
        dst_req_meta <= 1'b0;
        dst_req_sync <= 1'b0;
    end else begin
        dst_req_meta <= src_toggle;
        dst_req_sync <= dst_req_meta;
    end
end

// The payload is held stable from the source toggle until the return ack.
always_ff @(posedge src_clk or posedge src_rst) begin
    if (src_rst) begin
        src_toggle <= 1'b0;
        src_l_hold <= '0;
        src_r_hold <= '0;
    end else if (src_reset_active) begin
        src_toggle <= 1'b0;
        src_l_hold <= '0;
        src_r_hold <= '0;
    end else if (src_valid && src_ready) begin
        src_l_hold <= src_l;
        src_r_hold <= src_r;
        src_toggle <= ~src_toggle;
    end
end

always_ff @(posedge dst_clk or posedge dst_rst) begin
    if (dst_rst) begin
        dst_req_seen  <= 1'b0;
        dst_ack_toggle <= 1'b0;
        dst_l         <= '0;
        dst_r         <= '0;
        dst_valid     <= 1'b0;
    end else if (dst_reset_active) begin
        dst_req_seen  <= 1'b0;
        dst_ack_toggle <= 1'b0;
        dst_l         <= '0;
        dst_r         <= '0;
        dst_valid     <= 1'b0;
    end else begin
        dst_valid <= 1'b0;
        if (dst_req_sync != dst_req_seen) begin
            dst_l          <= src_l_hold;
            dst_r          <= src_r_hold;
            dst_req_seen   <= dst_req_sync;
            dst_ack_toggle <= dst_req_sync;
            dst_valid      <= 1'b1;
        end
    end
end

`ifdef SIMULATION
always @(posedge src_clk) begin
    if (!src_rst && !src_reset_active && src_valid && !src_ready)
        $fatal(1, "ssv_audio_cdc: source sample arrived while transfer busy");
end
`endif

endmodule
