// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Daikaiju no Gyakushu MiSTer core contributors

`default_nettype none

module daikaiju_sound_board #(
    parameter ROM_FILE = ""
) (
    input  logic               clk_sys,
    input  logic               reset_n,
    input  logic               ce_3mhz,
    input  logic               rom_download_write,
    input  logic [14:0]        rom_download_address,
    input  logic [15:0]        rom_download_data,
    input  logic [7:0]         command_data,
    input  logic               command_pending,
    output logic               command_ack,
    output logic signed [15:0] audio_sample,
    output logic               audio_sample_valid,
    output logic [15:0]        sound_pc,
    output logic [15:0]        sound_bus_addr,
    output logic [7:0]         sound_bus_dout,
    output logic [7:0]         sound_bus_din,
    output logic               sound_m1_n,
    output logic               sound_mreq_n,
    output logic               sound_iorq_n,
    output logic               sound_rd_n,
    output logic               sound_wr_n,
    output logic               sound_irq_n,
    output logic               sound_nmi_n,
    output logic               sound_nmi_enabled
);

    // The test bench supplies an image in the full Z80 address space. The
    // diagnostic window E000-EFFF is retained after the 0000-7FFF ROM.
    // Other address ranges are RAM/I/O/unmapped, so need no physical ROM bits.
    logic [15:0] sound_rom_words [0:18431];
    logic [7:0] sound_ram [0:2047];
    integer rom_index;
`ifdef SIMULATION
    reg [15:0] file_rom_words[0:32767];
`endif

    // JT03 delay-line state needs a full startup hold; CE remains external
    // and free-running while reset is stretched (shared lesson 18074).
    localparam [14:0] SOUND_RESET_HOLD_CYCLES = 15'd18732;
    logic [14:0] sound_reset_count = 15'd0;
    logic reset_n_q = 1'b0;
    wire sound_reset_n = reset_n && sound_reset_count == SOUND_RESET_HOLD_CYCLES;

    // Count from assertion, including clocks spent loading ROMs in reset.
    // The output above asserts immediately; release is qualified on clk_sys.
    always_ff @(posedge clk_sys) begin
        reset_n_q <= reset_n;
        if (reset_n_q && !reset_n)
            sound_reset_count <= 15'd0;
        else if (sound_reset_count < SOUND_RESET_HOLD_CYCLES)
            sound_reset_count <= sound_reset_count + 15'd1;
    end

    initial begin
`ifdef SIMULATION
        // Give simulation unmapped/diagnostic region reads their expected
        // erased value without asking Quartus to unroll this full ROM depth.
        for (rom_index = 0; rom_index < 18432; rom_index = rom_index + 1)
            sound_rom_words[rom_index] = 16'hFFFF;
`endif
`ifdef SIMULATION
        if (ROM_FILE != "") begin
            for(rom_index=0;rom_index<32768;rom_index=rom_index+1)
                file_rom_words[rom_index]=16'hffff;
            $readmemh(ROM_FILE, file_rom_words);
            for(rom_index=0;rom_index<16384;rom_index=rom_index+1)
                sound_rom_words[rom_index]=file_rom_words[rom_index];
            for(rom_index=0;rom_index<2048;rom_index=rom_index+1)
                sound_rom_words[16384+rom_index]=file_rom_words[28672+rom_index];
        end
