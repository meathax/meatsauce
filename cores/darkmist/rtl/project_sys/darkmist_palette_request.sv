// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Darkmist contributors
// Coherent HPS palette control transfer and one-outstanding DDR request.
// ddr_svc has no reset input: preserve request, address and burst ownership
// across a game reset while dropping pending, not-yet-issued requests.
module darkmist_palette_request(
 input wire src_clk,pal_clk,reset,src_valid,
 input wire [28:0] src_address,
 input wire src_enable,vs,
 input wire word_valid,last_word,
 output reg [28:0] address=0,
 output reg request=0,
 output reg busy=0,
 output wire control_valid
);
 wire [29:0] coherent;
 wire transfer_idle,transfer_current,transfer_commit;
 darkmist_audio_mailbox #(.W(30)) palette_cdc(
  .src_clk(src_clk),.dst_clk(pal_clk),.reset(reset),
  .src_valid(src_valid),.src_data({src_enable,src_address}),
  .src_idle(transfer_idle),.src_current(transfer_current),
  .dst_data(coherent),.dst_valid(control_valid),.dst_commit(transfer_commit));
 (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
 reg vs_meta=0,vs_sync=0;
 reg vs_old=0;
 reg pending=0;
 reg [28:0] pending_address=0;
 always @(posedge pal_clk) begin
  vs_meta<=vs;
  vs_sync<=vs_meta;
  vs_old<=vs_sync;
  if(word_valid&&last_word)busy<=0;
  if(!control_valid)pending<=0;
  else if(vs_sync&&!vs_old)begin
   // A newer frame may replace a queued frame, never an accepted burst.
   pending<=coherent[29];
   pending_address<=coherent[28:0];
  end
  else if(pending&&!busy)begin
   address<=pending_address;
   request<=~request;
   busy<=1;
   pending<=0;
  end
 end
endmodule
