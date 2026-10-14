// Double-buffered on-chip framebuffer holding a 9-bit palette index per
// pixel (256x224 x2 banks). The sprite renderer writes into the "back"
// bank (whichever bank the raster is *not* currently displaying); the
// raster always reads from the "front" bank. On frame_tick (vblank rising
// edge) the banks swap and the new back bank is cleared to palette index
// 0xFF (matching suna8_v.cpp's screen_update(): `bitmap.fill(0xff,
// cliprect);` runs before every draw_sprites() call every frame -- MAME's
// pen 0xff numerically equals this framebuffer's {palette_group,
// pixel_index} 9-bit encoding's value 255, since pixel_palette_index is
// exactly that concatenation).
//
// The clear runs opportunistically: one clear-write per cycle, but only
// on cycles the sprite renderer isn't already writing that cycle, so a
// sprite write is never dropped and the clear simply takes as many idle
// cycles as it needs (57,344 cycles worst case, far under one frame
// period of 405,504 raw clk cycles -- comfortably finishes before the
// next frame_tick even under heavy sprite-write load).
//
// Storage layout (Aug 2026 rework): TWO physically separate power-of-2
// banks (65536 x 9 each), addressed by plain {y, x} concatenation, each
// with exactly one uniformly-shaped write port and one unconditional
// registered read port -- the same shape suna8_sprite_ram.sv /
// suna8_palette.sv already use, and the only shape Quartus 17 reliably
// maps onto Cyclone V M10K. The previous implementation was one flat
// 114,688-entry (non-power-of-2) array indexed by "bank_base + y*256 + x"
// arithmetic with two differently-shaped write sites in a single
// always_ff -- Quartus never classified it as a RAM candidate at all (no
// "inferred altsyncram" line, no "uninferred" line, in ANY synthesis log
// including the last fully-successful Aug 5 build; only the
// index-width Warning 10027 hinted at it). Per this project's own
// build-repair notes, that silent non-classification is the top known
// cause of catastrophic synthesis-size blowups: a 1-Mbit array headed
// for one register per bit hands the netlist optimizer ~10^6 extra
// cells to chew on. Rows y >= 224 of each bank exist only to make the
// depth a power of two; they are never written (the renderer bounds
// check guarantees wr_y <= 223) and reads from them (rd_y wraps during
// vblank) are don't-cares blanked by suna8_core.sv's video mux.
module suna8_framebuffer
(
    input  logic clk,
    input  logic reset,
    input  logic frame_tick,

    input  logic wr_en,
    input  logic [7:0] wr_x,
    input  logic [7:0] wr_y,
    input  logic [8:0] wr_data,
    input  logic priority_en,
    input  logic [7:0] priority_y,

    // The sprite producer is serialized, so a complete pass can span more
    // than one raster frame.  Hold the completed back bank until a vblank
    // boundary instead of swapping a partially rendered image.
    input  logic render_done,
    output logic render_active,
    // High while the back bank is being cleared after a swap (or the
    // boot-time clear); suna8_core.sv snapshots the sprite list on its
    // rising edge.
    output logic clear_active,
    output logic frame_valid,

    input  logic [7:0] rd_x,
    input  logic [7:0] rd_y,
    output logic [8:0] rd_data
);

    // 224 rows x 256 columns actually used per bank; the clear counter
    // walks exactly this many entries. With {y, x} concatenation
    // addressing, addr = y*256 + x, so a flat 0..57343 counter covers
    // y = 0..223, x = 0..255 contiguously -- identical coverage to the
    // previous flat-offset clear.
    localparam int BANK_SIZE = 57344;

    // M10K explicitly: 9 bits wide x 65536 deep is far past MLAB
    // territory, and an MLAB fallback would waste 11 of every 20 bits
    // per row (see the byte-wide-MLAB note in the build guidelines).
    (* ramstyle = "M10K" *) logic [8:0] bank0 [0:65535];
    (* ramstyle = "M10K" *) logic [8:0] bank1 [0:65535];

    logic active_display;      // 1 => bank1 is front (displayed), bank0 is back
    logic clearing;
    logic render_done_latched;
    logic [15:0] clear_addr;

    // One uniformly-shaped write port shared by the sprite write and the
    // opportunistic clear. The sprite write always wins the port; the
    // clear only takes it on idle cycles (and never on the frame_tick
    // cycle itself, when the banks are mid-swap -- the old back bank is
    // about to become the front bank, and a stray clear-write into it
    // would punch a one-pixel hole in the displayed frame).
    logic        wr_port_en;
    logic [15:0] wr_port_addr;
    logic [8:0]  wr_port_data;
    logic [15:0] rd_addr;
    logic [8:0]  bank0_q, bank1_q;
    // MAME's text priority operation fills complete scanline rows, not an
    // arbitrary per-pixel mask.  A row bitmap therefore models the actual
    // hardware-visible effect with 224 flip-flops instead of another pair of
    // 57k-entry memories.  Each framebuffer bank keeps its own mask.
    logic [223:0] priority0_rows, priority1_rows;
    logic priority_hit;
    logic sprite_write_allowed;

    always_comb begin
        // Never write on the swap edge: the old back bank becomes the new
        // front bank at that edge and a producer write would punch a hole in
        // the first visible line of the new frame.
        priority_hit = 1'b0;
        if (wr_y < 8'd224)
            // active_display selects the front bank; the renderer always
            // writes the opposite bank.
            priority_hit = active_display ? priority0_rows[wr_y]
                                           : priority1_rows[wr_y];
        sprite_write_allowed = wr_en && !frame_tick &&
            (!priority_hit || priority_en);
        wr_port_en   = sprite_write_allowed ||
                       (clearing && !frame_tick && !sprite_write_allowed);
        wr_port_addr = sprite_write_allowed ? {wr_y, wr_x} : clear_addr;
        wr_port_data = sprite_write_allowed ? wr_data : 9'd255;
        rd_addr      = {rd_y, rd_x};
    end

    // Each bank: one write port, one *unconditional* registered read --
    // the read must not sit under reset or any other condition, or
    // Quartus reports "uninferred due to asynchronous read logic" and
    // falls back to registers (see suna8_sprite_ram.sv for the fuller
    // rationale). active_display selects which bank the shared write
    // port drives (the back bank) and which registered output feeds
    // rd_data (the front bank). Read-during-write across banks never
    // collides: the front bank is only read, the back bank only written.
    always_ff @(posedge clk) begin
        if (!reset && wr_port_en && active_display)
            bank0[wr_port_addr] <= wr_port_data;
        bank0_q <= bank0[rd_addr];
    end

    always_ff @(posedge clk) begin
        if (!reset && wr_port_en && !active_display)
            bank1[wr_port_addr] <= wr_port_data;
        bank1_q <= bank1[rd_addr];
    end

    assign rd_data = active_display ? bank1_q : bank0_q;
    assign render_active = !reset && !clearing && !render_done_latched;
    assign clear_active = !reset && clearing;

    always_ff @(posedge clk) begin
        if (reset) begin
            active_display <= 1'b0;
            // Clear the initial back bank before the first producer pass.
            // The initial front bank is never exposed while frame_valid is
            // low, so it need not consume a second boot-time clear.
            clearing <= 1'b1;
            clear_addr <= 16'd0;
            render_done_latched <= 1'b0;
            frame_valid <= 1'b0;
            priority0_rows <= '0;
            priority1_rows <= '0;
        end else begin
            if (render_done)
                render_done_latched <= 1'b1;

            if (frame_tick && (render_done_latched || render_done)) begin
                active_display <= ~active_display;
                clearing <= 1'b1;
                clear_addr <= 16'd0;
                render_done_latched <= 1'b0;
                frame_valid <= 1'b1;
                // The bank becoming the new back buffer starts with a blank
                // priority map, just as the pixel bank starts with 0xff.
                if (active_display)
                    priority1_rows <= '0;
                else
                    priority0_rows <= '0;
            end else if (clearing && !sprite_write_allowed) begin
                // Advance whenever the clear actually took the write port
                // (wr_port_en's own "clearing && !sprite_write_allowed"
                // term), not just when there is no sprite write attempt at
                // all. A pending write that loses to the priority mask
                // (wr_en=1 but sprite_write_allowed=0) still yields the
                // port to the clear -- the old "!wr_en" guard left
                // clear_addr stuck re-clearing the same address every such
                // cycle instead of progressing, extending the clear pass.
                if (clear_addr == BANK_SIZE[15:0] - 16'd1)
                    clearing <= 1'b0;
                else
                    clear_addr <= clear_addr + 16'd1;
            end

            if (priority_en && !frame_tick && (priority_y < 8'd224)) begin
                if (active_display)
                    priority0_rows[priority_y] <= 1'b1;
                else
                    priority1_rows[priority_y] <= 1'b1;
            end
        end
    end

endmodule
