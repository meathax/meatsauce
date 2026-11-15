// Async assertion, two destination edges before release, including stopped clocks.
module seicro_alsa_reset_release(input wire clk, input wire async_reset, output wire local_reset);
(* preserve, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [1:0] reset_pipe=2'b11;
always @(posedge clk or posedge async_reset)
 if(async_reset) reset_pipe<=2'b11;
 else reset_pipe<={reset_pipe[0],1'b0};
assign local_reset=reset_pipe[1];
endmodule
