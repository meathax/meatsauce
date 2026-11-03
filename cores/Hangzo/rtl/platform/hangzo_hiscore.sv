// SPDX-License-Identifier: GPL-3.0-or-later
// Byte-oriented Hangzo frontend for the standard MiSTer hiscore v14 engine.
// This module deliberately stops at the work-RAM request/ack boundary.
module hangzo_hiscore #(
    // Keep accepted backend work until a real ACK by default. A caller may
    // enable reset cancellation only when the RAM backend is reset by the
    // same epoch signal and independently suppresses its write enable.
    parameter bit RAM_CANCEL_ON_RESET = 1'b0,
    parameter integer RAM_BYTE_AW = 14,
    parameter integer TABLE_BYTES = 140,
    parameter logic [23:0] TABLE_ABSOLUTE_FIRST = 24'h3f003a,
    parameter logic [7:0] FIRST_MARKER = 8'h00,
    parameter logic [7:0] LAST_MARKER = 8'h20
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        frame_boundary,
    input  logic        osd_open,
    input  logic        autosave,
    input  logic        table_initialized,
    input  logic        paused,

    input  logic        ioctl_download,
    input  logic        ioctl_upload,
    input  logic        ioctl_wr,
    input  logic [15:0] ioctl_index,
    input  logic [26:0] ioctl_address,
    input  logic [7:0]  ioctl_data,
    output logic [7:0]  ioctl_read_data,
    output logic        ioctl_upload_request,
    output logic        configured,
    output logic        pause_request,
    output logic        fault,

    output logic        ram_request,
    output logic        ram_write,
    output logic [RAM_BYTE_AW-1:0] ram_byte_address,
    output logic [7:0]  ram_write_data,
    input  logic        ram_ack,
    input  logic [7:0]  ram_read_data
);
    localparam logic [15:0] CONFIG_INDEX = 16'd3;
    localparam logic [15:0] DATA_INDEX   = 16'd4;
    localparam logic [26:0] CONFIG_BYTES = 27'd24;
    localparam logic [26:0] DATA_BYTES = TABLE_BYTES[26:0];
    localparam logic [7:0] DATA_COUNT = TABLE_BYTES[7:0];
    localparam logic [RAM_BYTE_AW-1:0] TABLE_FIRST = TABLE_ABSOLUTE_FIRST[RAM_BYTE_AW-1:0];
    localparam logic [31:0] TABLE_END_FULL = {8'd0,TABLE_ABSOLUTE_FIRST} + TABLE_BYTES - 32'd1;
    localparam logic [RAM_BYTE_AW-1:0] TABLE_LAST = TABLE_END_FULL[RAM_BYTE_AW-1:0];

    logic [7:0] config_stage [0:23];
    logic [7:0] data_stage [0:TABLE_BYTES-1];
    logic host_download_last = 1'b0;
    logic host_active = 1'b0;
    logic [15:0] host_kind = 16'hffff;
    logic [7:0] host_count = 8'd0;
    logic host_bad = 1'b0;
    logic data_pending = 1'b0;

    typedef enum logic [1:0] {R_NONE, R_CONFIG, R_DATA} replay_kind_t;
    typedef enum logic [1:0] {RP_LOAD, RP_END, RP_DROP} replay_phase_t;
    replay_kind_t replay_kind = R_NONE;
    replay_phase_t replay_phase = RP_LOAD;
    logic [7:0] replay_address = 8'd0;
    logic [7:0] replay_limit = 8'd0;

    wire replay_download = (replay_kind != R_NONE) && (replay_phase != RP_DROP);
    wire replay_write = replay_download && (replay_phase == RP_LOAD);
    wire [7:0] replay_data = (replay_kind == R_CONFIG) ?
                             config_stage[replay_address] : data_stage[replay_address];

    wire donor_pause;
    wire donor_upload_request;
    wire donor_read;
    wire donor_write;
    wire [RAM_BYTE_AW-1:0] donor_address;
    wire [7:0] donor_data_to_host;
    wire [7:0] donor_data_to_ram;
    logic donor_data_ready = 1'b0;
    logic [7:0] donor_data_from_ram = 8'd0;

    wire upload_byte_valid = ioctl_upload && configured &&
                             (ioctl_index == DATA_INDEX) &&
                             (ioctl_address < DATA_BYTES);

    hiscore #(
        .HS_ADDRESSWIDTH(RAM_BYTE_AW),
        .HS_SCOREWIDTH(8),
        .HS_CONFIGINDEX(8'd3),
        .HS_DUMPINDEX(8'd4),
        .CFG_ADDRESSWIDTH(1),
        .CFG_LENGTHWIDTH(1)
    ) u_hiscore (
        .clk(clk),
        .paused(paused && table_initialized),
        .reset(reset),
        .autosave(autosave),
        .ioctl_upload(upload_byte_valid),
        .data_ready(donor_data_ready),
        .ioctl_upload_req(donor_upload_request),
        .ioctl_download(replay_download),
        .ioctl_wr(replay_write),
        .ioctl_addr(replay_download ? {17'd0, replay_address} : ioctl_address[24:0]),
        .ioctl_index(replay_download ? (replay_kind == R_CONFIG ? 8'd3 : 8'd4) :
                     (upload_byte_valid ? 8'd4 : 8'hff)),
        .OSD_STATUS(osd_open),
        .v_sync(frame_boundary),
        .data_from_hps(replay_data),
        .data_from_ram(donor_data_from_ram),
        .ram_address(donor_address),
        .data_to_hps(donor_data_to_host),
        .data_to_ram(donor_data_to_ram),
        .ram_write(donor_write),
        .ram_read(donor_read),
        .ram_intent_read(),
        .ram_intent_write(),
        .pause_cpu(donor_pause),
        .configured(configured)
    );

    typedef enum logic [1:0] {B_IDLE, B_GRANT, B_ACTIVE, B_GAP} bridge_state_t;
    bridge_state_t bridge_state = B_IDLE;
    logic [RAM_BYTE_AW-1:0] pending_address = '0;
    logic pending_write = 1'b0;
    logic [7:0] pending_data = 8'd0;

    assign pause_request = (donor_pause && table_initialized) ||
                           (bridge_state != B_IDLE);
    assign ioctl_upload_request = donor_upload_request;
    assign ram_request = (bridge_state == B_ACTIVE);
    assign ram_write = pending_write;
    assign ram_byte_address = pending_address;
    assign ram_write_data = pending_data;
    always_comb begin
        ioctl_read_data = upload_byte_valid ? donor_data_to_host : 8'd0;
    end

    // Constant-index staging reads belong outside a function: Quartus17
    // otherwise aborts VRFX veriname_elab.cpp:836 while mapping the RAM ports.
    // Same combinational predicate, no added stage or changed host protocol.
    // Static per-instance native table geometry; no byte mask.
    wire valid_config = (config_stage[15] == 8'h00) &&
                           (config_stage[16] == 8'h00) &&
                           (config_stage[17] == TABLE_ABSOLUTE_FIRST[23:16]) &&
                           (config_stage[18] == TABLE_ABSOLUTE_FIRST[15:8]) &&
                           (config_stage[19] == TABLE_ABSOLUTE_FIRST[7:0]) &&
                           (config_stage[20] == DATA_COUNT) &&
                           (config_stage[21] == FIRST_MARKER) &&
                           (config_stage[22] == LAST_MARKER);

    integer i;
    logic host_start;
    logic [15:0] current_kind;
    logic [7:0] current_count;
    logic current_bad;
    logic [26:0] expected_length;
    always_comb begin
        host_start = ioctl_download && !host_download_last;
        current_kind = host_start ? ioctl_index : host_kind;
        current_count = host_start ? 8'd0 : host_count;
        current_bad = host_start ?
                      !((ioctl_index == CONFIG_INDEX) || (ioctl_index == DATA_INDEX)) : host_bad;
        expected_length = current_kind == CONFIG_INDEX ? CONFIG_BYTES : DATA_BYTES;
    end

    always_ff @(posedge clk) begin
        donor_data_ready <= 1'b0;
        host_download_last <= ioctl_download;

        if (ioctl_download && !host_download_last) begin
            host_active <= 1'b1;
            host_kind <= ioctl_index;
            host_count <= 8'd0;
            host_bad <= !((ioctl_index == CONFIG_INDEX) || (ioctl_index == DATA_INDEX));
            if (replay_kind != R_NONE &&
                !(ioctl_index == DATA_INDEX && replay_kind == R_CONFIG))
                host_bad <= 1'b1;
        end

        if (ioctl_download && ioctl_wr) begin
            if (!((current_kind == CONFIG_INDEX) || (current_kind == DATA_INDEX))) begin
                host_bad <= 1'b1;
            end else begin
                if (ioctl_index != current_kind || ioctl_address != {19'd0, current_count} ||
                    {19'd0, current_count} >= expected_length || current_bad ||
                    (current_kind == CONFIG_INDEX && replay_kind != R_NONE) ||
                    (current_kind == DATA_INDEX && replay_kind == R_DATA)) begin
                    host_bad <= 1'b1;
                end else if (current_kind == CONFIG_INDEX) begin
                    config_stage[current_count] <= ioctl_data;
                end else begin
                    data_stage[current_count] <= ioctl_data;
                end
                if (current_count != 8'hff) host_count <= current_count + 8'd1;
            end
        end

        if (!ioctl_download && host_download_last) begin
            host_active <= 1'b0;
            if (host_kind == CONFIG_INDEX) begin
                if (!host_bad && host_count == 8'd24 && valid_config) begin
                    if (replay_kind == R_NONE) begin
                        replay_kind <= R_CONFIG;
                        replay_phase <= RP_LOAD;
                        replay_address <= 8'd0;
                        replay_limit <= 8'd24;
                    end else begin
                        fault <= 1'b1;
                    end
                end else if (host_count != 0 || host_bad) begin
                    fault <= 1'b1;
                end
            end else if (host_kind == DATA_INDEX) begin
                if (!host_bad && host_count == DATA_COUNT) begin
                    if (data_pending) begin
                        fault <= 1'b1;
                    end else begin
                        data_pending <= 1'b1;
                    end
                end else if (host_count != 0 || host_bad) begin
                    fault <= 1'b1;
                end
            end
        end

        if (replay_kind != R_NONE) begin
            case (replay_phase)
                RP_LOAD: begin
                    if (replay_address + 8'd1 >= replay_limit) begin
                        replay_phase <= RP_END;
                    end else begin
                        replay_address <= replay_address + 8'd1;
                    end
                end
                RP_END: replay_phase <= RP_DROP;
                RP_DROP: begin
                    replay_kind <= R_NONE;
                    replay_phase <= RP_LOAD;
                    replay_address <= 8'd0;
                end
                default: begin
                    replay_kind <= R_NONE;
                    replay_phase <= RP_LOAD;
                end
            endcase
        end else if (data_pending && configured) begin
            replay_kind <= R_DATA;
            replay_phase <= RP_LOAD;
            replay_address <= 8'd0;
            replay_limit <= DATA_COUNT;
            data_pending <= 1'b0;
        end

        if (reset) begin
            // In-flight accepted RAM requests drain below by default. Reset
            // cancellation is optional and must coincide with backend reset.
            // Only requests that have not reached the backend are otherwise
            // canceled here.
            // HPS transfers/replays remain live while the game is reset.
            // This mirrors MiSTer startup, where host files arrive under reset.
            if (bridge_state == B_GRANT || bridge_state == B_IDLE) begin
                bridge_state <= B_IDLE;
            end
            fault <= 1'b0;
        end

        // Bridge state is deliberately serviced during reset: once a backend
        // request is visible it remains owned until ram_ack drains it.
        case (bridge_state)
            B_IDLE: begin
                if (!reset && table_initialized && (donor_read || donor_write)) begin
                    if (donor_address < TABLE_FIRST || donor_address > TABLE_LAST) begin
                        fault <= 1'b1;
                        donor_data_from_ram <= 8'd0;
                        donor_data_ready <= 1'b1;
                        bridge_state <= B_GAP;
                    end else begin
                        pending_address <= donor_address;
                        pending_write <= donor_write;
                        pending_data <= donor_data_to_ram;
                        bridge_state <= B_GRANT;
                    end
                end
            end
            B_GRANT: begin
                if (reset) begin
                    bridge_state <= B_IDLE;
                end else if (paused) begin
                    bridge_state <= B_ACTIVE;
                end
            end
            B_ACTIVE: begin
                if (reset && RAM_CANCEL_ON_RESET) begin
                    // Explicit cancellation, not a synthetic RAM completion:
                    // reset suppresses downstream strobes and no stale read
                    // data is presented to the donor. The mandatory B_GAP
                    // edge releases request/pause ownership cleanly.
                    bridge_state <= B_GAP;
                end else if (ram_ack) begin
                    bridge_state <= B_GAP;
                    if (!reset) begin
                        donor_data_from_ram <= ram_read_data;
                        donor_data_ready <= 1'b1;
                    end
                end
            end
            B_GAP: bridge_state <= B_IDLE;
            default: bridge_state <= B_IDLE;
        endcase
    end

    // Host output read is byte-oriented. Upper address bits and non-dump
    // indices never alias the donor's 8-bit internal buffer address.
endmodule

// A separate cache/configuration belongs to each authoritative host profile.
// Inactive bridges and their matching main-RAM ports share reset cancellation.
module hangzo_hiscore_profiles #(parameter bit RAM_CANCEL_ON_RESET=1'b0)(
    input wire clk,reset,selected_schmeiser,
    input wire frame_boundary,osd_open,autosave,table_initialized,paused,
    input wire ioctl_download,ioctl_upload,ioctl_wr,
    input wire [15:0] ioctl_index,
    input wire [26:0] ioctl_address,
    input wire [7:0] ioctl_data,
    output wire [7:0] ioctl_read_data,
    output wire ioctl_upload_request,configured,pause_request,fault,
    output wire ram_request,ram_write,
    output wire [14:0] ram_byte_address,
    output wire [7:0] ram_write_data,
    input wire ram_ack,
    input wire [7:0] ram_read_data
);
    wire [1:0] upload_requests,configs,pauses,faults,requests,writes;
    wire [7:0] hps_data[0:1],write_data[0:1];
    wire [14:0] addresses[0:1];
    genvar p;
    generate for(p=0;p<2;p=p+1)begin: g_profile
        wire active=selected_schmeiser==(p==1);
        hangzo_hiscore #(.RAM_CANCEL_ON_RESET(RAM_CANCEL_ON_RESET),.RAM_BYTE_AW(15),
            .TABLE_BYTES(p==1 ? 100 : 140),.TABLE_ABSOLUTE_FIRST(p==1 ? 24'hff5a36 : 24'h3f003a),
            .FIRST_MARKER(8'h00),.LAST_MARKER(p==1 ? 8'h00 : 8'h20)) frontend(
            .clk(clk),.reset(reset || !active),.frame_boundary(frame_boundary),.osd_open(osd_open),.autosave(autosave),
            .table_initialized(table_initialized && active),.paused(paused && active),
            .ioctl_download(ioctl_download && active),.ioctl_upload(ioctl_upload && active),.ioctl_wr(ioctl_wr && active),
            .ioctl_index(ioctl_index),.ioctl_address(ioctl_address),.ioctl_data(ioctl_data),
            .ioctl_read_data(hps_data[p]),.ioctl_upload_request(upload_requests[p]),.configured(configs[p]),.pause_request(pauses[p]),.fault(faults[p]),
            .ram_request(requests[p]),.ram_write(writes[p]),.ram_byte_address(addresses[p]),.ram_write_data(write_data[p]),
            .ram_ack(ram_ack && active),.ram_read_data(ram_read_data));
    end endgenerate
    assign ioctl_read_data=selected_schmeiser ? hps_data[1] : hps_data[0];
    assign ioctl_upload_request=selected_schmeiser ? upload_requests[1] : upload_requests[0];
    assign configured=selected_schmeiser ? configs[1] : configs[0];
    assign pause_request=selected_schmeiser ? pauses[1] : pauses[0];
    assign fault=selected_schmeiser ? faults[1] : faults[0];
    assign ram_request=selected_schmeiser ? requests[1] : requests[0];
    assign ram_write=selected_schmeiser ? writes[1] : writes[0];
    assign ram_byte_address=selected_schmeiser ? addresses[1] : addresses[0];
    assign ram_write_data=selected_schmeiser ? write_data[1] : write_data[0];
endmodule
