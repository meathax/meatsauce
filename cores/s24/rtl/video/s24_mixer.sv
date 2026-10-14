// 315-5294 register file plus a single-pixel priority comparator. The register
// priority fields and blanking bit match MAME. Sprite/tile tie behavior is
// kept explicit so differential pixel tests can lock it down.
module s24_mixer (
    input  logic        clk,
    input  logic        reset,
    input  logic        cpu_wr,
    input  logic [3:0]  cpu_addr,
    input  logic [15:0] cpu_din,
    input  logic [1:0]  cpu_be,
    output logic [15:0] cpu_dout,

    input  logic [11:0] tile0_pixel,
    input  logic [11:0] tile1_pixel,
    input  logic [11:0] tile2_pixel,
    input  logic [11:0] tile3_pixel,
    input  logic        tile0_cat,
    input  logic        tile1_cat,
    input  logic        tile2_cat,
    input  logic        tile3_cat,
    input  logic        tile0_valid,
    input  logic        tile1_valid,
    input  logic        tile2_valid,
    input  logic        tile3_valid,
    input  logic [13:0] sprite0_pixel,
    input  logic [13:0] sprite1_pixel,
    input  logic [13:0] sprite2_pixel,
    input  logic [13:0] sprite3_pixel,
    input  logic [10:0] sprite0_rank,
    input  logic [10:0] sprite1_rank,
    input  logic [10:0] sprite2_rank,
    input  logic [10:0] sprite3_rank,
    // Tilemaps whose disable bit is toggling every frame (see s24_tile.sv).
    // Such a layer is now rendered on every frame, so mixed_pixel_alt repeats
    // the priority resolve with it removed. Averaging the two downstream
    // reproduces what the original CRT integrated out of the two fields.
    input  logic [3:0]  tile_blink,
    output logic [13:0] mixed_pixel,
    output logic [13:0] mixed_pixel_alt,
    output logic        display_blank,
    // MAME identifies mixer register 13 bit 1 (mask 0x2) as the System 24
    // screen-flip control.  The FPGA framebuffer path consumes this board
    // signal after the native mixer, while bit 0 continues to blank pixels.
    output logic        screen_flip
);
    import s24_pkg::*;
    logic [15:0] regs [0:15];
    integer i;

    assign cpu_dout = regs[cpu_addr];
    assign display_blank = regs[13][0];
    assign screen_flip = regs[13][1];

    // One evaluation of the 315-5294 priority chain. The tile validity inputs
    // are arguments so the same logic can be re-evaluated with a blinking
    // tilemap withheld; everything else is unchanged from the single-pass
    // version this replaced.
    function automatic logic [13:0] resolve_pixel(
        input logic valid0,
        input logic valid1,
        input logic valid2,
        input logic valid3
    );
        logic [3:0] best_pri;
        logic [3:0] pri;
        logic [2:0] backdrop_pri;
        logic backdrop_found;
        logic pixel_found;
        logic sprite0_ok,sprite1_ok,sprite2_ok,sprite3_ok;
        logic left_sprite_valid,right_sprite_valid;
        logic [10:0] left_sprite_rank,right_sprite_rank;
        logic [1:0] left_sprite_choice,right_sprite_choice;
        logic [13:0] chosen_sprite_pixel;
        logic [13:0] result;
    begin
        result = 14'h0000;
        backdrop_pri = 0;
        backdrop_found = 0;

        // MAME first draws every category-zero tile pass with
        // TILEMAP_DRAW_OPAQUE in reverse priority order. OPAQUE bypasses both
        // pen transparency and category matching, so the final fallback is
        // the lowest-priority selected physical layer regardless of the
        // current tile's category. Equal priorities leave the higher-numbered
        // layer underneath. Raw tile pixels retain palette color zero here.
        if (valid0) begin
            backdrop_pri = regs[0][2:0];
            result = {2'b00,tile0_pixel};
            backdrop_found = 1;
        end
        if (valid1 &&
                (!backdrop_found || regs[2][2:0] <= backdrop_pri)) begin
            backdrop_pri = regs[2][2:0];
            result = {2'b00,tile1_pixel};
            backdrop_found = 1;
        end
        if (valid2 &&
                (!backdrop_found || regs[4][2:0] <= backdrop_pri)) begin
            backdrop_pri = regs[4][2:0];
            result = {2'b00,tile2_pixel};
            backdrop_found = 1;
        end
        if (valid3 &&
                (!backdrop_found || regs[6][2:0] <= backdrop_pri)) begin
            backdrop_pri = regs[6][2:0];
            result = {2'b00,tile3_pixel};
            backdrop_found = 1;
        end

        best_pri = 0;
        pri = 0;
        pixel_found = 0;

        // MAME's equal-priority default order leaves lower tile pass numbers
        // above higher ones, hence the reverse evaluation order here.
        if (valid3 && tile3_pixel[3:0] != 0) begin
            best_pri = {1'b0,
                tile3_cat ? regs[7][2:0] : regs[6][2:0]};
            result = {2'b00,tile3_pixel};
            pixel_found = 1;
        end
        if (valid2 && tile2_pixel[3:0] != 0) begin
            pri = {1'b0,
                tile2_cat ? regs[5][2:0] : regs[4][2:0]};
            if (!pixel_found || pri >= best_pri) begin
                best_pri=pri; result={2'b00,tile2_pixel}; pixel_found=1;
            end
        end
        if (valid1 && tile1_pixel[3:0] != 0) begin
            pri = {1'b0,
                tile1_cat ? regs[3][2:0] : regs[2][2:0]};
            if (!pixel_found || pri >= best_pri) begin
                best_pri=pri; result={2'b00,tile1_pixel}; pixel_found=1;
            end
        end
        if (valid0 && tile0_pixel[3:0] != 0) begin
            pri = {1'b0,
                tile0_cat ? regs[1][2:0] : regs[0][2:0]};
            if (!pixel_found || pri >= best_pri) begin
                best_pri=pri; result={2'b00,tile0_pixel}; pixel_found=1;
            end
        end
        // Each group supplies its frontmost candidate. Reject candidates that
        // the selected tile pass blocks, then choose the largest reverse-list
        // rank. This preserves MAME's ability to show an earlier sprite when a
        // later sprite from another group is hidden behind a tile.
        // segaic24.cpp uses spri[3-group]: indirect color bits 7:6 map to
        // mixer registers 11,10,9,8 for groups 0,1,2,3 respectively.
        sprite0_ok = sprite0_pixel != 0 &&
                     (!pixel_found || {1'b0,regs[11][2:0]} >= best_pri);
        sprite1_ok = sprite1_pixel != 0 &&
                     (!pixel_found || {1'b0,regs[10][2:0]} >= best_pri);
        sprite2_ok = sprite2_pixel != 0 &&
                     (!pixel_found || {1'b0,regs[9][2:0]} >= best_pri);
        sprite3_ok = sprite3_pixel != 0 &&
                     (!pixel_found || {1'b0,regs[8][2:0]} >= best_pri);

        // A balanced rank tree shortens the pixel-to-palette path. Strict
        // greater-than comparisons preserve the old/MAME tie rule: the
        // lower-numbered group wins equal ranks.
        left_sprite_valid = sprite0_ok || sprite1_ok;
        left_sprite_rank = sprite0_rank;
        left_sprite_choice = 2'd0;
        if (sprite1_ok && (!sprite0_ok || sprite1_rank > sprite0_rank)) begin
            left_sprite_rank = sprite1_rank;
            left_sprite_choice = 2'd1;
        end

        right_sprite_valid = sprite2_ok || sprite3_ok;
        right_sprite_rank = sprite2_rank;
        right_sprite_choice = 2'd2;
        if (sprite3_ok && (!sprite2_ok || sprite3_rank > sprite2_rank)) begin
            right_sprite_rank = sprite3_rank;
            right_sprite_choice = 2'd3;
        end

        chosen_sprite_pixel = 0;
        if (right_sprite_valid &&
            (!left_sprite_valid || right_sprite_rank > left_sprite_rank)) begin
            case(right_sprite_choice)
                2'd2: chosen_sprite_pixel = sprite2_pixel;
                default: chosen_sprite_pixel = sprite3_pixel;
            endcase
        end else if (left_sprite_valid) begin
            case(left_sprite_choice)
                2'd0: chosen_sprite_pixel = sprite0_pixel;
                default: chosen_sprite_pixel = sprite1_pixel;
            endcase
        end

        if (left_sprite_valid || right_sprite_valid) begin
            // Indirect color 1 is the sprite shadow pen. MAME ORs the
            // shadow-bank bit into the already selected tile/background color.
            if (chosen_sprite_pixel == 14'h2000) result[13] = 1'b1;
            else result = chosen_sprite_pixel;
            pixel_found = 1;
        end
        if (display_blank) result = 0;
        resolve_pixel = result;
    end
    endfunction

    always_comb begin
        mixed_pixel = resolve_pixel(tile0_valid,tile1_valid,
                                    tile2_valid,tile3_valid);
        // Withholding the blinking tilemap reproduces the field in which the
        // game had that layer disabled. With tile_blink all zero this is
        // bit-identical to mixed_pixel, so the downstream average is a no-op.
        mixed_pixel_alt = resolve_pixel(tile0_valid & ~tile_blink[0],
                                        tile1_valid & ~tile_blink[1],
                                        tile2_valid & ~tile_blink[2],
                                        tile3_valid & ~tile_blink[3]);
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            for (i=0;i<16;i=i+1) regs[i] <= 0;
        end else if (cpu_wr) begin
            regs[cpu_addr] <= merge16(regs[cpu_addr],cpu_din,cpu_be);
        end
    end
endmodule
