// SPDX-License-Identifier: GPL-3.0-or-later
// Four-bank, four-line-ring 352-pixel SSV palette-index scanline store.
//
// The store is a ring of FOUR line slots (it was double-buffered before
// 2026-08). Scanout consumes completed lines in ring order; the renderer is
// kicked by the core into the next clean slot and may run up to three lines
// ahead of the beam. That headroom is what absorbs a sprite-dense line whose
// bg+sprite fetch exceeds one line time on real SDRAM -- the old
// one-line-ahead double buffer turned every such line into a visible
// full-width streak.
`timescale 1ns/1ps

module ssv_line_buffer4 (
    input  logic        clk,
    input  logic        rst,
    // Pulses once per frame, during vblank and before the first active-line
    // line_start. Resets BOTH ring pointers (scan side and render side) plus
    // the slot state to one deterministic aligned mapping, bounding any
    // underrun-induced misalignment to the frame it happened in.
    input  logic        frame_sync,
    // Display-side consumption pulse: advance scanout to the next completed
    // line in the ring. If no completed line is available the previous line
    // is repeated (scan_underrun) and the ring stays put; the late line is
    // then shown one line low until frame_sync realigns the ring.
    input  logic        line_start,
    // Producer handshake. render_start opens a plot epoch into the slot at
    // wr_ptr -- the core kicks only while render_ready is high, so that slot
    // is already cleared. render_done publishes the slot for scanout and
    // advances wr_ptr.
    input  logic        render_start,
    input  logic        render_done,

    input  logic  [3:0] plot_we,
    input  logic [35:0] plot_x,
    input  logic [59:0] plot_color,
    input  logic        plot_shadow,
    input  logic [31:0] plot_pen,
    input  logic        shadow_4bit,

    input  logic  [8:0] scan_x,
    output logic [14:0] scan_color,

    // A clean slot is available at wr_ptr and no plot epoch is open: the
    // core may kick the renderer.
    output logic        render_ready,
    // One-cycle pulse following render_start. Replaces the old post-swap
    // clear_done pulse the background renderer waits on: the slot handed to
    // the renderer was cleared before the kick was allowed, so the go can be
    // immediate.
    output logic        render_go,
    // Consumption pulse found no completed line (registered, pulses the
    // cycle after line_start). This is the real missed-deadline indicator.
    output logic        scan_underrun
);

localparam logic [8:0] ACTIVE_WIDTH = 9'd352;
localparam logic [6:0] LAST_WORD = 7'd87;

// Ring state. Slots advance strictly in order on both sides:
//   render (wr_ptr) -> full -> scanned (scan_sel) -> dirty -> clear
//   (clear_sel) -> clean -> render again.
logic [1:0] scan_sel;    // slot scanout reads
logic [1:0] wr_ptr;      // slot the open/next render epoch writes
logic [1:0] clear_sel;   // slot the clear engine services next
logic [3:0] slot_full;   // rendered, awaiting or being displayed
logic [3:0] slot_clean;  // cleared, ready for a render epoch
logic       render_active;
logic       clear_busy;
logic [6:0] clear_word;

logic [6:0] scan_word;
logic [1:0] scan_bank_q;
logic scan_valid_q;

logic [8:0] lane_x [0:3];
logic [14:0] lane_color [0:3];
logic [7:0] lane_pen [0:3];
logic [3:0] bank_req;
logic [6:0] bank_addr [0:3];
logic [14:0] bank_color [0:3];
logic [7:0] bank_pen [0:3];

logic [3:0] plot_pending;
logic [1:0] plot_select_q;
logic [6:0] bank_addr_q [0:3];
logic [14:0] bank_color_q [0:3];
logic [7:0] bank_pen_q [0:3];
logic plot_shadow_q;
logic shadow_4bit_q;
logic [3:0] bypass_q;
logic [14:0] bypass_value_q [0:3];

logic [14:0] plot_source [0:3];
logic [14:0] write_value [0:3];

wire [1:0] scan_next = scan_sel + 2'd1;
// A render finishing on the very consumption edge that needs it still counts
// as available: slot_full[wr_ptr] is only committed on this clock.
wire scan_next_full = slot_full[scan_next] ||
                      (render_active && render_done && (wr_ptr == scan_next));

assign render_ready = slot_clean[wr_ptr] && !render_active;

// Dirty = displayed and freed, not yet cleared. Never touch the slot scanout
// still reads (its full bit drops only when scanout advances away, so during
// the visible frame the scanned slot is protected by slot_full; the explicit
// scan_sel exclusion covers the frame_sync window where no slot is full yet)
// and never touch an open render epoch's slot.
wire clear_slot_dirty = !slot_full[clear_sel] && !slot_clean[clear_sel] &&
                        !(render_active && (wr_ptr == clear_sel)) &&
                        (scan_sel != clear_sel);

// Sixteen tiny line stores: four ring slots, each split into four x-parity
// banks. Consecutive four-pixel batches contain at most one write for each
// x[1:0] bank. Tiny 88x15 banks waste a full M10K each, so keep them in
// MLABs. Each store is simple-dual-port: one write (plot commit or clear),
// one registered read (scanout, or the read-modify-write fetch when the slot
// owns the open render epoch).
//
// RTL-inferred arrays here (`ramstyle`-attributed, combined or split
// always_ff, declared inside or outside the generate loop) all left zero
// RAM-inference log lines and a straight logic-cell array every time
// (confirmed 2026-08-19, 745-830 LAB fitter overflow). This is the same
// Quartus 17 inference failure already fixed for the ES5506 voice banks
// (ssv_mlab32_sdp) and the sprite renderer's line metadata (ssv_mlab240_sdp):
// a big module with muxed write addresses/enables and a muxed read address
// defeats the inference pass with no warning at all. Same fix: instantiate
// the explicit altsyncram primitive instead of leaving it to inference.
logic [239:0] lineq_flat;

genvar gs, gb;
generate
for (gs = 0; gs < 4; gs = gs + 1) begin : g_slot
    for (gb = 0; gb < 4; gb = gb + 1) begin : g_bank
        wire [6:0] rd_addr = (render_active && (wr_ptr == gs[1:0]))
                             ? bank_addr[gb] : scan_word;
        // Clear and plot target different slots by construction (a slot
        // being cleared is neither full nor an open epoch), so the two
        // sources never collide. Mux ahead of the array instead of
        // branching the write inside the always block.
        wire wr_en   = (clear_busy && (clear_sel == gs[1:0])) ||
                       (plot_pending[gb] && (plot_select_q == gs[1:0]));
        wire [6:0]  wr_addr = (clear_busy && (clear_sel == gs[1:0]))
                             ? clear_word : bank_addr_q[gb];
        wire [14:0] wr_data = (clear_busy && (clear_sel == gs[1:0]))
                             ? 15'd0 : write_value[gb];
        wire [14:0] mem_q;

        ssv_mlab88_sdp #(.WIDTH(15)) u_mem (
            .clk     (clk),
            .wr_addr (wr_addr),
            .we      (wr_en),
            .wdata   (wr_data),
            .rd_addr (rd_addr),
            .q       (mem_q)
        );

        assign lineq_flat[(gs * 4 + gb) * 15 +: 15] = mem_q;
    end
end
endgenerate

integer lane_i;
integer bank_i;
integer bank_ff_i;
always_comb begin
    scan_word = (scan_x < ACTIVE_WIDTH) ? scan_x[8:2] : 7'd0;

    for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1) begin
        lane_x[lane_i] = plot_x[lane_i * 9 +: 9];
        lane_color[lane_i] = plot_color[lane_i * 15 +: 15];
        lane_pen[lane_i] = plot_pen[lane_i * 8 +: 8];
    end

    for (bank_i = 0; bank_i < 4; bank_i = bank_i + 1) begin
        bank_req[bank_i] = 1'b0;
        bank_addr[bank_i] = 7'd0;
        bank_color[bank_i] = 15'd0;
        bank_pen[bank_i] = 8'd0;
        for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1) begin
            if (render_active && plot_we[lane_i] &&
                (lane_x[lane_i] < ACTIVE_WIDTH) &&
                (lane_x[lane_i][1:0] == bank_i[1:0])) begin
                bank_req[bank_i] = 1'b1;
                bank_addr[bank_i] = lane_x[lane_i][8:2];
                bank_color[bank_i] = lane_color[lane_i];
                bank_pen[bank_i] = lane_pen[lane_i];
            end
        end

        plot_source[bank_i] =
            lineq_flat[15 * {plot_select_q, bank_i[1:0]} +: 15];
        if (bypass_q[bank_i])
            plot_source[bank_i] = bypass_value_q[bank_i];

        write_value[bank_i] = bank_color_q[bank_i];
        if (plot_shadow_q)
            write_value[bank_i] = shadow_4bit_q
                                ? {bank_pen_q[bank_i][3:0],
                                   plot_source[bank_i][10:0]}
                                : {bank_pen_q[bank_i][1:0],
                                   plot_source[bank_i][12:0]};
    end

    if (!scan_valid_q)
        scan_color = 15'd0;
    else
        scan_color = lineq_flat[15 * {scan_sel, scan_bank_q} +: 15];
end

always_ff @(posedge clk) begin
    scan_bank_q <= scan_x[1:0];
    scan_valid_q <= (scan_x < ACTIVE_WIDTH);
    scan_underrun <= 1'b0;

    if (rst) begin
        scan_sel <= 2'd3;
        wr_ptr <= 2'd0;
        clear_sel <= 2'd0;
        slot_full <= 4'd0;
        slot_clean <= 4'd0;
        render_active <= 1'b0;
        clear_busy <= 1'b0;
        clear_word <= 7'd0;
        render_go <= 1'b0;
        scan_bank_q <= 2'd0;
        scan_valid_q <= 1'b0;
        scan_underrun <= 1'b0;
        plot_pending <= 4'd0;
        plot_select_q <= 2'd0;
        plot_shadow_q <= 1'b0;
        shadow_4bit_q <= 1'b0;
        bypass_q <= 4'd0;
        for (bank_ff_i = 0; bank_ff_i < 4; bank_ff_i = bank_ff_i + 1) begin
            bank_addr_q[bank_ff_i] <= 7'd0;
            bank_color_q[bank_ff_i] <= 15'd0;
            bank_pen_q[bank_ff_i] <= 8'd0;
            bypass_value_q[bank_ff_i] <= 15'd0;
        end
    end
    else begin
        // The go pulse is unconditional: if a kick collides with frame_sync
        // the buffer drops the epoch (plots are rejected while render_active
        // is low) but the background renderer, which was started by the same
        // kick, must still be released from its clear wait or it stays busy
        // forever.
        render_go <= render_start;

        if (frame_sync) begin
            // Deterministic aligned state: scanout parks on slot 3 so the
            // frame's first consumption advances into slot 0, the slot the
            // frame's first render kick writes. All slots are invalidated;
            // the clear engine then re-clears slots 0..2 during vblank (slot
            // 3 waits until scanout moves off it at the first consumption).
            // This is the double-buffer frame_sync resync extended to the
            // ring: any misalignment an underrun left behind is bounded to
            // the frame it happened in.
            scan_sel <= 2'd3;
            wr_ptr <= 2'd0;
            clear_sel <= 2'd0;
            slot_full <= 4'd0;
            slot_clean <= 4'd0;
            render_active <= 1'b0;
            clear_busy <= 1'b0;
            clear_word <= 7'd0;
            plot_pending <= 4'd0;
            bypass_q <= 4'd0;
        end
        else begin
            // Plot pipeline: plots are registered one cycle and committed
            // into the epoch slot captured with them (plot_select_q), so a
            // batch in flight across render_done still lands in its own
            // line. The same-address read-after-write hazard of the
            // registered RMW fetch is covered by the bypass registers, as in
            // the double-buffered version.
            plot_pending <= bank_req;
            if (|bank_req) begin
                plot_select_q <= wr_ptr;
                plot_shadow_q <= plot_shadow;
                shadow_4bit_q <= shadow_4bit;
                for (bank_ff_i = 0; bank_ff_i < 4;
                     bank_ff_i = bank_ff_i + 1) begin
                    bank_addr_q[bank_ff_i] <= bank_addr[bank_ff_i];
                    bank_color_q[bank_ff_i] <= bank_color[bank_ff_i];
                    bank_pen_q[bank_ff_i] <= bank_pen[bank_ff_i];
                    bypass_q[bank_ff_i] <= plot_pending[bank_ff_i] &&
                                       (plot_select_q == wr_ptr) &&
                                       (bank_addr_q[bank_ff_i] ==
                                        bank_addr[bank_ff_i]);
                    bypass_value_q[bank_ff_i] <= write_value[bank_ff_i];
                end
            end
            else begin
                bypass_q <= 4'd0;
            end

            // Producer handshake.
            if (render_start) begin
                render_active <= 1'b1;
                slot_clean[wr_ptr] <= 1'b0;
            end
            if (render_done && render_active) begin
                render_active <= 1'b0;
                slot_full[wr_ptr] <= 1'b1;
                wr_ptr <= wr_ptr + 2'd1;
            end

            // Display consumption. On an empty ring, hold: scanout repeats
            // the last completed line for this raster line. The in-flight
            // render is NOT discarded (unlike the old double buffer's
            // missed-deadline drain) -- it is simply consumed one line late,
            // shifting the remainder of the frame down one line until
            // frame_sync realigns the ring. A one-line shift for one frame
            // is far less visible than the full-width streak the old scheme
            // produced.
            if (line_start) begin
                if (scan_next_full) begin
                    slot_full[scan_sel] <= 1'b0;
                    scan_sel <= scan_next;
                end
                else begin
                    scan_underrun <= 1'b1;
                end
            end

            // Clear engine: chases scanout around the ring, one freed slot
            // per line at most (88 cycles of work per ~3000-cycle line, and
            // a whole vblank for the frame_sync re-clear), so a single
            // sequential engine keeps up with all four slots.
            if (clear_busy) begin
                if (clear_word == LAST_WORD) begin
                    clear_busy <= 1'b0;
                    slot_clean[clear_sel] <= 1'b1;
                    clear_sel <= clear_sel + 2'd1;
                end
                else begin
                    clear_word <= clear_word + 1'd1;
                end
            end
            else if (clear_slot_dirty) begin
                clear_busy <= 1'b1;
                clear_word <= 7'd0;
            end
        end
    end
end

endmodule
