// Portable regression copied from the MeatCore Credits framework.
// verify_credits.py inserts the actual host instance and dismiss expression,
// then adapts this fixture's 320x240 / two-frame defaults to host geometry.
`timescale 1ns/1ps
module overlay_tb;
    reg clk = 0;
    always #5 clk = !clk;
    reg reset = 1, ce = 0, trigger = 0, dismiss = 0;
    reg [191:0] joysticks = 0;
    reg [10:0] ps2_key = 0;
    reg [2:0] mouse_buttons = 0;
    reg [1:0] mister_buttons = 0;
    reg osd_status = 0;
    wire any_button = dismiss | |joysticks | ps2_key[9] |
                      |mouse_buttons | |mister_buttons | osd_status;
    reg [7:0] r = 0, g = 0, bl = 0;
    reg hs = 0, vs = 0, hb = 1, vb = 1;
    wire [7:0] ro, go, bo;
    wire hso, vso, hbo, vbo, deo, active;
    credits_overlay #(.SCROLL_FRAMES(2)) dut (
        .clk_video(clk), .reset(reset), .ce_pixel(ce),
        .menu_trigger(trigger), .dismiss(any_button),
        .r_in(r), .g_in(g), .b_in(bl), .hs_in(hs), .vs_in(vs),
        .hblank_in(hb), .vblank_in(vb),
        .r_out(ro), .g_out(go), .b_out(bo), .hs_out(hso), .vs_out(vso),
        .hblank_out(hbo), .vblank_out(vbo), .de_out(deo), .active(active));
    reg [27:0] expected[0:2];
    integer ex[0:2], ey[0:2];
    reg overlay[0:2];
    integer samples = 0, checks = 0, pixels = 0, fd = 0;
    integer sx, sy, capture = 0, gap = 0;
    integer start_phase;
    integer button_index;
    reg [27:0] held;

    task pixel(input integer px, input integer py, input integer active_pixel,
               input integer vertical_blank);
        begin
            @(negedge clk);
            ce = 1; hb = !active_pixel; vb = vertical_blank;
            hs = !active_pixel && (px % 2); vs = vertical_blank && (py % 2);
            r = 32 + ((px*3 + py) % 96);
            g = 24 + ((py*2 + px) % 80);
            bl = 48 + ((px + py*3) % 96);
            expected[2] = expected[1]; expected[1] = expected[0];
            expected[0] = {r,g,bl,hs,vs,hb,vb};
            ex[2] = ex[1]; ex[1] = ex[0]; ex[0] = px;
            ey[2] = ey[1]; ey[1] = ey[0]; ey[0] = py;
            overlay[2] = overlay[1]; overlay[1] = overlay[0]; overlay[0] = active;
            @(posedge clk); #1;
            if (samples >= 2) begin
                if ({hso,vso,hbo,vbo} !== expected[2][3:0])
                    $fatal(1, "timing pipeline mismatch");
                if (deo !== !(expected[2][1] || expected[2][0]))
                    $fatal(1, "DE does not match blanking");
                if (!overlay[2] && {ro,go,bo} !== expected[2][27:4])
                    $fatal(1, "inactive overlay modified RGB");
                checks = checks + 1;
                if (capture && deo) begin
                    $fwrite(fd, "%c%c%c", ro, go, bo);
                    pixels = pixels + 1;
                end
            end
            samples = samples + 1;
            held = {ro,go,bo,hso,vso,hbo,vbo};
            // Nonuniform CE spacing verifies both the ROM and timing hold correctly.
            gap = gap + 1;
            repeat ((gap % 3) + 1) begin
                @(negedge clk); ce = 0;
                @(posedge clk); #1;
                if ({ro,go,bo,hso,vso,hbo,vbo} !== held) $fatal(1, "output changed without CE");
            end
        end
    endtask

    task blank_frame;
        begin
            pixel(0,0,0,1); pixel(1,0,0,1); pixel(2,0,0,1);
        end
    endtask
    task raster(input integer save, input integer index);
        begin
            if (save) begin
                fd = $fopen($sformatf("build/frame_%0d.ppm",index),"wb");
                if (!fd) $fatal(1,"cannot create capture");
                $fwrite(fd,"P6\n320 240\n255\n");
                capture = 1; pixels = 0;
            end
            for (sy=0; sy<240; sy=sy+1) begin
                for (sx=0; sx<320; sx=sx+1) pixel(sx,sy,1,0);
                for (sx=320; sx<328; sx=sx+1) pixel(sx,sy,0,0);
            end
            if (save) begin
                capture = 0; $fclose(fd);
                if (pixels != 320*240) $fatal(1,"wrong active-pixel count: %0d",pixels);
            end
        end
    endtask
    task menu_pulse;
        begin
            @(negedge clk); trigger = 1;
            repeat (8) @(negedge clk);
            trigger = 0;
            repeat (8) @(negedge clk);
        end
    endtask

    task open_for_button;
        begin
            pixel(0,0,1,0);
            menu_pulse(); blank_frame();
            if (!active) $fatal(1,"button regression failed to open");
            pixel(0,0,1,0);
            repeat (8) @(negedge clk);
        end
    endtask

    task release_buttons;
        begin
            // A press and release entirely between frame boundaries must close.
            repeat (8) @(negedge clk);
            joysticks = 0; ps2_key[9] = 0; mouse_buttons = 0;
            mister_buttons = 0; osd_status = 0;
            repeat (8) @(negedge clk);
            if (!active) $fatal(1,"button press tore the active frame");
            blank_frame();
            if (active) $fatal(1,"short button press was lost before VBlank");
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        reset = 0;
        blank_frame(); raster(0,0);
        menu_pulse();
        if (active) $fatal(1,"menu changed visibility during active frame");
        blank_frame();
        if (!active || dut.phase != dut.START_PHASE) $fatal(1,"menu did not open at centered start phase");
        raster(1,0);
        blank_frame(); raster(0,0);
        if (dut.phase != dut.START_PHASE) $fatal(1,"scroll faster than requested");
        blank_frame();
        if (dut.phase != dut.START_PHASE+1) $fatal(1,"scroll did not advance up one pixel");
        raster(1,1);
        // Direct initial-state injection exercises distant names and wrap without
        // spending thousands of simulated video frames waiting for the slow scroll.
        blank_frame(); dut.phase = 1 << ($bits(dut.phase)-1);
        raster(1,2);
        blank_frame(); dut.phase = (dut.CREDIT_FOOTER_SCROLL_ROW-8)*8;
        raster(1,3);
        blank_frame(); dut.phase = dut.CREDIT_FOOTER_SCROLL_ROW*8;
        raster(1,4);
        blank_frame(); dut.phase = '1; dut.frame_timer = 1;
        raster(0,0); blank_frame();
        if (dut.phase != 0) $fatal(1,"scroll did not wrap");
        raster(0,0); menu_pulse(); blank_frame();
        if (active) $fatal(1,"second menu selection did not close");
        raster(0,0);
        menu_pulse(); menu_pulse(); blank_frame();
        if (active) $fatal(1,"two queued selections should cancel");
        raster(0,0); menu_pulse(); blank_frame();
        if (!active) $fatal(1,"reopen failed");
        raster(0,0);
        @(negedge clk); dismiss = 1;
        repeat (8) @(negedge clk);
        blank_frame();
        if (active) $fatal(1,"dismiss did not close");
        @(negedge clk); dismiss = 0;
        repeat (8) @(negedge clk);

        // The OSD confirm button can still be held when Credits opens.
        pixel(0,0,1,0);
        @(negedge clk); joysticks[4] = 1;
        menu_pulse(); blank_frame();
        if (!active) $fatal(1,"held opening button prevented opening");
        pixel(0,0,1,0); blank_frame();
        if (!active) $fatal(1,"held opening button immediately closed credits");
        @(negedge clk); joysticks = 0;
        repeat (8) @(negedge clk);
        pixel(0,0,1,0); blank_frame();
        if (!active) $fatal(1,"opening button release closed credits");
        pixel(0,0,1,0);
        @(negedge clk); joysticks[4] = 1;
        release_buttons();

        // Every mapped bit on all six controllers, including directions.
        for (button_index=0; button_index<192; button_index=button_index+1) begin
            open_for_button();
            @(negedge clk); joysticks[button_index] = 1;
            release_buttons();
        end
        // All scan codes close on a make; breaks alone must not close.
        for (button_index=0; button_index<256; button_index=button_index+1) begin
            open_for_button();
            @(negedge clk);
            ps2_key = {~ps2_key[10],1'b0,button_index[0],button_index[7:0]};
            repeat (8) @(negedge clk);
            blank_frame();
            if (!active) $fatal(1,"keyboard break closed credits");
            pixel(0,0,1,0);
            @(negedge clk); ps2_key[10] = !ps2_key[10]; ps2_key[9] = 1;
            release_buttons();
        end
        for (button_index=0; button_index<3; button_index=button_index+1) begin
            open_for_button();
            @(negedge clk); mouse_buttons[button_index] = 1;
            release_buttons();
        end
        for (button_index=0; button_index<2; button_index=button_index+1) begin
            open_for_button();
            @(negedge clk); mister_buttons[button_index] = 1;
            release_buttons();
        end
        open_for_button();
        @(negedge clk); osd_status = 1;
        release_buttons();
        // Reset must discard a queued close request and allow a fresh opening.
        open_for_button();
        @(negedge clk); dismiss = 1;
        repeat (8) @(negedge clk);
        dismiss = 0; reset = 1;
        repeat (4) @(negedge clk);
        reset = 0;
        if (active) $fatal(1,"reset did not clear credits");
        samples = 0; // Reset also clears the video pipeline; refill its scoreboard.
        open_for_button(); blank_frame();
        if (!active) $fatal(1,"stale dismiss survived reset");
        $display("PASS: any-button dismissal: 192 controller bits, 256 keyboard codes, 3 mouse buttons, 2 MiSTer buttons, OSD, held opener, short presses, reset");
        $display("PASS: %0d pixel/timing checks; CE holds, menu CDC, both tiers, upward scroll, centered opening, wrap, dismiss",checks);
        $finish;
    end
endmodule
