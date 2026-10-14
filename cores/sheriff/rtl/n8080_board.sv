// SPDX-License-Identifier: GPL-2.0-or-later
// Sheriff board, based on MAME 0.289 n8080.cpp (BSD-3-Clause).
// Digital behavior attribution: Zsolt Vasvari, Nicola Salmoria, hap and
// the MAME contributors. This file is original RTL; vendor notices remain.
module n8080_board (
    input wire clk, reset, pause, flip_screen,
    input wire [7:0] input0, input1, input2, input3,
    input wire load_wr,
    input wire [15:0] load_addr,
    input wire [7:0] load_data,
    input wire debug_req, debug_freeze, debug_wr,
    input wire [13:0] debug_addr,
    input wire [7:0] debug_dout,
    output wire [7:0] debug_data,
    output reg ce_pixel,
    output reg [8:0] pixel_x,
    output reg [7:0] pixel_y,
    output reg [2:0] rgb,
    output reg hblank, vblank, hsync, vsync,
    output wire [15:0] cpu_address,
    output wire [7:0] cpu_dout, cpu_din, cpu_status,
    output wire cpu_sync, cpu_dbin, cpu_wr_n, cpu_inte,
    output wire cpu_read, cpu_write, cpu_ack,
    output wire irq,
    output wire [7:0] irq_vector,
    output reg [7:0] sound1, sound2,
    output reg [1:0] color_mode,
    output reg [2:0] color_data,
    output reg flip,
    output reg [15:0] shift_data,
    output reg [2:0] shift_count,
    output wire signed [15:0] audio,
    output wire audio_ce, sound_dac,
    output wire [11:0] sound_pc,
    output wire [7:0] sound_p1, sound_p2
);
    reg [7:0] main_rom [0:16383];
    reg [7:0] ram [0:16383];
    reg [7:0] color_prom [0:1023];
    // Zero initialization matches the MAME region/RAM initialization. Warm
    // reset preserves RAM. Download/debug borrow is only valid while paused
    // or reset; the wrapper enforces that before making it user accessible.
    integer i;
    initial begin
        // Quartus 17 defaults to 5000 constant-loop iterations. Four explicit
        // quarters preserve a single BRAM array without raising global limits.
        for (i=0;i<4096;i=i+1) begin
            main_rom[i]=0; main_rom[i+4096]=0;
            main_rom[i+8192]=0; main_rom[i+12288]=0;
            ram[i]=0; ram[i+4096]=0; ram[i+8192]=0; ram[i+12288]=0;
        end
        for (i=0;i<1024;i=i+1) color_prom[i]=0;
    end
    reg [7:0] main_q, cpu_ram_q, bitmap_q, prom_q;
    // Restore the registered CPU RAM read before resuming a borrowed port.
    // The service requester may release pause and its address on the same
    // clock; phase-enabled CPU latches must not consume the service byte.
    reg [1:0] service_tail=0;
    always @(posedge clk) begin
        if(reset)service_tail<=0;
        else if(pause&&debug_req)service_tail<=2'b11;
        else service_tail<={1'b0,service_tail[1]};
    end
    wire execution_pause=pause||(|service_tail);
    assign debug_data = cpu_ram_q;
    reg [8:0] h = 0;
    // MAME's raw raster starts at the beginning of vblank. Using that origin
    // aligns CPU/IRQ checkpoint time without changing cadence or scanout.
    reg [7:0] v = 240;
    reg [3:0] pixel_phase = 0;
    wire pixel_tick = pixel_phase == 9;
    wire [7:0] source_x = h[7:0] ^ {8{flip ^ flip_screen}};
    wire [7:0] source_y = v ^ {8{flip ^ flip_screen}};
    wire [12:0] bitmap_address = {source_y,source_x[7:3]};
    wire [9:0] prom_address = {source_y[7:3],source_x[7:3]};
    wire [4:0] cpu_phase;
    n8080_cpu processor (
        .clk(clk), .reset(reset), .pause(execution_pause), .din(cpu_din),
        .irq(irq), .address(cpu_address), .dout(cpu_dout),
        .status(cpu_status), .inte(cpu_inte), .sync(cpu_sync),
        .dbin(cpu_dbin), .wr_n(cpu_wr_n), .read_start(cpu_read),
        .write_start(cpu_write), .interrupt_ack(cpu_ack), .phase_debug(cpu_phase)
    );
    // Keep the existing logical raster/event origin. This raw counter/VB
    // projection is not a qualified physical reset or visible phase.
    wire irq_raster_sample = (!pause || !debug_freeze) && pixel_phase == 0 && h == 0;
    wire irq_raw_vb = v < 16 || v >= 240;
    n8080_interrupt_path interrupt_path (
        .clk(clk), .diagnostic_clear(reset), .sample_ce(irq_raster_sample),
        .hold_irq(execution_pause), .raw_vertical(v), .vb(irq_raw_vb),
        .inte(cpu_inte), .status_inta(cpu_status[0]),
        .irq(irq), .interrupt_data(irq_vector), .intr(), .intd(), .request_rise()
    );
    reg [7:0] io_data;
    always @* begin
        case (cpu_address[2:0])
            0: io_data=input0;
            1: io_data=input1;
            2: io_data=input2;
            3: io_data=8'(shift_data >> (8 - shift_count));
            4: io_data=input3;
            default: io_data=8'hff;
        endcase
    end
    assign cpu_din = cpu_status[0] ? irq_vector : cpu_status[6] ? io_data :
                     cpu_address[14] ? cpu_ram_q : main_q;
    always @(posedge clk) begin
        main_q <= main_rom[cpu_address[13:0]];
        cpu_ram_q <= ram[pause && debug_req ? debug_addr : cpu_address[13:0]];
        bitmap_q <= ram[{1'b0,bitmap_address}];
        prom_q <= color_prom[prom_address];
        if (load_wr) begin
            if (load_addr < 16'h4000) main_rom[load_addr[13:0]] <= load_data;
            else if (load_addr >= 16'h4400 && load_addr < 16'h4800) color_prom[load_addr[9:0]] <= load_data;
        end
        if (!reset && !execution_pause && cpu_write && !cpu_status[4] && cpu_address[14])
            ram[cpu_address[13:0]] <= cpu_dout;
        else if (!reset && pause && debug_req && debug_wr)
            ram[debug_addr] <= debug_dout;
    end
    wire sn_enable, sn_vco_mode, sn_mixer_b, sn_vco_5v;
    n8080_mcs48 sound_processor (
        .clk(clk),.reset(reset),.pause(execution_pause),.sound1(sound1),.sound2(sound2),
        .load_wr(load_wr && load_addr>=16'h4000 && load_addr<16'h4400),
        .load_addr(load_addr[9:0]),.load_data(load_data),
        .dac_bit(sound_dac),.p1_out(sound_p1),.p2_out(sound_p2),
        .program_address(sound_pc),.program_data(),.irq_n(),.pins(),
        .mono0(),.mono1(),.ce_crystal(),.ce_state(),.ram_address(),.ram_write(),.ram_dout(),
        .sn_enable(sn_enable),.sn_vco_mode(sn_vco_mode),.sn_mixer_b(sn_mixer_b),.sn_vco_5v(sn_vco_5v)
    );
    wire signed [15:0] sn_sample;
    sheriff_sn76477 analog_sound (
        .clk(clk),.reset(reset),.pause(execution_pause),.enabled(sn_enable),
        .vco_mode(sn_vco_mode),.mixer_b(sn_mixer_b),.vco_5v(sn_vco_5v),
        .sample_ce(audio_ce),.sample(sn_sample),.slf_voltage(),.vco_voltage(),
        .noise_voltage(),.ad_voltage(),.slf_bit(),.vco_bit(),.filtered_noise()
    );
    // MAME route gains: SN76477 0.35 (included in its gain ROM), 1-bit DAC 0.15.
    // MAME's 1-bit DAC range is 0..1: low adds zero, high adds 4915.
    // Both source gains are already included; their sum fits signed 16 bits.
    assign audio = sn_sample + (sound_dac ? 16'sd4915 : 16'sd0);
    wire [2:0] selected_color = color_mode == 3 ? 3'b111 :
        (color_mode == 2 || (color_mode == 1 && !prom_q[3])) ?
        color_data ^ 3'b111 : prom_q[2:0];
    always @(posedge clk) begin
        ce_pixel <= 0;
        if (reset) begin
            h<=0; v<=240; pixel_phase<=0;
            pixel_x<=0; pixel_y<=0; rgb<=0;
            hblank<=1; vblank<=1; hsync<=0; vsync<=0;
            shift_data<=0; shift_count<=0;
            color_mode<=0; color_data<=0; flip<=0;
            sound1<=0; sound2<=0;
        end else begin
            // User pause preserves scanout; explicit simulation debug borrow
            // freezes raster too so RAM checkpoints consume no emulated time.
            if (!pause || !debug_freeze) begin
            pixel_phase <= pixel_tick ? 0 : pixel_phase + 1'b1;
            if (pixel_tick) begin
                ce_pixel<=1;
                pixel_x<=h; pixel_y<=v;
                rgb <= h < 256 && bitmap_q[source_x[2:0]] ? selected_color : 3'b000;
                hblank <= h >= 256;
                vblank <= v < 16 || v >= 240;
                // Native sync location remains a board evidence assumption;
                // cadence and active raster are exact to the driver.
                hsync <= h >= 272 && h < 304;
                vsync <= v >= 248 && v < 252;
                if (h == 319) begin h<=0; v<=v+1'b1; end
                else h<=h+1'b1;
            end
            end
            if (!execution_pause) begin
            if (cpu_write && cpu_status[4]) begin
                case (cpu_address[2:0])
                    2: shift_count<=cpu_dout[2:0];
                    3: shift_data<={cpu_dout,shift_data[15:8]};
                    4: sound1<=cpu_dout;
                    5: sound2<=cpu_dout;
                    6: begin
                        color_mode<=cpu_dout[4:3];
                        color_data<=cpu_dout[2:0];
                        flip<=cpu_dout[5];
                    end
                    default: begin end
                endcase
            end
            end
        end
    end
endmodule
