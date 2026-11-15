// Isolated clk_sys-domain HDMI VS synchronizer; source level must be held
// long enough for this domain to sample both levels.
module seicro_hdmi_vs_cdc(input wire clk, input wire vs_async, output wire vs_sync);
(* preserve, dont_merge, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg meta=0, sync=0;
always @(posedge clk) begin meta<=vs_async;sync<=meta;end
assign vs_sync=sync;
endmodule
