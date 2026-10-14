module suna8_palette
(
    input  logic clk,
    input  logic reset,

    input  logic palette_wr,
    input  logic [9:0] palette_wr_addr,
    input  logic [7:0] palette_wr_data,
    output logic [7:0] palette_rd_data,
    input  logic [9:0] palette_rd_addr,

    input  logic [2:0] profile_id,
    input  logic [7:0] protection_2_prev,
    input  logic [7:0] protection_2,

    // The renderer supplies a palette entry, not a byte address.  Palette
    // words are big-endian on the SunA bus and use RGBx 444 nibbles.
    input  logic [8:0] pixel_palette_index,
    output logic [7:0] pixel_r,
    output logic [7:0] pixel_g,
    output logic [7:0] pixel_b,
    output logic collision_seen
);

    // Split into even/odd byte planes (512 x 8 each) rather than one flat
    // 1024 x 8 array. This is necessary, not an optimization: the CPU port
    // needs a registered read (Quartus cannot map a combinational read onto
    // Cyclone V's M10K -- same root cause as suna8_sprite_ram.sv and
    // suna8_sound_memory.sv, see those files for the fuller rationale), and
    // the pixel-facing port reads two adjacent bytes (a 16-bit RGB word)
    // every cycle. A single flat array would need 3 ports (1 CPU
    // read/write + 2 simultaneous renderer read bytes), but a Cyclone V
    // M10K is true-dual-port (max 2 independent ports per block) -- Quartus
    // silently declines to infer such an array as RAM at all (no
    // "uninferred" info line anywhere in the log, just one register per
    // array bit; confirmed via the Aug 2026 fit failure: this array alone
    // cost 5,137 ALMs it should have cost ~0). Splitting into even/odd
    // planes means each plane only ever needs 2 ports (one CPU read/write
    // port, one renderer read-only port): the plane holding
    // pixel_byte_addr's low byte and the plane holding its high byte are
    // different planes, so both bytes read out in the same cycle without
    // either plane needing a 3rd port.
    (* ramstyle = "M10K" *) logic [7:0] palette_even [0:511];
    (* ramstyle = "M10K" *) logic [7:0] palette_odd  [0:511];

    // Brick Zone stores the bus bytes unscrambled, then presents a decoded
    // RGBx444 value to the palette device.  Keep a private raw shadow for
    // the adjacent byte needed when either half of a colour word is written;
    // the CPU-facing planes above remain byte-accurate for reads.
    (* ramstyle = "M10K" *) logic [7:0] brick_raw_even [0:511];
    (* ramstyle = "M10K" *) logic [7:0] brick_raw_odd  [0:511];
    (* ramstyle = "M10K" *) logic [7:0] display_even [0:511];
    (* ramstyle = "M10K" *) logic [7:0] display_odd  [0:511];

    logic [9:0] pixel_byte_addr;
    logic [7:0] even_cpu_q, odd_cpu_q;
    logic [7:0] even_pixel_q, odd_pixel_q;
    logic even_cpu_bypass_q, odd_cpu_bypass_q;
    logic [7:0] even_cpu_bypass_data_q, odd_cpu_bypass_data_q;
    logic cpu_parity_q;
    logic even_wr_en, odd_wr_en;

    // Stage-1 registers for the decoded display copy (2026-09-07 audit item
    // 21.2). The previous code read brick_raw_odd/even asynchronously inside
    // the always_ff that also wrote them, which Quartus cannot map onto M10K
    // with a registered read; both arrays fell back to 8,192 flip-flops.
    // Now the raw byte from the other plane is fetched with a registered
    // read in the same cycle the write is issued, and the decoded bytes are
    // written one clock later. The renderer's read of display_* already
    // tolerates a clock of latency (see the CPU/pixel read note above), and
    // the CPU cannot issue two palette writes within one clock.
    logic        disp_even_wr_q, disp_odd_wr_q;
    logic [8:0]  disp_addr_q;
    logic [7:0]  disp_data_q;
    logic [7:0]  raw_even_q, raw_odd_q;
    logic [7:0]  disp_prot_prev_q, disp_prot_now_q;

    function automatic [7:0] display_byte
    (
        input logic [2:0] profile,
        input logic [7:0] prot_prev,
        input logic [7:0] prot_now,
        input logic [7:0] even_byte,
        input logic [7:0] odd_byte,
        input logic high_byte
    );
        logic [15:0] rgb;
        logic [3:0] r;
        logic [3:0] g;
        logic [3:0] b;
        begin
            rgb = {even_byte, odd_byte};
            if ((profile == 3'd5) &&
                (prot_prev == 8'h3c) && (prot_now == 8'h80)) begin
                rgb = rgb ^ 16'h4444;
                r = rgb[15:12];
                g = rgb[11:8];
                b = rgb[7:4];
            end else if ((profile == 3'd5) &&
                         (prot_prev == 8'ha8) && (prot_now == 8'h00)) begin
                r = {rgb[15], rgb[14], rgb[11], rgb[12]};
                g = {rgb[13], rgb[10], rgb[9], rgb[8]};
                b = {rgb[7], rgb[6], rgb[3], rgb[4]};
            end else begin
                r = rgb[15:12];
                g = rgb[11:8];
                b = rgb[7:4];
            end
            display_byte = high_byte ? {r, g} : {b, 4'h0};
        end
    endfunction

    assign even_wr_en = !reset && palette_wr && !palette_wr_addr[0];
    assign odd_wr_en  = !reset && palette_wr &&  palette_wr_addr[0];

    // Both the CPU-facing and pixel-facing reads are registered (one cycle
    // of address-to-data latency) rather than combinational, same reason as
    // the plane split above. Both consumers have slack: the CPU only runs
    // on ce_cpu = ce_pix (1 in 4 raw clk cycles), and the pixel pipeline
    // already carries one cycle of latency through suna8_framebuffer.sv's
    // own registered read before pixel_palette_index is even presented
    // here, inside the same 4-raw-clk pixel period that ce_pix defines --
    // one more registered cycle here still resolves before the next ce_pix
    // sample point.
    always_ff @(posedge clk) begin
        if (even_wr_en)
            palette_even[palette_wr_addr[9:1]] <= palette_wr_data;
        even_cpu_q <= palette_even[palette_rd_addr[9:1]];
        cpu_parity_q <= palette_rd_addr[0];
        even_cpu_bypass_q <= even_wr_en &&
            (palette_wr_addr[9:1] == palette_rd_addr[9:1]);
        even_cpu_bypass_data_q <= palette_wr_data;
    end

    always_ff @(posedge clk) begin
        if (odd_wr_en)
            palette_odd[palette_wr_addr[9:1]] <= palette_wr_data;
        odd_cpu_q <= palette_odd[palette_rd_addr[9:1]];
        odd_cpu_bypass_q <= odd_wr_en &&
            (palette_wr_addr[9:1] == palette_rd_addr[9:1]);
        odd_cpu_bypass_data_q <= palette_wr_data;
    end

    // Update the decoded display copy only when the corresponding raw bus
    // byte is written.  This matches MAME's banked_paletteram_w: a later
    // protection transition affects future writes, not colours already in
    // the palette device.
    // Stage 1: write the raw plane, read the other plane (registered, so
    // each array is one write port plus one unconditional registered read
    // port, the shape Quartus 17 maps onto M10K), and latch the write.
    always_ff @(posedge clk) begin
        if (even_wr_en)
            brick_raw_even[palette_wr_addr[9:1]] <= palette_wr_data;
        raw_even_q <= brick_raw_even[palette_wr_addr[9:1]];
    end

    always_ff @(posedge clk) begin
        if (odd_wr_en)
            brick_raw_odd[palette_wr_addr[9:1]] <= palette_wr_data;
        raw_odd_q <= brick_raw_odd[palette_wr_addr[9:1]];
    end

    always_ff @(posedge clk) begin
        disp_even_wr_q   <= even_wr_en;
        disp_odd_wr_q    <= odd_wr_en;
        disp_addr_q      <= palette_wr_addr[9:1];
        disp_data_q      <= palette_wr_data;
        disp_prot_prev_q <= protection_2_prev;
        disp_prot_now_q  <= protection_2;
    end

    // Stage 2: decode with the byte just written plus the other plane's
    // byte as it was when the write was issued. This matches MAME's
    // banked_paletteram_w, which decodes from the palette bytes at the time
    // of the write: a later protection transition affects future writes,
    // not colours already in the palette device.
    wire [7:0] disp_even_src = disp_even_wr_q ? disp_data_q : raw_even_q;
    wire [7:0] disp_odd_src  = disp_odd_wr_q  ? disp_data_q : raw_odd_q;

    always_ff @(posedge clk) begin
        if (disp_even_wr_q || disp_odd_wr_q) begin
            display_even[disp_addr_q] <= display_byte(
                profile_id, disp_prot_prev_q, disp_prot_now_q,
                disp_even_src, disp_odd_src, 1'b1);
            display_odd[disp_addr_q] <= display_byte(
                profile_id, disp_prot_prev_q, disp_prot_now_q,
                disp_even_src, disp_odd_src, 1'b0);
        end
    end

    always_ff @(posedge clk)
        even_pixel_q <= display_even[pixel_byte_addr[9:1]];

    always_ff @(posedge clk)
        odd_pixel_q <= display_odd[pixel_byte_addr[9:1]];

    // The renderer reads both byte planes every cycle while the CPU can
    // write either plane. Keep a sticky indicator for any same-row collision;
    // the actual read-during-write value remains the fitted RAM's contract.
    always_ff @(posedge clk) begin
        if (reset)
            collision_seen <= 1'b0;
        else if (palette_wr &&
                 (palette_wr_addr[9:1] == pixel_byte_addr[9:1]))
            collision_seen <= 1'b1;
    end

    always_comb begin
        // palette_rd_addr is always an exact byte address (caller supplies
        // the exact byte), so cpu_parity_q selects which plane actually
        // holds the requested byte.
        palette_rd_data = cpu_parity_q
            ? (odd_cpu_bypass_q ? odd_cpu_bypass_data_q : odd_cpu_q)
            : (even_cpu_bypass_q ? even_cpu_bypass_data_q : even_cpu_q);

        // pixel_byte_addr is always even (the low byte of the 16-bit RGB
        // word); its high byte lives at pixel_byte_addr+1, i.e. the same
        // [9:1] row of the odd plane -- matching the original
        // {palette_ram[pixel_byte_addr], palette_ram[pixel_byte_addr+1]}
        // pairing exactly, just split across the two planes instead of
        // computed via a "+1" address.
        pixel_byte_addr = {pixel_palette_index, 1'b0};

        pixel_r = {even_pixel_q[7:4], even_pixel_q[7:4]};
        pixel_g = {even_pixel_q[3:0], even_pixel_q[3:0]};
        pixel_b = {odd_pixel_q[7:4],  odd_pixel_q[7:4]};
    end

endmodule