`endif
    end

    // The parent converts WIDE ioctl byte offsets to this 16-bit word index.
    wire sound_download_selected=rom_download_address<15'h4000 ||
        (rom_download_address>=15'h7000 && rom_download_address<15'h7800);
    wire [14:0] sound_write_index=rom_download_address<15'h4000 ?
        rom_download_address : 15'h4000+{4'd0,rom_download_address[10:0]};
    always_ff @(posedge clk_sys)
        if(rom_download_write && sound_download_selected)
            sound_rom_words[sound_write_index] <= rom_download_data;

    logic [7:0] cpu_data_in;
    wire [15:0] cpu_addr;
    wire [14:0] sound_rom_index = cpu_addr[15] ? 15'h4000+{4'd0,cpu_addr[11:1]} : {1'b0,cpu_addr[14:1]};
    reg [15:0] sound_rom_word_q;
    reg sound_rom_odd_q;
    // The CPU consumes at CE16; unconditional root-clock reads settle before
    // its next bus phase. The harness checks the sampled byte at every CE.
    always_ff @(posedge clk_sys)begin
        sound_rom_word_q <= sound_rom_words[sound_rom_index];
        sound_rom_odd_q <= cpu_addr[0];
    end
    wire [7:0] sound_rom_byte = sound_rom_odd_q ? sound_rom_word_q[15:8] : sound_rom_word_q[7:0];
    wire [7:0] cpu_data_out;
    wire cpu_m1_n;
    wire cpu_mreq_n;
    wire cpu_iorq_n;
    wire cpu_rd_n;
    wire cpu_wr_n;
    wire cpu_refresh_n;
    wire cpu_halt_n;
    wire cpu_busak_n;
    wire ym2203_irq_n;
    wire cpu_nmi_n = ~(command_pending && sound_nmi_enabled);

    daikaiju_z80_bus sound_cpu (
        .clk_sys  ( clk_sys       ),
        .reset_n  ( sound_reset_n ),
        .ce       ( ce_3mhz       ),
        .wait_n   ( 1'b1          ),
        .int_n    ( ym2203_irq_n  ),
        .nmi_n    ( cpu_nmi_n     ),
        .data_in  ( cpu_data_in   ),
        .address  ( cpu_addr      ),
        .data_out ( cpu_data_out  ),
        .m1_n     ( cpu_m1_n      ),
        .mreq_n   ( cpu_mreq_n    ),
        .iorq_n   ( cpu_iorq_n    ),
        .rd_n     ( cpu_rd_n      ),
        .wr_n     ( cpu_wr_n      ),
        .refresh_n( cpu_refresh_n),
        .halt_n   ( cpu_halt_n    ),
        .busak_n  ( cpu_busak_n   )
    );

    wire mem_read  = !cpu_mreq_n && !cpu_rd_n;
    wire mem_write = !cpu_mreq_n && !cpu_wr_n;
    wire ym2203_sel = cpu_addr >= 16'hA000 && cpu_addr <= 16'hA001;
    wire ym2203_read = mem_read && ym2203_sel;
    wire ym2203_write = mem_write && ym2203_sel;
    wire ym2149_addr_write = mem_write && cpu_addr == 16'hC000;
    wire ym2149_data_write = mem_write && cpu_addr == 16'hC001;
    wire command_read = mem_read && cpu_addr == 16'hD000;
    wire status_read = mem_read && cpu_addr == 16'hD800;

    logic [3:0] ym2149_addr;
    always_ff @(posedge clk_sys) begin
        if (!sound_reset_n)
            ym2149_addr <= 4'd0;
        else if (ce_3mhz && ym2149_addr_write)
            ym2149_addr <= cpu_data_out[3:0];
    end

    wire [7:0] ym2203_data_in;
    always @* begin
        cpu_data_in = 8'hFF;
        if (mem_read) begin
            if (cpu_addr <= 16'h7FFF)
                cpu_data_in = sound_rom_byte;
            else if (cpu_addr >= 16'h8000 && cpu_addr <= 16'h87FF)
                cpu_data_in = sound_ram[cpu_addr[10:0]];
            else if (ym2203_sel)
                cpu_data_in = ym2203_data_in;
            else if (cpu_addr == 16'hD000)
                cpu_data_in = command_data;
            else if (status_read)
                cpu_data_in = command_pending ? 8'h02 : 8'h01;
            else if (cpu_addr >= 16'hE000 && cpu_addr <= 16'hEFFF)
                cpu_data_in = sound_rom_byte;
        end
    end

    always_ff @(posedge clk_sys) begin
        if (sound_reset_n && ce_3mhz && mem_write && cpu_addr >= 16'h8000 && cpu_addr <= 16'h87FF)
            sound_ram[cpu_addr[10:0]] <= cpu_data_out;
    end

    wire [7:0] ym2203_ioa_out;
    wire [7:0] ym2203_iob_out;
    wire ym2203_ioa_oe;
    wire ym2203_iob_oe;
    wire [7:0] ym2203_psg_a;
    wire [7:0] ym2203_psg_b;
    wire [7:0] ym2203_psg_c;
    wire [9:0] ym2203_psg_raw;
    wire signed [15:0] ym2203_fm_raw;
    wire signed [15:0] ym2203_combined_unused;
    wire ym2203_sample;
    wire [7:0] ym2203_debug_unused;

    jt03 #(.MAME_TIMER_A(1)) ym2203 (
        .rst       ( !sound_reset_n                   ),
        .clk       ( clk_sys                          ),
        .cen       ( ce_3mhz                          ),
        .din       ( cpu_data_out                     ),
        .addr      ( cpu_addr[0]                      ),
        .cs_n      ( !(ym2203_read || ym2203_write)   ),
        .wr_n      ( !ym2203_write                    ),
        .dout      ( ym2203_data_in                   ),
        .irq_n     ( ym2203_irq_n                     ),
        .IOA_in    ( 8'hFF                            ),
        .IOB_in    ( 8'hFF                            ),
        .IOA_out   ( ym2203_ioa_out                   ),
        .IOB_out   ( ym2203_iob_out                   ),
        .IOA_oe    ( ym2203_ioa_oe                    ),
        .IOB_oe    ( ym2203_iob_oe                    ),
        .psg_A     ( ym2203_psg_a                     ),
        .psg_B     ( ym2203_psg_b                     ),
        .psg_C     ( ym2203_psg_c                     ),
        .fm_snd    ( ym2203_fm_raw                    ),
        .psg_snd   ( ym2203_psg_raw                   ),
        .snd       ( ym2203_combined_unused           ),
        .snd_sample( ym2203_sample                    ),
        .debug_view( ym2203_debug_unused              )
    );

    wire [9:0] ym2149_psg_raw;
    wire [7:0] ym2149_psg_a;
    wire [7:0] ym2149_psg_b;
    wire [7:0] ym2149_psg_c;
    wire [7:0] ym2149_data_unused;
    wire ym2149_sample;
    wire [7:0] ym2149_ioa_out_unused;
    wire [7:0] ym2149_iob_out_unused;
    wire ym2149_ioa_oe_unused;
    wire ym2149_iob_oe_unused;

    jt49 ym2149 (
        .rst_n  ( sound_reset_n       ),
        .clk    ( clk_sys             ),
        .clk_en ( ce_3mhz             ),
        .addr   ( ym2149_addr         ),
        .cs_n   ( !ym2149_data_write ),
        .wr_n   ( !ym2149_data_write ),
        .din    ( cpu_data_out        ),
        .sel    ( 1'b1                ),
        .dout   ( ym2149_data_unused  ),
        .sound  ( ym2149_psg_raw      ),
        .A      ( ym2149_psg_a        ),
        .B      ( ym2149_psg_b        ),
        .C      ( ym2149_psg_c        ),
        .sample ( ym2149_sample      ),
        .IOA_in ( 8'hFF               ),
        .IOA_out( ym2149_ioa_out_unused),
        .IOA_oe ( ym2149_ioa_oe_unused),
        .IOB_in ( 8'hFF               ),
        .IOB_out( ym2149_iob_out_unused),
        .IOB_oe ( ym2149_iob_oe_unused)
    );

    // Three 8-bit channel levels sum to 765. Preserve either polarity of
    // that full step after DC subtraction; signed ten bits would wrap.
    wire signed [10:0] ym2203_psg_ac;
    wire signed [10:0] ym2149_psg_ac;

    jt49_dcrm2 #(.sw(11)) ym2203_psg_dc_remove (
        .clk ( clk_sys          ),
        .cen ( ce_3mhz          ),
        .rst ( !sound_reset_n   ),
        .din ( {1'b0,ym2203_psg_raw} ),
        .dout( ym2203_psg_ac    )
    );

    jt49_dcrm2 #(.sw(11)) ym2149_psg_dc_remove (
        .clk ( clk_sys          ),
        .cen ( ce_3mhz          ),
        .rst ( !sound_reset_n   ),
        .din ( {1'b0,ym2149_psg_raw} ),
        .dout( ym2149_psg_ac    )
    );

    // MAME's Daikaiju routes the three PSG channels at 0.12 and YM2203 FM
    // at 0.63. DC removal turns JT49's unsigned levels into signed samples.
    // MAME spans are 16382 signed16 units per YMFM SSG channel and 16384
    // per legacy YM2149 channel; JT49 uses 0..255. Apply 0.12*span/255.
    // These software route gains do not establish the PCB analog gain.
    wire signed [31:0] fm_scaled,ym2203_psg_scaled,ym2149_psg_scaled;
    a74_audio_gain gains(.fm_raw(ym2203_fm_raw),.ym_psg(ym2203_psg_ac),.ay_psg(ym2149_psg_ac),
        .fm_scaled(fm_scaled),.ym_scaled(ym2203_psg_scaled),.ay_scaled(ym2149_psg_scaled));
    wire signed [31:0] audio_mix_wide = fm_scaled + ym2203_psg_scaled + ym2149_psg_scaled;

    function automatic logic signed [15:0] saturate_audio(input logic signed [31:0] value);
        begin
            if (value > 32'sd32767)
                saturate_audio = 16'sh7FFF;
            else if (value < -32'sd32768)
                saturate_audio = -16'sd32768;
            else
                saturate_audio = value[15:0];
        end
    endfunction

    logic command_read_seen;
    logic ym2203_sample_d;
    logic ym2149_sample_d;
    always_ff @(posedge clk_sys) begin
        if (!sound_reset_n) begin
            // Daikaiju's MAME INPUT_MERGER_ALL_HIGH leaves control input 1
            // high at startup; D400 disables and D800 re-enables sound NMI.
            sound_nmi_enabled <= 1'b1;
            command_read_seen <= 1'b0;
            command_ack <= 1'b0;
            sound_pc <= 16'd0;
            audio_sample <= 16'sd0;
            audio_sample_valid <= 1'b0;
            ym2203_sample_d <= 1'b0;
            ym2149_sample_d <= 1'b0;
        end else begin
            command_ack <= 1'b0;
            audio_sample_valid <= 1'b0;
            ym2203_sample_d <= ym2203_sample;
            ym2149_sample_d <= ym2149_sample;

            if (!command_read)
                command_read_seen <= 1'b0;
            else if (ce_3mhz && !command_read_seen) begin
                command_ack <= 1'b1;
                command_read_seen <= 1'b1;
            end

            if (ce_3mhz && mem_write && cpu_addr == 16'hD400)
                sound_nmi_enabled <= 1'b0;
            else if (ce_3mhz && mem_write && cpu_addr == 16'hD800)
                sound_nmi_enabled <= 1'b1;

            if (ce_3mhz && !cpu_mreq_n && !cpu_m1_n && !cpu_rd_n)
                sound_pc <= cpu_addr;

            // Both vendor sample flags are chip-domain markers. Capture their
            // rising edges once so a held marker cannot oversample the mix.
            if ((ym2203_sample && !ym2203_sample_d) || (ym2149_sample && !ym2149_sample_d)) begin
                audio_sample <= saturate_audio(audio_mix_wide);
                audio_sample_valid <= 1'b1;
            end
        end
    end

    always_comb begin
        sound_bus_addr = cpu_addr;
        sound_bus_dout = cpu_data_out;
        sound_bus_din = cpu_data_in;
        sound_m1_n = cpu_m1_n;
        sound_mreq_n = cpu_mreq_n;
        sound_iorq_n = cpu_iorq_n;
        sound_rd_n = cpu_rd_n;
        sound_wr_n = cpu_wr_n;
        sound_irq_n = ym2203_irq_n;
        sound_nmi_n = cpu_nmi_n;
    end

endmodule

`default_nettype wire
