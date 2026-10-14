module argus_audio (
    input wire clk_sys, reset, ce_sound_cpu, ce_opn, pause_game,
    input wire [1:0] game_id,
    input wire [7:0] sound_cmd,
    input wire sound_cmd_we,
    output wire rom_req,
    output wire [23:0] rom_addr,
    input wire rom_ready,
    input wire [7:0] rom_rdata,
    output wire signed [15:0] audio_l, audio_r,
    output wire sample_ce,
    output wire trace_io_we, trace_io_re, trace_latch_read, trace_ram_write,
    output wire [7:0] trace_io_addr, trace_io_data,
    output wire [15:0] trace_cpu_addr, trace_chip_debug,
    output wire trace_irq_n,
    output wire [1:0] trace_chip_irq_n
);
    reg [6:0] reset_ticks;
    wire board_reset = reset || reset_ticks != 0;
    // Flush serial operator state on cold AND software reset, independently of pause.
    // JT03 minimum is six input-enable clocks; 127 also clears its 12-slot pipeline.
    always @(posedge clk_sys) begin
        if (reset) reset_ticks <= 127;
        else if (ce_opn && reset_ticks != 0) reset_ticks <= reset_ticks - 1'b1;
    end
    wire [15:0] addr;
    wire [7:0] cpu_out, cpu_in, opn_rdata;
    wire mreq_n,iorq_n,m1_n,rfsh_n,rd_n,wr_n;
    wire cpu_can_advance;
    wire [1:0] opn_select;
    wire opn_addr,opn_we;
    wire [7:0] opn_wdata;
    assign trace_cpu_addr = addr;
    assign trace_io_addr = addr[7:0];
    assign trace_io_data = !rd_n ? cpu_in : cpu_out;
    assign trace_io_we = opn_we;

    argus_sound_z80 u_cpu (
        .clk(clk_sys), .reset_n(!board_reset),
        .ce(ce_sound_cpu && !pause_game && cpu_can_advance),
        .wait_n(1'b1), .int_n(trace_irq_n), .nmi_n(1'b1), .busrq_n(1'b1),
        .m1_n(m1_n), .mreq_n(mreq_n), .iorq_n(iorq_n), .rfsh_n(rfsh_n),
        .rd_n(rd_n), .wr_n(wr_n), .halt_n(), .busak_n(),
        .A(addr), .di(cpu_in), .\do (cpu_out)
    );
    argus_sound_bus u_bus (
        .clk_sys(clk_sys), .reset(board_reset), .pause_game(pause_game), .game_id(game_id),
        .cpu_addr(addr), .cpu_dout(cpu_out), .mreq_n(mreq_n), .iorq_n(iorq_n),
        .m1_n(m1_n), .rfsh_n(rfsh_n), .rd_n(rd_n), .wr_n(wr_n),
        .cpu_din(cpu_in), .cpu_can_advance(cpu_can_advance),
        .sound_cmd(sound_cmd), .sound_cmd_we(sound_cmd_we),
        .rom_req(rom_req), .rom_addr(rom_addr), .rom_ready(rom_ready), .rom_rdata(rom_rdata),
        .opn_select(opn_select), .opn_addr(opn_addr), .opn_we(opn_we),
        .opn_wdata(opn_wdata), .opn_rdata(opn_rdata),
        .trace_latch_read(trace_latch_read), .trace_io_read(trace_io_re),
        .trace_ram_write(trace_ram_write)
    );
    argus_sound_chips u_chips (
        .clk_sys(clk_sys), .reset(board_reset), .ce_opn(ce_opn), .pause_game(pause_game),
        .game_id(game_id), .opn_select(opn_select), .opn_addr(opn_addr), .opn_we(opn_we),
        .opn_wdata(opn_wdata), .opn_rdata(opn_rdata), .irq_n(trace_irq_n),
        .audio_l(audio_l), .audio_r(audio_r), .sample_ce(sample_ce),
        .trace_irq_n(trace_chip_irq_n), .trace_chip_debug(trace_chip_debug)
    );
endmodule
