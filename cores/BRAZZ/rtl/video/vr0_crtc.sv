// SPDX-License-Identifier: BSD-3-Clause
// VRender0 programmable raster. Register/timing interpretation follows pinned
// MAME 0.289; physical interlace half-lines and porch polarity need HW evidence.
module vr0_crtc (
    input logic clk, reset,
    input logic reg_valid, reg_write,
    input logic [9:0] reg_address,
    input logic [31:0] reg_data,
    input logic [3:0] reg_strobe,
    output logic reg_ready, reg_response,
    output logic [31:0] reg_result,
    input logic external_pixel_tick,
    output logic pixel_tick, display_enable, screen_blank,
    output logic hsync, vsync, hblank, vblank,
    output logic vblank_start, flip_tick, irq_vblank, frame_start,
    output logic [11:0] pixel_x, pixel_y,
    output logic [31:0] frame_number,
    output logic [11:0] horizontal_total, vertical_total,
    output logic [11:0] horizontal_visible, vertical_visible,
    output logic [5:0] pixel_period,
    output logic interlaced,
    output logic unsupported_timing,
    output logic timing_changed
);
    logic [31:0] regs [0:31], next_regs [0:31];
    logic [31:0] write_mask, allowed_mask, read_value;
    logic register_changed, configure, configuration_pending;
    logic [5:0] divider;
    logic [11:0] next_h, next_v, next_hd, next_vd;
    logic [5:0] next_period;
    logic next_interlace, next_internal, internal_clock;
    logic [12:0] hsync_begin, hsync_end;
    logic [11:0] vsync_begin, vsync_end;
    integer index;
    logic [10:0] hdisp, htot;
    logic [9:0] vdisp;
    logic [11:0] vtot;
    logic [7:0] hbp, hsw, hsfp, vbp;

    assign timing_changed=configure;
    always_comb begin
        reg_ready = !configuration_pending;
        write_mask = {{8{reg_strobe[3]}},{8{reg_strobe[2]}},
                      {8{reg_strobe[1]}},{8{reg_strobe[0]}}};
        allowed_mask = 0;
        case (reg_address)
            10'h000,10'h00c,10'h028: allowed_mask=32'h000003ff;
            10'h004: allowed_mask=32'h00003fff;
            10'h008: allowed_mask=32'h0000ffff;
            10'h010,10'h01c: allowed_mask=32'h000001ff;
            10'h014: allowed_mask=32'h00007f3f;
            10'h018: allowed_mask=32'h000000ff;
            10'h020: if (reg_data[10]) allowed_mask=32'h00001fff;
            10'h024: if (reg_data[11]) allowed_mask=32'h00000fff;
            10'h02c,10'h030: allowed_mask=32'h00007fff;
            // Light pen X/Y (0x038..0x044) are read-only and return 0 without a light gun (MAME master).
            10'h048: allowed_mask=32'h00000003;
            default: allowed_mask=0;
        endcase
        if (regs[0][8] && reg_address>0 && reg_address<10'h028)
            allowed_mask=0;
        for (integer i=0;i<32;i=i+1) next_regs[i]=regs[i];
        index=int'(reg_address[6:2]);
        register_changed=0;
        // Compare masked write bits at each fixed register before selection.
        // A dynamic next_regs/readback mux followed by equality lengthens the
        // CPU address -> configuration_pending path unnecessarily.
        for (integer i=0;i<32;i=i+1) begin
            if (reg_valid && reg_ready && reg_write && reg_address<10'h080 &&
                reg_address[6:2]==5'(i)) begin
                next_regs[i]=(regs[i]&~(write_mask&allowed_mask))|
                             (reg_data&write_mask&allowed_mask);
                register_changed=|( (regs[i]^reg_data)&write_mask&allowed_mask );
            end
        end

        // Reconfigure from registered timing words, after the accepted write.
        // This breaks address/mask/write-mux -> auto-total -> raster control.
        // Backpressure the next request until automatic readback is committed.
        hdisp={1'b0,regs[3][9:0]}+11'd1;
        vdisp={1'b0,regs[7][8:0]};
        next_interlace=!regs[12][0];
        if (next_interlace) vdisp=vdisp<<1;
        htot={1'b0,regs[8][9:0]}+11'd1;
        vtot={1'b0,regs[9][10:0]};
        hbp=regs[2][15:8];
        hsw=regs[2][7:0];
        hsfp=regs[4][7:0];
        vbp=regs[2][7:0]; // Pinned MAME rule, not VSBP.
        configure=configuration_pending && vdisp!=0;
        if (configure && (htot<=1 || htot<=hdisp)) begin
            if (hbp==0 && hsw==0 && hsfp==0) configure=0;
            else begin
                htot=hdisp+{3'b0,hbp}+{3'b0,hsw}+{3'b0,hsfp}+11'd3;
                next_regs[8]={22'b0,htot[9:0]}-32'd1;
            end
        end
        if (configure && vtot==0) begin
            if (vbp==0) configure=0;
            else begin
                vtot={2'b0,vdisp}+{4'b0,vbp}+12'd1;
                next_regs[9]={21'b0,vtot[10:0]}-32'd1;
            end
        end
        if (!next_interlace) vtot=(vtot>>1)+12'd1;
        vtot=vtot+12'd9;
        next_h={1'b0,htot}; next_v=vtot;
        next_hd={1'b0,hdisp}; next_vd={2'b0,vdisp};
        // SYSCLK=85.90908MHz; internal VCLK=14.31818MHz, optionally doubled.
        next_period=(regs[1][7]?6'd3:6'd6)*({3'b0,regs[1][2:0]}+6'd1);
        next_internal=regs[1][3];

        read_value=0;
        if (reg_address<10'h080) read_value=regs[index];
        if (reg_address>=10'h038 && reg_address<10'h048) read_value=0;
        if (reg_address==0) begin
            // MAME master crtc_r status: bit14 vertical display enable, bit13 inside the
            // display area, bit15 horizontal status; boundaries are inclusive.
            read_value=read_value&32'h000003ff;
            if ({20'b0,pixel_y} <= ((regs[7]+1)<<(interlaced?1:0))) begin
                read_value=read_value|32'h4000;
                if ({20'b0,pixel_x}<=regs[3]+1) read_value=read_value|32'h2000;
            end
            if ({20'b0,pixel_x}<=regs[3]+1) read_value=read_value|32'h8000;
        end
        pixel_tick=internal_clock ? (divider==pixel_period-1) : external_pixel_tick;
        hblank=pixel_x>=horizontal_visible;
        vblank=pixel_y>=vertical_visible;
        screen_blank=regs[0][9];
        display_enable=!hblank && !vblank && !screen_blank;
        // Standard 15 kHz composite-sync geometry for CRTs/direct video: front porch >= 11 px
        // (1.5 us), sync 34 px (4.7 us at 7.16 MHz), as the game's 60-pixel register width is
        // wider than NTSC and can drop out of a monitor's sync-separator window.
        hsync_begin={1'b0,horizontal_visible}+(({5'b0,regs[4][7:0]}+13'd1)<13'd11 ? 13'd11 : {5'b0,regs[4][7:0]}+13'd1);
        hsync_end=hsync_begin+(({5'b0,regs[2][7:0]}+13'd1)<13'd34 ? {5'b0,regs[2][7:0]}+13'd1 : 13'd34);
        hsync=!({1'b0,pixel_x}>=hsync_begin && {1'b0,pixel_x}<hsync_end);
        // FWINB low six bits are the field-window sync width. This waveform is
        // provisional; MAME does not model sync pin timing or its polarity.
        vsync_begin=vertical_total-{4'b0,regs[6][7:0]}-12'd1-
                    {6'b0,regs[5][5:0]}-12'd1;
        // The game's field values place the window at line 237 of a 240-line
        // picture; a sync pulse must never start inside active video.
        // NTSC-style vertical sync: 4-line front porch, 3-line pulse (the game's field
        // window would give a 10-line pulse that some CRTs treat as a different standard).
        if (vsync_begin<vertical_visible+12'd4 && vertical_visible+12'd8<vertical_total) vsync_begin=vertical_visible+12'd4;
        vsync_end=vsync_begin+(({6'b0,regs[5][5:0]}+12'd1)<12'd3 ? {6'b0,regs[5][5:0]}+12'd1 : 12'd3);
        vsync=!(pixel_y>=vsync_begin && pixel_y<vsync_end);
        unsupported_timing=(horizontal_visible>=horizontal_total ||
            vertical_visible>=vertical_total || pixel_period==0);
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            for (integer i=0;i<32;i=i+1) regs[i]<=0;
            regs[1]<=32'h2a;
            reg_response<=0; reg_result<=0; configuration_pending<=0;
            horizontal_total<=455; vertical_total<=262;
            horizontal_visible<=320; vertical_visible<=240;
            pixel_period<=12; internal_clock<=1; interlaced<=1;
            divider<=0; pixel_x<=0; pixel_y<=0; frame_number<=0;
            vblank_start<=0; flip_tick<=0; irq_vblank<=0; frame_start<=0;
        end else begin
            configuration_pending<=register_changed;
            reg_response<=reg_valid && reg_ready;
            if (reg_valid && reg_ready) reg_result<=reg_write?0:read_value;
            for (integer i=0;i<32;i=i+1) regs[i]<=next_regs[i];
            vblank_start<=0; flip_tick<=0; irq_vblank<=0; frame_start<=0;
            if (configure) begin
                horizontal_total<=next_h; vertical_total<=next_v;
                horizontal_visible<=next_hd; vertical_visible<=next_vd;
                pixel_period<=next_period; internal_clock<=next_internal;
                interlaced<=next_interlace;
                divider<=0; pixel_x<=0; pixel_y<=0;
            end else begin
                if (pixel_tick) divider<=0;
                else if (internal_clock) divider<=divider+6'd1;
                if (pixel_tick) begin
                    if (pixel_x==horizontal_total-1) begin
                        pixel_x<=0;
                        if (pixel_y==vertical_total-1) begin
                            pixel_y<=0; frame_number<=frame_number+1;
                            frame_start<=1;
                        end else begin
                            pixel_y<=pixel_y+1;
                            if (pixel_y==vertical_visible-1) begin
                                vblank_start<=1;
                                if (!interlaced || (frame_number[0]^regs[0][3])) begin
                                    irq_vblank<=1; flip_tick<=1;
                                end
                            end
                        end
                    end else pixel_x<=pixel_x+1;
                end
            end
        end
    end
endmodule
