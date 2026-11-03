// Konami GX857: Z80 + YM3812 + two K007232 chips, 3.579545 MHz enables.
module spy_sound #(parameter PCM_BLOCK_ROM=1)(
    input logic clk, reset, pause,
    input logic [7:0] main_latch,
    input logic main_irq,
    output wire rom_req,
    output wire [14:0] rom_addr,
    input logic [7:0] rom_data,
    input logic rom_ok,
    output wire [1:0] pcm_req,
    output wire [18:0] pcm0_addr, pcm1_addr,
    input logic [7:0] pcm0_data, pcm1_data,
    input logic [31:0] pcm0_block, pcm1_block,
    input logic [1:0] pcm_ok,
    output logic signed [15:0] audio,
    output logic sample_valid,
    output wire debug_wr, debug_rd,
    output wire [15:0] debug_addr,
    output wire [7:0] debug_data, debug_banks,
    output wire debug_irq_n, debug_nmi_n,
    output logic debug_clip,
    output wire debug_cen
);
    logic [25:0] fraction;
    wire [26:0] next_fraction = {1'b0,fraction} + 27'd3579545;
    wire ce = next_fraction >= 27'd48000000 && !pause;
    logic [12:0] reset_count;
    wire sound_reset = reset || reset_count != 0;
    assign debug_cen = ce;
    always_ff @(posedge clk) begin
        if (reset) begin fraction <= 0; reset_count <= 4096; end
        else if (!pause) begin
            fraction <= ce ? next_fraction - 27'd48000000 : next_fraction[25:0];
            if (reset_count != 0) reset_count <= reset_count - 1'b1;
        end
    end
    wire [15:0] cpu_addr;
    wire [7:0] cpu_din, cpu_dout, ym_data,ym_raw_data,ym_status;
    wire ym_raw_irq_n;
    wire mreq_n, iorq_n, m1_n, rd_n, wr_n, wait_n;
    wire ym_cs, ym_wr, pcm_wr, ym_sample;
    wire [1:0] pcm_cs;
    wire signed [15:0] ym_audio;
    wire signed [10:0] pcm0_a, pcm0_b, pcm1_a, pcm1_b;
    T80s u_cpu(.RESET_n(!sound_reset), .CLK(clk), .CEN(ce),
        .WAIT_n(wait_n), .INT_n(debug_irq_n), .NMI_n(debug_nmi_n),
        .BUSRQ_n(1'b1), .OUT0(1'b0), .DI(cpu_din), .M1_n(m1_n),
        .MREQ_n(mreq_n), .IORQ_n(iorq_n), .RD_n(rd_n), .WR_n(wr_n),
        .RFSH_n(), .HALT_n(), .BUSAK_n(), .A(cpu_addr), .DOUT(cpu_dout));
    spy_sound_bus u_bus(.clk(clk), .reset(sound_reset), .irq_reset(reset), .pause(pause),
        .cpu_addr(cpu_addr), .cpu_dout(cpu_dout), .mreq_n(mreq_n),
        .iorq_n(iorq_n), .m1_n(m1_n), .rd_n(rd_n), .wr_n(wr_n),
        .cpu_din(cpu_din), .wait_n(wait_n), .main_latch(main_latch),
        .main_irq(main_irq), .irq_n(debug_irq_n), .rom_req(rom_req),
        .rom_addr(rom_addr), .rom_data(rom_data), .rom_ok(rom_ok),
        .ym_data(ym_data), .ym_cs(ym_cs), .ym_wr(ym_wr),
        .pcm_cs(pcm_cs), .pcm_wr(pcm_wr), .banks(debug_banks),
        .debug_wr(debug_wr), .debug_rd(debug_rd),
        .debug_addr(debug_addr), .debug_data(debug_data));
    jtopl2 u_ym(.rst(sound_reset), .clk(clk), .cen(ce), .din(cpu_dout),
        .addr(cpu_addr[0]), .cs_n(!ym_cs), .wr_n(!ym_wr),
        .dout(ym_raw_data), .irq_n(ym_raw_irq_n), .snd(ym_audio), .sample(ym_sample));
    spy_ym_timers u_timers(.clk(clk),.reset(reset),.pause(pause),.cen(ce),
        .write(ym_wr),.addr(cpu_addr[0]),.data(cpu_dout),.status(ym_status),.irq_n(debug_nmi_n));
    assign ym_data=cpu_addr[0]?ym_raw_data:ym_status;
    spy_pcm #(.BLOCK_ROM(PCM_BLOCK_ROM)) u_pcm0(.clk(clk), .reset(sound_reset), .pause(pause), .cen(ce),
        .cs(pcm_cs[0]), .wr(pcm_wr), .addr(cpu_addr[3:0]), .din(cpu_dout),
        .bank_a(debug_banks[1:0]), .bank_b(debug_banks[3:2]),
        .rom_req(pcm_req[0]), .rom_addr(pcm0_addr), .rom_data(pcm0_data), .rom_block(pcm0_block),
        .rom_ok(pcm_ok[0]), .snda(pcm0_a), .sndb(pcm0_b));
    spy_pcm #(.BLOCK_ROM(PCM_BLOCK_ROM)) u_pcm1(.clk(clk), .reset(sound_reset), .pause(pause), .cen(ce),
        .cs(pcm_cs[1]), .wr(pcm_wr), .addr(cpu_addr[3:0]), .din(cpu_dout),
        .bank_a(debug_banks[5:4]), .bank_b(debug_banks[7:6]),
        .rom_req(pcm_req[1]), .rom_addr(pcm1_addr), .rom_data(pcm1_data), .rom_block(pcm1_block),
        .rom_ok(pcm_ok[1]), .snda(pcm1_a), .sndb(pcm1_b));
    logic ym_sample_d;
    wire sample_edge = ym_sample && !ym_sample_d;
    always_ff @(posedge clk) begin
        if (sound_reset) ym_sample_d <= 0;
        else ym_sample_d <= ym_sample;
    end
    spy_audio_mix u_mix(.clk(clk), .reset(sound_reset), .pause(pause),
        .sample_tick(sample_edge), .ym_audio(ym_audio),
        .pcm0_a(pcm0_a), .pcm0_b(pcm0_b), .pcm1_a(pcm1_a), .pcm1_b(pcm1_b),
        .audio(audio), .sample_valid(sample_valid), .clip(debug_clip));
endmodule
