// -----------------------------------------------------------------------------
// tms34010_local_bus_bridge.sv
//
// Lossless command/response crossing between the core memory-fabric clock and
// the dedicated 8x original-pin local-bus clock.
//
// This is a two-phase multi-cycle-path (MCP) handshake. The source registers
// the complete command and holds it unchanged while a one-bit request toggle
// crosses through a dedicated 2FF synchronizer. The destination captures that
// already-stable, deliberately unsynchronized payload into destination-domain
// registers. Completion follows the same rule in reverse: read data remains in
// a destination register while an acknowledge toggle crosses back, then the
// source captures it and emits one source-clock acknowledge pulse.
//
// The two resets must assert together at the integrated-system boundary so the
// request and acknowledge toggle phases return to the same value. The future
// project SDC must cut the registered payload paths as MCP CDC paths and mark
// the two synchronizer inputs asynchronous.
// -----------------------------------------------------------------------------

`default_nettype none

module tms34010_local_bus_bridge
  import tms34010_pkg::*;
(
  input  logic              src_clk_i,
  input  logic              src_rst_i,
  input  logic              src_req_i,
  input  local_cycle_cmd_t  src_cmd_i,
  output local_word_t       src_rdata_o,
  output logic              src_ack_o,
  output logic              src_busy_o,

  input  logic              dst_clk_i,
  input  logic              dst_rst_i,
  output logic              dst_req_o,
  output local_cycle_cmd_t  dst_cmd_o,
  input  local_word_t       dst_rdata_i,
  input  logic              dst_ack_i
);

  local_cycle_cmd_t src_cmd_q;
  local_cycle_cmd_t dst_cmd_q;
  local_word_t      dst_response_q;

  logic src_request_toggle_q;
  logic src_request_armed_q;
  logic src_outstanding_q;
  logic src_ack_toggle_sync;

  logic dst_request_toggle_sync;
  logic dst_request_seen_q;
  logic dst_ack_toggle_q;
  logic dst_active_q;

  // Only the handshake controls enter synchronizer chains. The wide payloads
  // cross directly between source and destination registers under the MCP
  // stability contract documented above.
  tms34010_sync_bit u_request_sync (
    .clk     (dst_clk_i),
    .rst     (dst_rst_i),
    .async_i (src_request_toggle_q),
    .sync_o  (dst_request_toggle_sync)
  );

  tms34010_sync_bit u_ack_sync (
    .clk     (src_clk_i),
    .rst     (src_rst_i),
    .async_i (dst_ack_toggle_q),
    .sync_o  (src_ack_toggle_sync)
  );

  // Source-side request launch and returned-response capture. Arming requires
  // observing src_req_i low after each transfer; this prevents the arbiter's
  // held request from being accepted a second time in the clock where it sees
  // the returned acknowledge.
  always_ff @(posedge src_clk_i) begin
    if (src_rst_i) begin
      src_cmd_q            <= '0;
      src_rdata_o          <= '0;
      src_ack_o            <= 1'b0;
      src_request_toggle_q <= 1'b0;
      src_request_armed_q  <= 1'b1;
      src_outstanding_q    <= 1'b0;
    end else begin
      src_ack_o <= 1'b0;

      if (!src_req_i)
        src_request_armed_q <= 1'b1;

      if (src_outstanding_q) begin
        if (src_ack_toggle_sync == src_request_toggle_q) begin
          src_rdata_o       <= dst_response_q;
          src_ack_o         <= 1'b1;
          src_outstanding_q <= 1'b0;
        end
      end else if (src_req_i && src_request_armed_q) begin
        src_cmd_q            <= src_cmd_i;
        src_request_toggle_q <= ~src_request_toggle_q;
        src_request_armed_q  <= 1'b0;
        src_outstanding_q    <= 1'b1;
      end
    end
  end

  // Destination-side command capture and controller service. dst_req_o and
  // dst_cmd_o remain stable through arbitrary controller waits.
  always_ff @(posedge dst_clk_i) begin
    if (dst_rst_i) begin
      dst_cmd_q              <= '0;
      dst_response_q         <= '0;
      dst_request_seen_q     <= 1'b0;
      dst_ack_toggle_q       <= 1'b0;
      dst_active_q           <= 1'b0;
    end else if (dst_active_q) begin
      if (dst_ack_i) begin
        dst_response_q   <= dst_rdata_i;
        dst_ack_toggle_q <= dst_request_seen_q;
        dst_active_q     <= 1'b0;
      end
    end else if (dst_request_toggle_sync != dst_request_seen_q) begin
      dst_cmd_q          <= src_cmd_q;
      dst_request_seen_q <= dst_request_toggle_sync;
      dst_active_q       <= 1'b1;
    end
  end

  assign src_busy_o = src_outstanding_q;
  assign dst_req_o  = dst_active_q;
  assign dst_cmd_o  = dst_cmd_q;

endmodule : tms34010_local_bus_bridge

`default_nettype wire
