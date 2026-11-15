// Source-matched adaptation; donor periods and SDC are not reused.
// Async assertion, two destination edges before release, including stopped clocks.
module seicro_vga_reset_release(input wire clk, input wire async_reset, output wire local_reset);
(* preserve, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [1:0] reset_pipe=2'b11;
always @(posedge clk or posedge async_reset)
 if(async_reset) reset_pipe<=2'b11;
 else reset_pipe<={reset_pipe[0],1'b0};
assign local_reset=reset_pipe[1];
endmodule

// clk_ctrl and request_native belong to the continuous game fabric domain.
// Quiesce the DDIO before changing CLKSELECT; keep its reset asserted until
// the new selection has settled. The selected-domain reset pipe owns release.
module seicro_vga_clock_control (
    input wire clk_ctrl, input wire reset,
    input wire request_native,
    output reg select_native = 1'b1,
    output wire switch_reset
);
localparam BEFORE = 2'd0, AFTER = 2'd1, RUN = 2'd2;
reg [1:0] state = BEFORE;
reg [1:0] count = 0;
assign switch_reset = reset | (state != RUN);
// Selection never changes asynchronously on runtime reset. The clock may
// be stopped; wait for four control edges of quiescence before any switch.
always @(posedge clk_ctrl) begin
    if (!reset && state == BEFORE && count == 3) select_native <= request_native;
end
always @(posedge clk_ctrl or posedge reset) begin
    if (reset) begin
        state <= BEFORE;
        count <= 0;
    end else begin
        case (state)
        BEFORE: begin
            if (count == 3) begin
                state <= AFTER;
                count <= 0;
            end else count <= count + 1'b1;
        end
        AFTER: begin
            if (count == 3) begin
                count <= 0;
                state <= (request_native == select_native) ? RUN : BEFORE;
            end else count <= count + 1'b1;
        end
        RUN: begin
            count <= 0;
            if (request_native != select_native) state <= BEFORE;
        end
        default: begin state <= BEFORE; count <= 0; end
        endcase
    end
end
endmodule
