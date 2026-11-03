// SPDX-License-Identifier: GPL-3.0-or-later
// Audio program and both 128KiB sample images use on-chip RAM. The unpopulated
// upper half of each MAME 256KiB OKI region reads zero, matching ROM assembly.
module madmotor_audio #(
    parameter logic [31:0] SYS_HZ=48000000
)(
    input tri0 bandit,
    input logic clk,reset,
    input logic [7:0] command,
    input logic command_irq,
    input logic load_we,
    input logic [1:0] load_region,
    input logic [17:0] load_addr,
    input logic [7:0] load_data,
    output wire signed [15:0] audio_left,audio_right,
    output wire sample_ce,clipped,
    output wire [15:0] debug_rom_addr,
    output wire debug_rom_cs,
    output wire [7:0] debug_ram_data,
    output wire [12:0] debug_ram_addr,
    output wire debug_ram_we,
    output wire [20:0] debug_chip_address,
    output wire [7:0] debug_chip_data,
    output wire debug_chip_write
);
    logic [7:0] program_rom [0:65535],sample1_rom [0:131071],sample2_rom [0:131071],work_ram [0:8191];
`ifdef VERILATOR
    string program_path,sample1_path,sample2_path;
    initial begin
        if(!$value$plusargs("AUDIO_PROGRAM=%s",program_path)) $fatal(1,"AUDIO_PROGRAM missing");
        if(!$value$plusargs("AUDIO_SAMPLE1=%s",sample1_path)) $fatal(1,"AUDIO_SAMPLE1 missing");
        if(!$value$plusargs("AUDIO_SAMPLE2=%s",sample2_path)) $fatal(1,"AUDIO_SAMPLE2 missing");
        $readmemh(program_path,program_rom);$readmemh(sample1_path,sample1_rom);$readmemh(sample2_path,sample2_rom);
    end
`endif
    wire cen_huc,cen_ym,cen_oki1,cen_oki2,sample_tick;
    wire cen_bsnd,cen_bopn,cen_bopl,cen_boki;
    madmotor_frac_ce #(.NUM(6000000),.DEN(SYS_HZ)) bsnd_clock(clk,reset,cen_bsnd);
    madmotor_frac_ce #(.NUM(1500000),.DEN(SYS_HZ)) bopn_clock(clk,reset,cen_bopn);
    madmotor_frac_ce #(.NUM(3000000),.DEN(SYS_HZ)) bopl_clock(clk,reset,cen_bopl);
    madmotor_frac_ce #(.NUM(1000000),.DEN(SYS_HZ)) boki_clock(clk,reset,cen_boki);
    // Start oscillators after the outer reset, then hold chip reset long
    // enough for their enable-driven register pipelines to be cleared.
    // Preserve at least the original4095/48MHz warm-up time at another root.
    localparam integer RESET_ROOTS=(64'(SYS_HZ)*4095+47999999)/48000000;
    localparam integer RESET_WIDTH=$clog2(RESET_ROOTS+1);
    logic [RESET_WIDTH-1:0] reset_hold;
    wire chip_reset=reset||(reset_hold!=RESET_WIDTH'(RESET_ROOTS));
    always_ff @(posedge clk) begin
        if(reset)reset_hold<=0;
        else if(reset_hold!=RESET_WIDTH'(RESET_ROOTS))reset_hold<=reset_hold+1'b1;
    end
    madmotor_frac_ce #(.NUM(24159000),.DEN(SYS_HZ)) huc_clock(clk,reset,cen_huc);
    madmotor_frac_ce #(.NUM(21477272),.DEN(SYS_HZ*6)) ym_clock(clk,reset,cen_ym);
    madmotor_frac_ce #(.NUM(1023924),.DEN(SYS_HZ)) oki1_clock(clk,reset,cen_oki1);
    madmotor_frac_ce #(.NUM(2047848),.DEN(SYS_HZ)) oki2_clock(clk,reset,cen_oki2);
    madmotor_frac_ce #(.NUM(48000),.DEN(SYS_HZ)) sample_clock(clk,reset,sample_tick);
    wire [15:0] program_addr;
    wire program_cs;
    logic [15:0] program_addr_q;
    logic [7:0] program_data,ram_data,oki1_data,oki2_data;
    wire [12:0] ram_addr;
    wire [7:0] ram_write_data;
    wire ram_we;
    wire [17:0] oki1_addr;
    wire [18:0] oki2_addr;
    logic [17:0] oki1_addr_q;
    logic [18:0] oki2_addr_q;
    wire signed [15:0] opn,raw_opm_left,raw_opm_right;
    wire [9:0] psg;
    wire signed [13:0] raw_pcm1,raw_pcm2;
    wire [3:0] native_sample;
    wire signed [15:0] native_data [4];
    wire signed [20:0] resampled [4];
    wire signed [20:0] opm_left=resampled[0],opm_right=resampled[1],pcm1=resampled[2],pcm2=resampled[3];
    wire mix_tick;
    logic signed [15:0] mix_opn;
    logic [9:0] mix_psg;
    assign native_data[0]=raw_opm_left;assign native_data[1]=raw_opm_right;
    assign native_data[2]={{2{raw_pcm1[13]}},raw_pcm1};
    assign native_data[3]={{2{raw_pcm2[13]}},raw_pcm2};
    always_ff @(posedge clk)begin
        if(chip_reset)begin mix_opn<=0;mix_psg<=0;end
        else if(sample_tick)begin mix_opn<=opn;mix_psg<=psg;end
    end
    madmotor_audio_resampler #(.SYS_HZ(SYS_HZ)) resampler(
        .bandit(bandit),.clk(clk),.reset(reset),.source_reset(chip_reset),.output_ce(sample_tick),
        .source_ce(native_sample),.source_data(native_data),.sample_data(resampled),.sample_valid(mix_tick));
    always_ff @(posedge clk) begin
        program_addr_q<=program_addr;
        program_data<=program_rom[program_addr];
        oki1_addr_q<=oki1_addr;oki2_addr_q<=oki2_addr;
        oki1_data<=oki1_addr[17]?8'd0:sample1_rom[oki1_addr[16:0]];
        oki2_data<=|oki2_addr[18:17]?8'd0:sample2_rom[oki2_addr[16:0]];
        ram_data<=work_ram[ram_addr];
        if(ram_we)work_ram[ram_addr]<=ram_write_data;
        if(load_we)case(load_region)
            0:program_rom[load_addr[15:0]]<=load_data;
            1:sample1_rom[load_addr[16:0]]<=load_data;
            2:sample2_rom[load_addr[16:0]]<=load_data;
            default:;
        endcase
    end
    madmotor_sound engine(
        .bandit(bandit),
        .native_sample(native_sample),
        .debug_address(debug_chip_address),.debug_data(debug_chip_data),.debug_chip_write(debug_chip_write),
        .rst(chip_reset),.clk(clk),.cen_snd(bandit?cen_bsnd:cen_huc),.cen_opn(bandit?cen_bopn:cen_ym),.cen_opm(bandit?cen_bopl:cen_ym),
        .cen_oki1(bandit?cen_boki:cen_oki1),.cen_oki2(cen_oki2 && !bandit),.dseal(1'b1),
        .latch(command),.snd_irq(command_irq),
        .sndram_addr(ram_addr),.sndram_din(ram_write_data),.sndram_we(ram_we),.sndram_dout(ram_data),
        .rom_addr(program_addr),.rom_cs(program_cs),.rom_data(program_data),.rom_ok(program_addr_q==program_addr),
        .oki1_addr(oki1_addr),.oki1_cs(),.oki1_data(oki1_data),.oki1_ok(oki1_addr_q==oki1_addr),
        .oki2_addr(oki2_addr),.oki2_cs(),.oki2_data(oki2_data),.oki2_ok(oki2_addr_q==oki2_addr),
        .opn(opn),.psg(psg),.opm_l(raw_opm_left),.opm_r(raw_opm_right),.pcm1(raw_pcm1),.pcm2(raw_pcm2)
    );
    madmotor_audio_mix mixer(
        .bandit(bandit),.clk(clk),.reset(reset),.sample_ce(mix_tick),.opn(mix_opn),.psg(mix_psg),
        .opm_left(opm_left),.opm_right(opm_right),.pcm1(pcm1),.pcm2(pcm2),
        .left(audio_left),.right(audio_right),.clipped(clipped),.sample_valid(sample_ce)
    );
    assign debug_rom_addr=program_addr;assign debug_rom_cs=program_cs;
    assign debug_ram_addr=ram_addr;assign debug_ram_data=ram_write_data;assign debug_ram_we=ram_we;
endmodule
