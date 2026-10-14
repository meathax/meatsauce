// SPDX-License-Identifier: GPL-3.0-or-later
module dram_storage_qualification (
 input wire clk, reset, direct_mode, consumer_capture,
 input wire direct_ras_n, direct_cas_n, direct_we_n,
 input wire [6:0] direct_address,
 input wire [7:0] di,
 input wire cpu_wr_rd_level,
 input wire [15:0] cpu_address,
 input wire cpu_wr_n,
 input wire [4:0] physical_h_byte,
 input wire [7:0] physical_v,
 input wire raw_ras_n, raw_cas_n, comadr_n, hread_n,
 output wire actual_ras_n, actual_cas_n, actual_we_n,
 output wire [6:0] actual_address,
 output wire [1:0] mux_selector,
 output wire [7:0] do_data,
 output wire do_valid, read_event, write_event, ignored_cas_event, unsupported_event,
 output reg [7:0] captured_data,
 output reg captured_valid
);
 wire r, c, w;
 wire [6:0] a;
 n8080_dram_control control (
  .cpu_wr_rd_level(cpu_wr_rd_level), .cpu_address(cpu_address),
  .cpu_wr_n(cpu_wr_n), .cpu_sync(1'b0), .phi1_ttl(1'b0),
  .physical_h_byte(physical_h_byte), .physical_v(physical_v),
  .raw_cas_n(raw_cas_n), .raw_ras_n(raw_ras_n),
  .comadr_n(comadr_n), .hread_n(hread_n),
  .mux_selector(mux_selector), .mux_address(a),
  .dram_cas_n(c), .dram_ras_n(r), .dram_we_n(w),
  .ststb(), .ramstb_n(), .disable_level(), .write_predicate()
 );
 assign actual_ras_n = direct_mode ? direct_ras_n : r;
 assign actual_cas_n = direct_mode ? direct_cas_n : c;
 assign actual_we_n = direct_mode ? direct_we_n : w;
 assign actual_address = direct_mode ? direct_address : a;
 n8080_dram_storage storage (
  .clk(clk), .reset(reset), .ras_n(actual_ras_n), .cas_n(actual_cas_n),
  .we_n(actual_we_n), .mux_address(actual_address), .di(di),
  .do_data(do_data), .do_valid(do_valid), .read_event(read_event),
  .write_event(write_event), .ignored_cas_event(ignored_cas_event),
  .unsupported_event(unsupported_event)
 );
 // A real clocked consumer proves old-state sampling at the same CAS release edge.
 always @(posedge clk) begin
  if (reset) begin captured_data <= 0; captured_valid <= 0; end
  else if (consumer_capture) begin
   captured_data <= do_data;
   captured_valid <= do_valid;
  end
 end
endmodule
