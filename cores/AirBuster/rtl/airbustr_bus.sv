// SPDX-License-Identifier: GPL-3.0-or-later
// Round-robin CPU transactions and Air Buster's board I/O (airbustr.cpp maps).
// One request per valid/ready handshake, one registered response.
//   main  OUT 00 bank (data&7), 01 nop, 02 sub NMI pulse
//   sub   OUT 00 bank/flip(b4)/sprite-clear(b5), 02 soundlatch, 04-0C scroll,
//         28 coin counters/lockout, 38 irq ack (nop)
//         IN  02 soundlatch2, 0E latch status, 20 P1, 22 P2, 24 SYSTEM
//   sound OUT 00 bank, 02/03 YM2203, 04 OKI, 06 soundlatch2
//         IN  02/03 YM2203, 04 OKI status, 06 soundlatch
module airbustr_bus (
    input  logic        clk,
    input  logic        reset,
    input  logic [2:0]  cpu_req_valid,
    output logic [2:0]  cpu_req_ready,
    input  logic [2:0]  cpu_req_io,
    input  logic [2:0]  cpu_req_write,
    input  logic [47:0] cpu_req_addr,
    input  logic [23:0] cpu_req_data,
    output logic [2:0]  cpu_rsp_valid,
    output logic [23:0] cpu_rsp_data,
    output logic        mem_req_valid,
    input  logic        mem_req_ready,
    output logic [1:0]  mem_req_cpu,
    output logic        mem_req_write,
    output logic [15:0] mem_req_addr,
    output logic [7:0]  mem_req_data,
    input  logic        mem_rsp_valid,
    input  logic [7:0]  mem_rsp_data,
    input  logic [7:0]  system_inputs_n, player1_inputs_n, player2_inputs_n,
    output logic [2:0]  main_bank, sub_bank, sound_bank,
    output logic [7:0]  sub_control,
    output logic [7:0]  scroll_x0, scroll_y0, scroll_x1, scroll_y1, scroll_high_n,
    output logic [3:0]  coin_outputs,
    output logic        sub_nmi_request,
    output logic        sound_nmi,
    // YM2203 (sel=0) or OKI (sel=1) on the sound CPU.
    output logic        snd_req_valid,
    input  logic        snd_req_ready,
    output logic        snd_req_oki,
    output logic        snd_req_write,
    output logic        snd_req_addr,
    output logic [7:0]  snd_req_data,
    input  logic        snd_rsp_valid,
    input  logic [7:0]  snd_rsp_data
);
    typedef enum logic [2:0] {IDLE, DISPATCH, MEM_ISSUE, MEM_WAIT,
        SND_ISSUE, SND_WAIT} state_t;
    state_t state;
    logic [1:0] next_cpu, selected;
    logic selected_valid, request_io;
    logic [7:0] latch_to_sound, latch_to_sub;
    logic latch_to_sound_pending, latch_to_sub_pending;
    wire [7:0] port = mem_req_addr[7:0];
    wire io_dispatch = state == DISPATCH && request_io;
    wire sub_latch_write = io_dispatch && mem_req_cpu == 1 && mem_req_write && port == 8'h02;
    wire sub_latch_read  = io_dispatch && mem_req_cpu == 1 && !mem_req_write && port == 8'h02;
    wire snd_latch_write = io_dispatch && mem_req_cpu == 2 && mem_req_write && port == 8'h06;
    wire snd_latch_read  = io_dispatch && mem_req_cpu == 2 && !mem_req_write && port == 8'h06;
    wire snd_chip_port   = mem_req_cpu == 2 && (port == 8'h02 || port == 8'h03 || port == 8'h04);

    always_comb begin
        selected = next_cpu;
        selected_valid = |cpu_req_valid;
        case (next_cpu)
            2'd0: if (cpu_req_valid[0]) selected=0;
                else if (cpu_req_valid[1]) selected=1; else selected=2;
            2'd1: if (cpu_req_valid[1]) selected=1;
                else if (cpu_req_valid[2]) selected=2; else selected=0;
            default: if (cpu_req_valid[2]) selected=2;
                else if (cpu_req_valid[0]) selected=0; else selected=1;
        endcase
        cpu_req_ready = 3'd0;
        if (state == IDLE && !reset && selected_valid)
            cpu_req_ready[selected] = 1'b1;
    end
    assign mem_req_valid = state == MEM_ISSUE && !reset;
    assign snd_req_valid = state == SND_ISSUE && !reset;
    assign snd_req_oki = port == 8'h04;
    assign snd_req_write = mem_req_write;
    assign snd_req_addr = mem_req_addr[0];
    assign snd_req_data = mem_req_data;

    // generic_latch_8: write sets pending, read clears it (new write wins).
    // Sound NMI follows the to-sound latch pending level.
    assign sound_nmi = latch_to_sound_pending;
    always_ff @(posedge clk) begin
        if (reset) begin
            latch_to_sound <= 8'd0; latch_to_sub <= 8'd0;
            latch_to_sound_pending <= 1'b0; latch_to_sub_pending <= 1'b0;
        end else begin
            if (snd_latch_read) latch_to_sound_pending <= 1'b0;
            if (sub_latch_write) begin latch_to_sound <= mem_req_data; latch_to_sound_pending <= 1'b1; end
            if (sub_latch_read) latch_to_sub_pending <= 1'b0;
            if (snd_latch_write) begin latch_to_sub <= mem_req_data; latch_to_sub_pending <= 1'b1; end
        end
    end

    always_ff @(posedge clk) begin
        cpu_rsp_valid <= 3'd0;
        sub_nmi_request <= 1'b0;
        if (reset) begin
            state <= IDLE;
            next_cpu <= 2'd0;
            request_io <= 1'b0;
            mem_req_cpu <= 2'd0;
            mem_req_write <= 1'b0;
            mem_req_addr <= 16'd0;
            mem_req_data <= 8'd0;
            cpu_rsp_data <= 24'hffffff;
            main_bank <= 3'd0; sub_bank <= 3'd0; sound_bank <= 3'd0;
            sub_control <= 8'h20; // Pandora device_reset: clear_bitmap = true
            scroll_x0 <= 8'd0; scroll_y0 <= 8'd0; scroll_x1 <= 8'd0; scroll_y1 <= 8'd0;
            scroll_high_n <= 8'd0;
            coin_outputs <= 4'd0;
        end else begin
            case (state)
                IDLE: if (selected_valid) begin
                    mem_req_cpu <= selected;
                    mem_req_addr <= cpu_req_addr[16*selected +: 16];
                    mem_req_data <= cpu_req_data[8*selected +: 8];
                    mem_req_write <= cpu_req_write[selected];
                    request_io <= cpu_req_io[selected];
                    next_cpu <= selected == 2 ? 2'd0 : selected + 2'd1;
                    state <= DISPATCH;
                end
                DISPATCH: begin
                    if (!request_io) state <= MEM_ISSUE;
                    else if (snd_chip_port) state <= SND_ISSUE;
                    else begin
                        cpu_rsp_valid[mem_req_cpu] <= 1'b1;
                        cpu_rsp_data[8*mem_req_cpu +: 8] <= 8'h00;
                        state <= IDLE;
                        if (mem_req_write) begin
                            case (mem_req_cpu)
                                2'd0: case (port)
                                    8'h00: main_bank <= mem_req_data[2:0];
                                    8'h02: sub_nmi_request <= 1'b1;
                                    default: ;
                                endcase
                                2'd1: case (port)
                                    8'h00: begin sub_bank <= mem_req_data[2:0]; sub_control <= mem_req_data; end
                                    // scrollregs_w: offset = port-4
                                    8'h04: scroll_y1 <= mem_req_data;
                                    8'h06: scroll_x1 <= mem_req_data;
                                    8'h08: scroll_y0 <= mem_req_data;
                                    8'h0a: scroll_x0 <= mem_req_data;
                                    8'h0c: scroll_high_n <= mem_req_data;
                                    8'h28: coin_outputs <= mem_req_data[3:0];
                                    default: ;
                                endcase
                                2'd2: if (port == 8'h00) sound_bank <= mem_req_data[2:0];
                                default: ;
                            endcase
                        end else begin
                            case (mem_req_cpu)
                                2'd1: case (port)
                                    8'h02: cpu_rsp_data[15:8] <= latch_to_sub;
                                    8'h0e: cpu_rsp_data[15:8] <= {5'd0, 1'b1, latch_to_sound_pending, !latch_to_sub_pending};
                                    8'h20: cpu_rsp_data[15:8] <= player1_inputs_n;
                                    8'h22: cpu_rsp_data[15:8] <= player2_inputs_n;
                                    8'h24: cpu_rsp_data[15:8] <= system_inputs_n;
                                    default: ;
                                endcase
                                2'd2: if (port == 8'h06) cpu_rsp_data[23:16] <= latch_to_sound;
                                default: ;
                            endcase
                        end
                    end
                end
                MEM_ISSUE: if (mem_req_ready) state <= MEM_WAIT;
                MEM_WAIT: if (mem_rsp_valid) begin
                    cpu_rsp_valid[mem_req_cpu] <= 1'b1;
                    cpu_rsp_data[8*mem_req_cpu +: 8] <= mem_rsp_data;
                    state <= IDLE;
                end
                SND_ISSUE: if (snd_req_ready) state <= SND_WAIT;
                SND_WAIT: if (snd_rsp_valid) begin
                    cpu_rsp_valid[mem_req_cpu] <= 1'b1;
                    cpu_rsp_data[8*mem_req_cpu +: 8] <= snd_rsp_data;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
