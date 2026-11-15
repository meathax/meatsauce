// SPDX-License-Identifier: GPL-3.0-or-later
// Canonical Psycho Soldier adapter for the unchanged staged standard hiscore FSM.
// paused is a quiescent grant from the board, not merely a requested pause level.
`default_nettype none

module psychos_hiscore (
    input  wire        clk,
    input  wire        reset,
    input  wire        paused,
    input  wire        autosave,
    input  wire        ioctl_upload,
    input  wire        ioctl_download,
    input  wire        ioctl_wr,
    input  wire [24:0] ioctl_addr,
    input  wire [7:0]  ioctl_index,
    input  wire        OSD_STATUS,
    input  wire [7:0]  data_from_hps,
    output wire [7:0]  data_to_hps,
    output wire        ioctl_upload_req,
    output wire [7:0]  ioctl_upload_index,
    output wire        configured,
    output wire        pause_request,
    output wire        hs_req,
    output wire        hs_write,
    output wire [15:0] hs_addr,
    output wire [7:0]  hs_wdata,
    input  wire        hs_ack,
    input  wire [7:0]  hs_rdata,
    output wire        fault
);
    // Standard version1 header and two eight-byte descriptor entries.
    // START_WAIT=FFFF; CHECK_WAIT=FF; CHECK_HOLD/WRITE_HOLD=2;
    // WRITE_REPEATCOUNT=1; WRITE_REPEATWAIT=1111; PAD=0; no change mask.
    function automatic [7:0] config_byte(input [5:0] addr);
        case (addr)
            0,1: config_byte=8'h00;
            2,3: config_byte=8'hFF;
            4: config_byte=8'h00; 5: config_byte=8'hFF;
            6: config_byte=8'h00; 7: config_byte=8'h02;
            8: config_byte=8'h00; 9: config_byte=8'h02;
            10: config_byte=8'h00; 11: config_byte=8'h01;
            12,13: config_byte=8'h11;
            14,15,16,17: config_byte=8'h00;
            18: config_byte=8'hDD; 19: config_byte=8'h05;
            20: config_byte=8'hF5; 21: config_byte=8'h31;
            22: config_byte=8'hFF; 23,24,25: config_byte=8'h00;
            26: config_byte=8'hFE; 27: config_byte=8'h66;
            28: config_byte=8'h03; 29,30,31: config_byte=8'h00;
            default: config_byte=8'h00;
        endcase
    endfunction

    function automatic in_range(input [15:0] address);
        in_range = ((address >= 16'hDD05) && (address <= 16'hDDF9)) ||
                   ((address >= 16'hFE66) && (address <= 16'hFE68));
    endfunction

    wire config_transfer = ioctl_download && (ioctl_index == 8'd3);
    wire dump_transfer = ioctl_download && (ioctl_index == 8'd4);
    reg last_config_transfer=0, last_dump_transfer=0;
    reg [5:0] config_count=0;
    reg [8:0] dump_count=0;
    reg config_valid=0, config_bad=0, dump_valid=0, dump_bad=0;
    reg address_fault=0;
    wire vendor_configured, vendor_pause, vendor_read, vendor_write;
    wire vendor_intent_read, vendor_intent_write, vendor_upload_req;
    wire [15:0] vendor_addr;
    wire [7:0] vendor_wdata, vendor_hps;
    reg vendor_ready=0;
    reg [7:0] vendor_rdata=0;
    reg request_pending=0, wait_command_drop=0;
    reg request_write=0;
    reg [15:0] request_addr=0;
    reg [7:0] request_data=0;
    wire vendor_command = vendor_read || vendor_write;

    assign fault = config_bad || dump_bad || address_fault;
    assign configured = vendor_configured && config_valid && !fault;
    assign hs_req = request_pending && !reset;
    assign hs_write = request_write;
    assign hs_addr = request_addr;
    assign hs_wdata = request_data;
    assign pause_request = configured && !reset && (vendor_pause || request_pending);
    assign ioctl_upload_req = configured && !reset && vendor_upload_req;
    assign ioctl_upload_index = 8'd4;
    assign data_to_hps = configured ? vendor_hps : 8'hFF;

    // Validate the exact canonical descriptor and complete, sequential F8-byte dumps.
    // This scanner stays active while core reset is held during MRA/HPS downloads.
    always @(posedge clk) begin
        last_config_transfer <= config_transfer;
        last_dump_transfer <= dump_transfer;
        if (config_transfer && !last_config_transfer) begin
            config_valid <= 0;
            config_count <= (ioctl_wr && ioctl_addr==0 && data_from_hps==config_byte(0)) ? 6'd1 : 6'd0;
            config_bad <= ioctl_wr && (ioctl_addr!=0 || data_from_hps!=config_byte(0));
        end else if (config_transfer && ioctl_wr) begin
            if (ioctl_addr < 25'd32 && ioctl_addr == {19'd0,config_count} &&
                data_from_hps == config_byte(ioctl_addr[5:0]) && config_count < 6'd32)
                config_count <= config_count + 6'd1;
            else config_bad <= 1;
        end
        if (!config_transfer && last_config_transfer)
            config_valid <= (config_count==6'd32) && !config_bad;
        if (dump_transfer && !last_dump_transfer) begin
            dump_valid <= 0;
            dump_count <= (ioctl_wr && ioctl_addr==0) ? 9'd1 : 9'd0;
            dump_bad <= ioctl_wr && ioctl_addr!=0;
        end else if (dump_transfer && ioctl_wr) begin
            if (ioctl_addr < 25'd248 && ioctl_addr == {16'd0,dump_count} && dump_count < 9'd248)
                dump_count <= dump_count + 9'd1;
            else dump_bad <= 1;
        end
        if (!dump_transfer && last_dump_transfer) begin
            dump_valid <= (dump_count==9'd248) && !dump_bad;
            if (dump_count!=9'd248) dump_bad <= 1;
        end
    end

    // Convert one donor command into one held byte request. ACK supplies a one-cycle
    // data_ready edge; wait for command deassertion before accepting another command.
    // During reset, flush a donor WAITDATA command internally without external access.
    // Hold reset for at least three clocks so that this cancellation is consumed.
    always @(posedge clk) begin
        vendor_ready <= 0;
        if (reset) begin
            request_pending <= 0;
            wait_command_drop <= 1;
            address_fault <= 0;
            vendor_ready <= vendor_command;
        end else if (!configured || config_transfer || dump_transfer) begin
            request_pending <= 0;
            wait_command_drop <= 1;
        end else if (request_pending) begin
            if (hs_ack) begin
                vendor_rdata <= hs_rdata;
                vendor_ready <= 1;
                request_pending <= 0;
                wait_command_drop <= 1;
            end
        end else if (wait_command_drop) begin
            if (!vendor_command) wait_command_drop <= 0;
        end else if (vendor_command && paused) begin
            if (!in_range(vendor_addr) || (vendor_read && vendor_write) ||
                (vendor_write && !dump_valid)) begin
                address_fault <= 1;
            end else begin
                request_pending <= 1;
                request_write <= vendor_write;
                request_addr <= vendor_addr;
                request_data <= vendor_wdata;
            end
        end
    end

    psychos_standard_hiscore #(
        .HS_ADDRESSWIDTH(16), .HS_SCOREWIDTH(8),
        .HS_CONFIGINDEX(3), .HS_DUMPINDEX(4),
        .CFG_ADDRESSWIDTH(1), .CFG_LENGTHWIDTH(1)
    ) standard_hiscore (
        .clk(clk), .reset(reset), .paused(paused), .autosave(autosave),
        .ioctl_upload(ioctl_upload), .ioctl_download(ioctl_download),
        .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_index(ioctl_index),
        .OSD_STATUS(OSD_STATUS), .data_from_hps(data_from_hps),
        .data_ready(vendor_ready), .data_from_ram(vendor_rdata),
        .ioctl_upload_req(vendor_upload_req), .data_to_hps(vendor_hps),
        .ram_address(vendor_addr), .data_to_ram(vendor_wdata),
        .ram_write(vendor_write), .ram_read(vendor_read),
        .ram_intent_read(vendor_intent_read), .ram_intent_write(vendor_intent_write),
        .pause_cpu(vendor_pause), .configured(vendor_configured)
    );

`ifndef SYNTHESIS

    reg held=0;
    reg [15:0] held_addr=0;
    reg [7:0] held_data=0;
    reg held_write=0;
    always @(posedge clk) begin
        if (!reset && hs_req) begin
            assert (configured && paused && in_range(hs_addr));
        end
        if (!reset && held) begin
            assert (hs_req && hs_addr==held_addr && hs_write==held_write && hs_wdata==held_data);
        end
        held <= hs_req && !hs_ack && !reset;
        held_addr <= hs_addr;
        held_data <= hs_wdata;
        held_write <= hs_write;
    end
`endif
endmodule
`default_nettype wire
