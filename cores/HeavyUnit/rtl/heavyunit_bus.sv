// SPDX-License-Identifier: GPL-3.0-or-later
// Round-robin CPU transactions and Heavy Unit's board I/O latches.
// One request per valid/ready handshake, one registered response, no replay
// while a ROM/Yamaha request is outstanding. Z80 T-state adapters follow in P3.
module heavyunit_bus (
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
    output logic [2:0]  main_bank,
    output logic [1:0]  sub_bank,
    output logic [1:0]  sound_bank,
    output logic [7:0]  sub_control,
    output logic [7:0]  scroll_x,
    output logic [7:0]  scroll_y,
    output logic        sub_nmi_request,
    output logic        sub_irq_ack,
    output logic [7:0]  mermaid_command,
    output logic        mermaid_command_pending,
    input  logic        mermaid_command_ack,
    input  logic        mermaid_response_write,
    input  logic [7:0]  mermaid_response_data,
    output logic        mermaid_response_pending,
    output logic        sound_nmi,
    output logic        ym_req_valid,
    input  logic        ym_req_ready,
    output logic        ym_req_write,
    output logic        ym_req_addr,
    output logic [7:0]  ym_req_data,
    input  logic        ym_rsp_valid,
    input  logic [7:0]  ym_rsp_data
);
    typedef enum logic [2:0] {IDLE, DISPATCH, MEM_ISSUE, MEM_WAIT,
        YM_ISSUE, YM_WAIT} state_t;
    state_t state;
    logic [1:0] next_cpu, selected;
    logic selected_valid, request_io;
    logic [7:0] mermaid_response, sound_command;
    logic command_write, response_read, sound_write, sound_read;

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
    assign ym_req_valid = state == YM_ISSUE && !reset;
    assign ym_req_write = mem_req_write;
    assign ym_req_addr = mem_req_addr[0];
    assign ym_req_data = mem_req_data;
    assign command_write = state == DISPATCH && request_io &&
        mem_req_cpu == 1 && mem_req_write && mem_req_addr[7:0] == 8'h04;
    assign response_read = state == DISPATCH && request_io &&
        mem_req_cpu == 1 && !mem_req_write && mem_req_addr[7:0] == 8'h04;
    assign sound_write = state == DISPATCH && request_io &&
        mem_req_cpu == 1 && mem_req_write && mem_req_addr[7:0] == 8'h02;
    assign sound_read = state == DISPATCH && request_io &&
        mem_req_cpu == 2 && !mem_req_write && mem_req_addr[7:0] == 8'h04;

    // New data wins a coincident acknowledgement; reads return the prior byte.
    // Sound NMI is the pending level, matching generic_latch_8 pending_cb.
    always_ff @(posedge clk) begin
        if (reset) begin
            mermaid_command <= 8'd0;
            mermaid_response <= 8'd0;
            sound_command <= 8'd0;
            mermaid_command_pending <= 1'b0;
            mermaid_response_pending <= 1'b0;
            sound_nmi <= 1'b0;
        end else begin
            if (mermaid_command_ack) mermaid_command_pending <= 1'b0;
            if (command_write) begin
                mermaid_command <= mem_req_data;
                mermaid_command_pending <= 1'b1;
            end
            if (response_read) mermaid_response_pending <= 1'b0;
            if (mermaid_response_write) begin
                mermaid_response <= mermaid_response_data;
                mermaid_response_pending <= 1'b1;
            end
            if (sound_read) sound_nmi <= 1'b0;
            if (sound_write) begin
                sound_command <= mem_req_data;
                sound_nmi <= 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        cpu_rsp_valid <= 3'd0;
        sub_nmi_request <= 1'b0;
        sub_irq_ack <= 1'b0;
        if (reset) begin
            state <= IDLE;
            next_cpu <= 2'd0;
            request_io <= 1'b0;
            mem_req_cpu <= 2'd0;
            mem_req_write <= 1'b0;
            mem_req_addr <= 16'd0;
            mem_req_data <= 8'd0;
            cpu_rsp_data <= 24'hffffff;
            main_bank <= 3'd0;
            sub_bank <= 2'd0;
            sound_bank <= 2'd0;
            sub_control <= 8'd0;
            scroll_x <= 8'd0;
            scroll_y <= 8'd0;
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
                    else if (mem_req_cpu == 2 &&
                        (mem_req_addr[7:0] == 8'h02 || mem_req_addr[7:0] == 8'h03))
                        state <= YM_ISSUE;
                    else begin
                        cpu_rsp_valid[mem_req_cpu] <= 1'b1;
                        cpu_rsp_data[8*mem_req_cpu +: 8] <= 8'h00;
                        state <= IDLE;
                        if (mem_req_write) begin
                            case (mem_req_cpu)
                                2'd0: case (mem_req_addr[7:0])
                                    8'h00,8'h01: main_bank <= mem_req_data[2:0];
                                    8'h02: sub_nmi_request <= 1'b1;
                                    default: ;
                                endcase
                                2'd1: case (mem_req_addr[7:0])
                                    8'h00: begin
                                        sub_bank <= mem_req_data[1:0];
                                        sub_control <= mem_req_data;
                                    end
                                    8'h06: scroll_y <= mem_req_data;
                                    8'h08: scroll_x <= mem_req_data;
                                    8'h0e: sub_irq_ack <= 1'b1;
                                    default: ;
                                endcase
                                2'd2: if (mem_req_addr[7:0] == 8'h00)
                                    sound_bank <= mem_req_data[1:0];
                                default: ;
                            endcase
                        end else begin
                            if (response_read)
                                cpu_rsp_data[8*mem_req_cpu +: 8] <= mermaid_response;
                            else if (mem_req_cpu == 1 && mem_req_addr[7:0] == 8'h0c)
                                cpu_rsp_data[8*mem_req_cpu +: 8] <=
                                    // CPU status differs from the MCU P3 pins:
                                    // bit3 is command busy; bit2 is reply empty.
                                    {4'd0,mermaid_command_pending,~mermaid_response_pending,2'd0};
                            else if (sound_read)
                                cpu_rsp_data[8*mem_req_cpu +: 8] <= sound_command;
                        end
                    end
                end
                MEM_ISSUE: if (mem_req_ready) state <= MEM_WAIT;
                MEM_WAIT: if (mem_rsp_valid) begin
                    cpu_rsp_valid[mem_req_cpu] <= 1'b1;
                    cpu_rsp_data[8*mem_req_cpu +: 8] <= mem_rsp_data;
                    state <= IDLE;
                end
                YM_ISSUE: if (ym_req_ready) state <= YM_WAIT;
                YM_WAIT: if (ym_rsp_valid) begin
                    cpu_rsp_valid[mem_req_cpu] <= 1'b1;
                    cpu_rsp_data[8*mem_req_cpu +: 8] <= ym_rsp_data;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
