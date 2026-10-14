module suna8_sprite_ram
(
    input  logic clk,
    input  logic reset,
    input  logic wr_en,
    input  logic [15:0] wr_addr,
    input  logic [7:0] wr_data,
    input  logic [15:0] cpu_rd_addr,
    output logic [7:0] cpu_rd_data,
    input  logic [15:0] renderer_rd_addr,
    output logic [7:0] renderer_rd_data,
    // Pulse: copy the whole 32 KiB sprite RAM (chip 0 at 0x0000-0x3FFF,
    // chip 1 at 0x4000-0x7FFF) into the shadow the renderer reads from.
    input  logic snapshot_start,
    output logic snapshot_busy,
    output logic collision_seen
);

    // Four 8 KiB banks cover the later SunA reference space.  The two
    // 16 KiB halves are also the two independent Spark Man sprite engines.
    //
    // Both reads are registered (one cycle of latency from address to
    // data) rather than the combinational reads this module used to have.
    // Quartus cannot map a combinational read onto Cyclone V's M10K block
    // RAM -- Analysis & Synthesis reported this array "uninferred due to
    // asynchronous read logic" and fell back to one register per bit
    // (262,144 registers for this 32 KiB array alone), overflowing the
    // device's register budget outright (Error (276003)). The one-cycle
    // latency is absorbed for free on the CPU-facing port: the CPU only
    // ever runs on ce_pix/sound_ce, themselves gated to at most 1 in 4 raw
    // clk cycles, so an extra raw-clk cycle of read latency resolves well
    // before the CPU's own next sample point. The renderer-facing port has
    // no such slack (its FSM advances every raw clk cycle); its consumer
    // (suna8_sprite_render.sv) is restructured with an explicit ST_RAM_WAIT
    // bubble state to account for it. wr_addr and cpu_rd_addr are always
    // driven from the same value by the caller (suna8_main_memory.sv sets
    // sprite_wr_addr = sprite_rd_addr), so this is a genuine two-port
    // memory (one CPU read/write port, one renderer read-only port), not
    // three independent ports.
    logic [7:0] sprite_ram [0:32767];
    logic [7:0] cpu_mem_q, renderer_mem_q;
    logic cpu_bypass_q, renderer_bypass_q;
    logic [7:0] cpu_bypass_data_q, renderer_bypass_data_q;

    always_ff @(posedge clk) begin
        if (!reset && wr_en)
            sprite_ram[wr_addr[14:0]] <= wr_data;
        // Keep the RAM read unconditional for M10K inference, then apply a
        // registered write-through policy outside the inferred memory.  This
        // makes same-cycle CPU/renderer collisions deterministic (new data)
        // without embedding a conditional read mux in the RAM template.
        cpu_mem_q <= sprite_ram[cpu_rd_addr[14:0]];
        cpu_bypass_q <= wr_en &&
            (wr_addr[14:0] == cpu_rd_addr[14:0]);
        cpu_bypass_data_q <= wr_data;
    end

    // Sprite-list snapshot. The renderer used to read the live sprite RAM
    // over the whole of its pass (roughly 60% of a frame at 24 MHz on a
    // full list), so a game that rewrites its list mid-frame (Hard Head
    // 2's scanline-112 NMI moves its title-screen notes; Brick Zone's
    // attract text) was rendered from a mixture of old and new entries
    // that matches neither MAME's picture nor any real frame. MAME's
    // screen_update reads the list once, at the start of vblank; the PCB's
    // line-based sprite hardware reads it during active display. Both see
    // a list the CPU has finished with. Copy the whole RAM into a shadow
    // at the frame tick, under the framebuffer's own clear pass (57,344
    // clocks, longer than this 32,768-clock copy), and let the renderer
    // read only the shadow. The copy reuses the renderer read port, which
    // is idle while the framebuffer clears.
    //
    // The whole RAM, not the first 8 KiB of each chip. Each chip's
    // reference space is 16 KiB (MAME's draw_sprites() reads
    // `m_banked_spriteram + which*0x2000*2`, i.e. 0x4000 bytes per chip):
    // tile pages 0-3 in the first half, pages 4-7 in the second. The 4x4
    // sprite format (code & 0xc0 == 0x40) always sources pages 4-7
    // (suna8_v.cpp: `srcpg = ((code >> 4) & 3) + 4`), and that is the
    // format the later games draw their player with (hardhea2, sparkman,
    // starfigh, brickzn). The first version of this shadow copied 8 KiB
    // per chip and folded the renderer address over it, so every 4x4
    // sprite was rendered from page 0-3 tile codes -- HUD glyphs in place
    // of the player -- while the 2x2/2x32/4x32 sprites the attract modes
    // draw from pages 0-3 rendered correctly.
    logic [7:0] shadow_ram [0:32767];
    logic [14:0] copy_idx;
    logic [14:0] copy_wr_idx;
    logic copy_wr_en;
    logic [14:0] renderer_port_addr;
    logic [7:0] shadow_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            snapshot_busy <= 1'b0;
            copy_idx <= 15'd0;
            copy_wr_en <= 1'b0;
            copy_wr_idx <= 15'd0;
        end else begin
            copy_wr_en <= snapshot_busy;
            copy_wr_idx <= copy_idx;
            if (snapshot_start) begin
                snapshot_busy <= 1'b1;
                copy_idx <= 15'd0;
            end else if (snapshot_busy) begin
                if (copy_idx == 15'h7fff)
                    snapshot_busy <= 1'b0;
                else
                    copy_idx <= copy_idx + 15'd1;
            end
        end
    end

    assign renderer_port_addr = snapshot_busy ? copy_idx : renderer_rd_addr[14:0];

    always_ff @(posedge clk) begin
        renderer_mem_q <= sprite_ram[renderer_port_addr];
        renderer_bypass_q <= wr_en &&
            (wr_addr[14:0] == renderer_port_addr);
        renderer_bypass_data_q <= wr_data;
    end

    // Registered read-modify path: the byte read one clock ago lands in the
    // shadow one clock later, so the last copy write drains one clock
    // after snapshot_busy drops; the renderer's first shadow read after
    // re-activation is several clocks later (framebuffer clear).
    wire [7:0] copy_data = renderer_bypass_q ? renderer_bypass_data_q :
                                               renderer_mem_q;
    always_ff @(posedge clk) begin
        if (copy_wr_en)
            shadow_ram[copy_wr_idx] <= copy_data;
        shadow_q <= shadow_ram[renderer_rd_addr[14:0]];
    end

    assign cpu_rd_data = cpu_bypass_q ? cpu_bypass_data_q : cpu_mem_q;
    assign renderer_rd_data = shadow_q;

`ifdef VERILATOR
    // Snapshot tearing probe. The copy below walks 32,768 addresses one per
    // clock, about 8% of a frame, while the CPU keeps running. A CPU write
    // that lands on a slot the copy has NOT reached yet is taken into the
    // shadow, so that slot shows the new value while every slot already
    // copied shows the old one -- one rendered frame built from two
    // different list states. With a scrolling game that is a vertical seam
    // between the sprites drawn at the old X and those at the new X, coming
    // and going with the CPU's update timing. MAME reads the list once,
    // instantaneously, and cannot tear this way.
    logic [31:0] snapshot_tear_writes;
    always_ff @(posedge clk) begin
        if (reset)
            snapshot_tear_writes <= 32'd0;
        else if (snapshot_busy && wr_en &&
                 // only a slot the copy has not yet reached
                 (wr_addr[14:0] > copy_idx))
            snapshot_tear_writes <= snapshot_tear_writes + 32'd1;
    end
`endif

    // A CPU write and renderer read to the same M10K row are a mixed-port
    // collision. Cyclone V read-during-write mode is not safe to infer from
    // the behavioural model, so retain evidence instead of silently forcing
    // an old-data/new-data policy that may be wrong for the fitted RAM.
    always_ff @(posedge clk) begin
        if (reset)
            collision_seen <= 1'b0;
        else if (wr_en && (wr_addr[14:0] == renderer_rd_addr[14:0]))
            collision_seen <= 1'b1;
    end

endmodule
