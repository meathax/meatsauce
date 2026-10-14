// SPDX-License-Identifier: GPL-3.0-or-later
// Shared board core. Platform download, SDRAM, raster, renderers and audio
// connect at these interfaces; the simulation instantiates this same RTL.
module osman_core #(
    parameter integer SYS_HZ = 48820224,
    parameter integer CPU_HZ = 28000000
)(
    input wire clk, reset, pause,
    input wire [7:0] profile,
    input wire irq_line, vblank,
    output wire irq_ack,
    input wire [15:0] inputs_0, inputs_1,
    output wire rom_req,
    output wire [16:0] rom_word_addr,
    input wire rom_ready,
    input wire [31:0] rom_rdata,
    input wire eeprom_load_en,
    input wire [5:0] eeprom_load_addr,
    input wire [15:0] eeprom_load_data,
    input wire [5:0] eeprom_state_addr,
    output wire [15:0] eeprom_state_data,
    output wire eeprom_busy,
    input wire [7:0] oki_sfx_status, oki_music_status,
    output wire oki_sfx_wr, oki_music_wr,
    output wire [7:0] oki_data,
    output wire [2:0] music_bank,
    input wire [25:0] state_addr,
    output wire [31:0] state_data,
    input wire score_req, score_we, score_paused,
    input wire [25:0] score_addr,
    input wire [7:0] score_wdata,
    output wire score_valid,
    output wire [7:0] score_rdata,
    input wire video_req,
    input wire [25:0] video_addr,
    output wire video_valid,
    output wire [31:0] video_data,
    input wire [4:0] cpu_state_index,
    output wire [31:0] cpu_state_data,
    output wire cpu_at_boundary,
    output wire commit_valid, commit_we,
    output wire [25:0] commit_addr,
    output wire [3:0] commit_be,
    output wire [31:0] commit_data,
    output wire [31:0] write_count, unmapped_count
);
    reg [31:0] cpu_phase;
    wire [32:0] cpu_phase_next = {1'b0,cpu_phase} + CPU_HZ;
    wire ce_cpu = !pause && !reset && cpu_phase_next >= SYS_HZ;
    always @(posedge clk) begin
        if (reset) cpu_phase <= 0;
        else if (!pause) cpu_phase <= (cpu_phase_next >= SYS_HZ)
            ? 32'(cpu_phase_next - SYS_HZ) : cpu_phase_next[31:0];
    end
    wire [25:0] cpu_addr;
    wire cpu_req, cpu_we, cpu_ready;
    wire [3:0] cpu_be;
    wire [31:0] cpu_wdata, cpu_rdata;
    // Retain vblank HOLD_LINE until acceptance, or the source's explicit clear.
    // Osman has no MMIO IRQ acknowledge register (0x140000 is music OKI).
    reg irq_pending, irq_previous, irq_resume_hold;
    always @(posedge clk) begin
        if (reset) begin
            irq_pending <= 1'b0;
            irq_previous <= 1'b0;
            irq_resume_hold <= 1'b0;
        end else if (pause) begin
            // Freeze game interrupt history with the CPU. A request already
            // pending at pause entry survives raster edges until real resume ACK.
            if (irq_pending) irq_resume_hold <= 1'b1;
        end else begin
            irq_previous <= irq_line;
            if (irq_line && !irq_previous) irq_pending <= 1'b1;
            else if (irq_ack) begin irq_pending <= 1'b0; irq_resume_hold <= 1'b0; end
            else if (!irq_line && !irq_resume_hold) irq_pending <= 1'b0;
        end
    end
    arm_cpu_wrapper u_cpu (
        .clk(clk), .ce_cpu(ce_cpu), .reset(reset),
        .i_irq(irq_pending), .i_firq(1'b0), .irq_ack(irq_ack),
        .bus_addr(cpu_addr), .bus_req(cpu_req), .bus_we(cpu_we), .bus_be(cpu_be),
        .bus_wdata(cpu_wdata), .bus_rdata(cpu_rdata), .bus_ready(cpu_ready),
        .ss_load(1'b0), .ss_idx(cpu_state_index), .ss_wdata(32'd0),
        .ss_rdata(cpu_state_data), .cpu_at_boundary(cpu_at_boundary)
    );
    wire eeprom_cs, eeprom_sk, eeprom_di, eeprom_do;
    osman_eeprom #(
        .WRITE_CYCLE_CLKS(integer'((SYS_HZ * 64'd1750 + 999999)/1000000)),
        .ERASE_CYCLE_CLKS(integer'((SYS_HZ * 64'd1000 + 999999)/1000000)),
        .BULK_CYCLE_CLKS(integer'((SYS_HZ * 64'd8000 + 999999)/1000000))
    ) u_eeprom (
        .clk(clk), .reset(reset), .cs(eeprom_cs), .sk(eeprom_sk), .di(eeprom_di),
        .do_out(eeprom_do), .busy(eeprom_busy),
        .load_en(eeprom_load_en), .load_addr(eeprom_load_addr), .load_data(eeprom_load_data),
        .state_addr(eeprom_state_addr), .state_data(eeprom_state_data)
    );
    osman_bus u_bus (
        .clk(clk), .reset(reset), .profile(profile), .cpu_req(cpu_req), .cpu_we(cpu_we), .cpu_addr(cpu_addr),
        .cpu_be(cpu_be), .cpu_wdata(cpu_wdata), .cpu_ready(cpu_ready), .cpu_rdata(cpu_rdata),
        .rom_req(rom_req), .rom_word_addr(rom_word_addr), .rom_ready(rom_ready), .rom_rdata(rom_rdata),
        .inputs_0(inputs_0), .inputs_1(inputs_1), .vblank(vblank), .eeprom_do(eeprom_do),
        .eeprom_cs(eeprom_cs), .eeprom_sk(eeprom_sk), .eeprom_di(eeprom_di), .music_bank(music_bank),
        .oki_sfx_status(oki_sfx_status), .oki_music_status(oki_music_status),
        .oki_sfx_wr(oki_sfx_wr), .oki_music_wr(oki_music_wr), .oki_data(oki_data),
        .state_addr(state_addr), .state_data(state_data), .commit_valid(commit_valid),
        .score_req(score_req),.score_we(score_we),.score_paused(score_paused),
        .score_addr(score_addr),.score_wdata(score_wdata),.score_valid(score_valid),.score_rdata(score_rdata),
        .video_req(video_req), .video_addr(video_addr), .video_valid(video_valid), .video_data(video_data),
        .commit_we(commit_we), .commit_addr(commit_addr), .commit_be(commit_be),
        .commit_data(commit_data), .write_count(write_count), .unmapped_count(unmapped_count)
    );
endmodule
