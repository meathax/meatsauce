`timescale 1ns/1ps
`default_nettype none
// Transaction-safe handoff of the shared main-RAM SDRAM client to MiSTer NVRAM
// upload. A save request first stops the TMS34010 at an instruction boundary;
// only after the core reports its bus idle may the upload client issue reads.
module narc_nvram_arbiter (
  input  wire clk,
  input  wire rst,
  input  wire save_request,
  input  wire core_quiescent,
  output logic nvram_grant
);
  always_ff @(posedge clk) begin
    if (rst || !save_request)
      nvram_grant <= 1'b0;
    else if (core_quiescent)
      nvram_grant <= 1'b1;
  end
endmodule
`default_nettype wire
