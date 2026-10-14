// SPDX-License-Identifier: GPL-3.0-or-later
// Osman: two 1 MHz/PIN7-high MSM6295s, one banked 2 MiB music region.
module osman_audio #(
    parameter integer SYSTEM_HZ=48820224
)(
    input wire clk, reset, pause,
    input wire [7:0] profile,
    input wire sfx_wr, music_wr,
    input wire [7:0] command_data,
    input wire [2:0] music_bank,
    input wire [1:0] sfx_level,music_level,
    input wire filter,
    output wire [7:0] sfx_status, music_status,
    output wire sfx_req,
    output wire [17:0] sfx_addr,
    input wire sfx_valid,
    input wire [7:0] sfx_data,
    output wire music_req,
    output wire [20:0] music_addr,
    input wire music_valid,
    input wire [7:0] music_data,
    output wire signed [15:0] audio,
    output wire sample
);
    reg [31:0] phase;
    reg cen;
    reg [31:0] music_phase;
    reg music_cen;
    wire [31:0] music_clock_hz = profile == 8'd2 ? 32'd2000000 : 32'd1000000;
    always @(posedge clk) begin
        if (reset) begin phase<=0; cen<=0; end
        else if (!pause) begin
            if (phase>=SYSTEM_HZ-1000000) begin
                phase<=phase-(SYSTEM_HZ-1000000); cen<=1;
            end else begin phase<=phase+1000000; cen<=0; end
        end
    end
    always @(posedge clk) begin
        if (reset) begin music_phase<=0; music_cen<=0; end
        else if (!pause) begin
            if (music_phase>=SYSTEM_HZ-music_clock_hz) begin
                music_phase<=music_phase-(SYSTEM_HZ-music_clock_hz); music_cen<=1;
            end else begin music_phase<=music_phase+music_clock_hz; music_cen<=0; end
        end
    end
    wire run=reset || !pause;
    wire [17:0] jt_sfx_addr,jt_music_addr;
    wire [7:0] jt_sfx_data,jt_music_data;
    wire jt_sfx_ok,jt_music_ok;
    wire signed [13:0] sfx_sound,music_sound;
    wire sfx_sample,music_sample;
    jt6295 #(.INTERPOL(0),.SAMPLE(0)) u_sfx(
        .rst(reset),.clk(clk),.run(run),.cen(cen),.ss(1'b1),
        .wrn(!(sfx_wr && !pause)),.din(command_data),.dout(sfx_status),
        .rom_addr(jt_sfx_addr),.rom_data(jt_sfx_data),.rom_ok(jt_sfx_ok),
        .sound(sfx_sound),.sample(sfx_sample));
    jt6295 #(.INTERPOL(0),.SAMPLE(0)) u_music(
        .rst(reset),.clk(clk),.run(run),.cen(music_cen),.ss(1'b1),
        .wrn(!(music_wr && !pause)),.din(command_data),.dout(music_status),
        .rom_addr(jt_music_addr),.rom_data(jt_music_data),.rom_ok(jt_music_ok),
        .sound(music_sound),.sample(music_sample));

    osman_audio_rom #(.AW(18)) u_sfx_rom(
        .clk(clk),.reset(reset),.pause(pause),.wanted(jt_sfx_addr),
        .request(sfx_req),.address(sfx_addr),.valid(sfx_valid),.data(sfx_data),
        .chip_ok(jt_sfx_ok),.chip_data(jt_sfx_data));
    osman_audio_rom #(.AW(21)) u_music_rom(
        .clk(clk),.reset(reset),.pause(pause),.wanted({music_bank,jt_music_addr}),
        .request(music_req),.address(music_addr),.valid(music_valid),.data(music_data),
        .chip_ok(jt_music_ok),.chip_data(jt_music_data));

    // MAME 0.6 SFX : 0.2 music; convert the raw chip sum to signed 16-bit PCM.
    wire signed [13:0] sfx_scaled=sfx_level==3 ? 14'sd0 : sfx_sound >>> sfx_level;
    wire signed [13:0] music_scaled=music_level==3 ? 14'sd0 : music_sound >>> music_level;
    // Output reconstruction filter. The chips hold each native sample
    // (7.576 kHz at 1 MHz/PIN7 high), so the unfiltered staircase carries
    // spectral images only 6-19 dB below the music, heard as a tinny/harsh
    // top end. The PCB follows the MSM6295 DAC with an analogue low-pass;
    // two one-pole sections at the 1 MHz enable (about 10 kHz and 5 kHz)
    // keep the passband (-1.8 dB at 2 kHz) and add 9-17 dB of image
    // rejection. Joe & Mac Returns' 2 MHz music (15.15 kHz native) uses an
    // octave-higher pair. Unity DC gain and no overshoot keep the range.
    wire filter_ce=cen && !pause;
    wire signed [13:0] sfx_lpf,music_lpf;
    osman_audio_lpf u_sfx_lpf(.clk(clk),.reset(reset),.ce(filter_ce),
        .k1(3'd4),.k2(3'd5),.din(sfx_scaled),.dout(sfx_lpf));
    osman_audio_lpf u_music_lpf(.clk(clk),.reset(reset),.ce(filter_ce),
        .k1(profile==8'd2 ? 3'd3 : 3'd4),.k2(profile==8'd2 ? 3'd4 : 3'd5),
        .din(music_scaled),.dout(music_lpf));
    wire signed [13:0] sfx_out=filter ? sfx_lpf : sfx_scaled;
    wire signed [13:0] music_out=filter ? music_lpf : music_scaled;
    wire signed [19:0] sx={{6{sfx_out[13]}},sfx_out};
    wire signed [19:0] mu={{6{music_out[13]}},music_out};
    wire signed [19:0] mixed=((sx*20'sd3+mu)*20'sd16)/20'sd5;
    wire signed [15:0] mixed_pcm=mixed>20'sd32767 ? 16'sh7fff :
                                      mixed< -20'sd32768 ? 16'sh8000 : mixed[15:0];
    assign audio=pause ? 16'sd0 : mixed_pcm;
    // SAMPLE=0 exports a cen-scaled 48 kHz observer pulse at 1 MHz. Keep that
    // fixed cadence while the Joe music decoder itself runs at its real 2 MHz.
    assign sample=!pause && sfx_sample;
endmodule

// Two cascaded one-pole low-pass sections, y += (x - y) / 2^k per enable.
// Eight fractional state bits avoid a dead band; the output is rounded so a
// constant input settles to exactly the same value.
module osman_audio_lpf(
    input wire clk,reset,ce,
    input wire [2:0] k1,k2,
    input wire signed [13:0] din,
    output wire signed [13:0] dout
);
    reg signed [23:0] y1,y2;
    wire signed [23:0] x={{2{din[13]}},din,8'd0};
    wire signed [23:0] d1=x-y1;
    wire signed [23:0] d2=y1-y2;
    wire signed [23:0] r2=y2+24'sd128;
    assign dout=r2[21:8];
    always @(posedge clk) begin
        if(reset) begin y1<=0;y2<=0; end
        else if(ce) begin
            y1<=y1+(d1>>>k1);
            y2<=y2+(d2>>>k2);
        end
    end
endmodule

// One outstanding pulse request per independent transport channel. JT6295
// continuously drives an address; cache the returned tuple until it changes.
// In-flight returns are accepted even during pause, then consumed on resume.
module osman_audio_rom #(parameter integer AW=18)(
    input wire clk,reset,pause,
    input wire [AW-1:0] wanted,
    output reg request,
    output reg [AW-1:0] address,
    input wire valid,
    input wire [7:0] data,
    output wire chip_ok,
    output wire [7:0] chip_data
);
    reg pending,have;
    wire returning = valid && pending;
    reg [AW-1:0] cached_address;
    reg [7:0] cached_data;
    assign chip_ok=have && cached_address==wanted;
    assign chip_data=cached_data;
    always @(posedge clk) begin
        request<=0;
        if(reset) begin
            pending<=0;have<=0;address<=0;cached_address<=0;cached_data<=0;
        end else begin
            if(returning) begin
                pending<=0;have<=1;cached_address<=address;cached_data<=data;
            end
            // Retire the old fetch and launch a changed address on the same edge.
            // Compare against the arriving tuple, not the previous cache entry.
            if(!pause && (!pending || returning) &&
               (returning ? address!=wanted : (!have || cached_address!=wanted))) begin
                request<=1;address<=wanted;pending<=1;
            end
        end
    end
endmodule
