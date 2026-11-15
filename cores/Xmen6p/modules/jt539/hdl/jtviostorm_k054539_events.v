/* Native 054539 key/end controller, public SiliconRE physical gates.
 * SDF W21/W16/W26/V15 and W11B/W12A/W12B/W14/W15; PDF sheets15/26/27.
 * WR214 captures pending. Native frame consumes it. D7 has no event fanout.
 * sample_event is gated M4; sample_valid is V38A (!decoded EOF).
 * Separate physical clocks use host-clock strobes. Exact CPU/frame
 * coincidence is unqualified. W16 reset consumes old pending; a coincident
 * release queues only on channels not being reset.
 * W16 is native DFFR: reset Q=0 needs one cen recovery edge before WR214.
 * V15/W26 only have $RES async reset; key-off enters their clocked D gates.
 */
module jtviostorm_k054539_events (
    input            clk,
    input            rst,
    input            cen,
    input            frame_tick,
    input            keyon_release,
    input      [7:0] keyon_mask,
    input      [7:0] keyoff_mask,
    input      [7:0] sample_event,
    input      [7:0] sample_valid,
    input      [7:0] loop_enable,
    input      [7:0] odd_bit2,
    output reg [7:0] pending,
    output reg [7:0] active,
    output reg [7:0] start,
    output     [7:0] loop_reset,
    output reg [7:0] saved_valid,
    output reg [7:0] history
);

reg [7:0] w16_q;
reg [7:0] pending_d, active_d, start_d, w16_d;
reg [7:0] saved_valid_d, history_d;
wire [7:0] end_guard =
    pending | loop_enable | saved_valid | (odd_bit2 & ~history);
wire [7:0] trigger =
    (pending & {8{frame_tick}}) | (start & {8{~frame_tick}});

assign loop_reset = loop_enable & ~saved_valid;

always @* begin
    active_d = active;
    start_d = start;
    w16_d = w16_q;
    if (cen) begin
        w16_d = ~(pending & {8{frame_tick}});
        active_d = (active | trigger) & ~keyoff_mask & end_guard;
        start_d = trigger & ~keyoff_mask & end_guard;
    end
    // W20 asynchronously resets W21 while W16 or key-off gate is low.
    // Old/new W16 make reset dominant at either side of the native edge.
    pending_d = (pending | (keyon_mask & {8{keyon_release}})) &
                ~keyoff_mask & w16_q & w16_d;
    saved_valid_d = (saved_valid & ~sample_event) |
                    (sample_valid & sample_event) | ~w16_q | ~w16_d;
    // PDF15 separates active-low SET=W16_Q from RESET=VCC (SDF typo).
    // W14.D=1; rising saved-valid sets history. Loop or W16 low resets it.
    history_d = (history | (~saved_valid & saved_valid_d)) &
                ~loop_enable & w16_q & w16_d;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        pending <= 8'd0;
        active <= 8'd0;
        start <= 8'd0;
        w16_q <= 8'd0;
        saved_valid <= 8'hff;
        history <= 8'd0;
    end else begin
        pending <= pending_d;
        active <= active_d;
        start <= start_d;
        w16_q <= w16_d;
        saved_valid <= saved_valid_d;
        history <= history_d;
    end
end
endmodule
