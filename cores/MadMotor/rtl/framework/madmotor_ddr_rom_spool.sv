// SPDX-License-Identifier: GPL-3.0-or-later
// Fast MRA index-0 image replay into the existing Mad Motor byte loader.
// Private adapter; donor code is referenced in docs/DDR_ROM_SPOOL.md only.
module madmotor_ddr_rom_spool #(
    parameter logic [28:0] ROM_BASE_QWORD = 29'h06000000,
    parameter logic [21:0] IMAGE_BYTES = 22'h02b0000
) (
    input  logic        clk_sys,
    input  logic        reset,

    input  logic        ioctl_download,
    input  logic        ioctl_wr,
    input  logic [15:0] ioctl_index,
    input  logic [26:0] ioctl_addr,
    input  logic [7:0]  ioctl_dout,
    output logic        ioctl_wait,

    output logic        rom_ioctl_download,
    output logic        rom_ioctl_wr,
    output logic [15:0] rom_ioctl_index,
    output logic [26:0] rom_ioctl_addr,
    output logic [7:0]  rom_ioctl_dout,
    input  logic        rom_ioctl_wait,
    input  logic        rom_load_mode,
    input  logic        rom_loaded_in,
    output logic        rom_loaded,

    input  logic [7:0]  rot_queue_level,
    input  logic [7:0]  rot_ddram_burstcount,
    input  logic [28:0] rot_ddram_address,
    input  logic [63:0] rot_ddram_data,
    input  logic [7:0]  rot_ddram_byteenable,
    input  logic        rot_ddram_we,
    input  logic        rot_ddram_rd,
    output logic        rot_ddram_busy,
    output logic        rotation_reset,

    output logic        ddram_clk,
    output logic [7:0]  ddram_burstcount,
    output logic [28:0] ddram_address,
    input  logic [63:0] ddram_dout,
    input  logic        ddram_dout_ready,
    output logic        ddram_rd,
    output logic [63:0] ddram_din,
    output logic [7:0]  ddram_byteenable,
    output logic        ddram_we,
    input  logic        ddram_busy,

    output logic        load_busy,
    output logic        load_error,
    output logic        owner_rom,
    output logic        protocol_error
);
    localparam logic [26:0] IMAGE_BYTES_27 = {5'b00000, IMAGE_BYTES};
    localparam logic [21:0] LAST_BYTE = IMAGE_BYTES - 22'd1;
    localparam logic [18:0] LAST_QWORD = IMAGE_BYTES[21:3] - 19'd1;

    typedef enum logic [3:0] {
        S_ROTATION          = 4'd0,
        S_QUIESCE_TO_ROM    = 4'd1,
        S_READ_REQUEST      = 4'd2,
        S_WAIT_RESPONSE     = 4'd3,
        S_REPLAY_BYTES      = 4'd4,
        S_REPLAY_END        = 4'd5,
        S_WAIT_LOADER       = 4'd6,
        S_ABORT_WAIT_READ   = 4'd7,
        S_ABORT_LOADER      = 4'd8,
        S_RETURN_DRAIN      = 4'd9
    } state_t;

    state_t state;
    logic host_active;
    logic host_byte_seen;
    logic host_fast_candidate;
    logic [26:0] host_length;
    logic direct_route;
    logic fast_pending;
    logic [21:0] stream_index;
    logic [18:0] qword_index;
    logic [2:0] byte_lane;
    logic [63:0] read_buffer;
    logic [1:0] quiet_cycles;
    logic read_pending = 1'b0;

    wire host_rom_download = ioctl_download && (ioctl_index == 16'd0);
    wire host_rom_start = host_rom_download && !host_active;
    wire host_rom_end = host_active && !host_rom_download;
    wire direct_first_byte = host_rom_download && ioctl_wr;
    wire direct_to_loader = direct_route || direct_first_byte ||
                            (host_active && host_byte_seen);
    wire read_accept = ddram_rd && !ddram_busy;
    wire quiet_bus = !ddram_busy && !ddram_dout_ready && !read_pending &&
                     (rot_queue_level == 8'd0) && !rot_ddram_we &&
                     !rot_ddram_rd && !rom_load_mode;

    assign ddram_clk = clk_sys;
    assign owner_rom = (state != S_ROTATION);
    assign rom_loaded = rom_loaded_in && !load_error && !host_rom_download &&
                        !host_active && !direct_route && !fast_pending &&
                        !owner_rom;
    assign rotation_reset = reset || host_rom_download || host_active ||
                            direct_route || fast_pending || owner_rom ||
                            !rom_loaded_in || load_error;
    assign rot_ddram_busy = rotation_reset || owner_rom;

    always_comb begin
        load_busy = reset || host_rom_download || host_active || direct_route ||
                    fast_pending || owner_rom || rom_load_mode || !rom_loaded_in ||
                    load_error;

        rom_ioctl_download = 1'b0;
        rom_ioctl_wr = 1'b0;
        rom_ioctl_index = 16'd0;
        rom_ioctl_addr = 27'd0;
        rom_ioctl_dout = 8'd0;
        ioctl_wait = 1'b0;

        if (state == S_ROTATION) begin
            if (direct_to_loader || (ioctl_download && (ioctl_index != 16'd0))) begin
                rom_ioctl_download = ioctl_download;
                rom_ioctl_wr = ioctl_wr;
                rom_ioctl_index = ioctl_index;
                rom_ioctl_addr = ioctl_addr;
                rom_ioctl_dout = ioctl_dout;
                ioctl_wait = rom_ioctl_wait;
            end
        end else if ((state == S_READ_REQUEST) ||
                     (state == S_WAIT_RESPONSE) ||
                     (state == S_REPLAY_BYTES) ||
                     (state == S_REPLAY_END)) begin
            // Keep one loader download epoch across DDR qword boundaries.
            // A low download level between reads would make the byte loader
            // treat each 8-byte DDR response as a short, separate image.
            rom_ioctl_download = 1'b1;
            rom_ioctl_index = 16'd0;
            rom_ioctl_addr = {5'b00000, stream_index};
            if (state == S_REPLAY_BYTES) begin
                rom_ioctl_dout = read_buffer[{byte_lane, 3'b000} +: 8];
                rom_ioctl_wr = !rom_ioctl_wait && !reset && !host_rom_start;
            end
            if (ioctl_wr)
                ioctl_wait = 1'b1;
        end else begin
            if (ioctl_wr)
                ioctl_wait = 1'b1;
        end

        ddram_address = 29'd0;
        ddram_burstcount = 8'd1;
        ddram_din = 64'd0;
        ddram_byteenable = 8'hff;
        ddram_rd = 1'b0;
        ddram_we = 1'b0;
        if (state == S_ROTATION) begin
            if (!rotation_reset) begin
                ddram_burstcount = rot_ddram_burstcount;
                ddram_address = rot_ddram_address;
                ddram_din = rot_ddram_data;
                ddram_byteenable = rot_ddram_byteenable;
                ddram_we = rot_ddram_we;
                ddram_rd = rot_ddram_rd && !ddram_busy;
            end
        end else if ((state == S_READ_REQUEST) ||
                     (state == S_WAIT_RESPONSE) ||
                     (state == S_ABORT_WAIT_READ)) begin
            ddram_address = ROM_BASE_QWORD + {10'd0, qword_index};
            ddram_rd = (state == S_READ_REQUEST) && !ddram_busy &&
                       !reset && !host_rom_start;
        end
    end

    always_ff @(posedge clk_sys) begin
        // The read ledger deliberately survives reset. Avalon has no cancel
        // signal: an accepted response keeps ROM ownership until DOUT_READY.
        if (read_accept)
            read_pending <= !ddram_dout_ready;
        else if (read_pending && ddram_dout_ready)
            read_pending <= 1'b0;
    end

    always_ff @(posedge clk_sys) begin
        if (reset) begin
            host_active <= 1'b0;
            host_byte_seen <= 1'b0;
            host_fast_candidate <= 1'b0;
            host_length <= 27'd0;
            direct_route <= 1'b0;
            fast_pending <= 1'b0;
            stream_index <= 22'd0;
            qword_index <= 19'd0;
            byte_lane <= 3'd0;
            read_buffer <= 64'd0;
            quiet_cycles <= 2'd0;
            load_error <= 1'b0;
            protocol_error <= 1'b0;
            if (read_pending) begin
                if (ddram_dout_ready)
                    state <= S_RETURN_DRAIN;
                else
                    state <= S_ABORT_WAIT_READ;
            end else if (state == S_ROTATION) begin
                state <= S_ROTATION;
            end else begin
                state <= S_RETURN_DRAIN;
            end
        end else begin
            if (host_rom_start) begin
                host_active <= 1'b1;
                host_byte_seen <= ioctl_wr;
                host_fast_candidate <= (ioctl_addr != 27'd0) && !ioctl_wr;
                host_length <= ioctl_addr;
                direct_route <= direct_route || ioctl_wr;
                fast_pending <= 1'b0;
                load_error <= 1'b0;
            end else if (host_active) begin
                if (host_rom_download && ioctl_wr) begin
                    host_byte_seen <= 1'b1;
                    host_fast_candidate <= 1'b0;
                    direct_route <= 1'b1;
                end
                if (host_rom_end) begin
                    host_active <= 1'b0;
                    if (host_byte_seen || ioctl_wr) begin
                        direct_route <= 1'b1;
                    end else if (host_fast_candidate &&
                                 (host_length == IMAGE_BYTES_27)) begin
                        fast_pending <= 1'b1;
                        load_error <= 1'b0;
                    end else begin
                        load_error <= 1'b1;
                    end
                    host_byte_seen <= 1'b0;
                    host_fast_candidate <= 1'b0;
                end
            end

            if (direct_route && !host_active && !host_rom_download &&
                !rom_load_mode && (state == S_ROTATION)) begin
                direct_route <= 1'b0;
                if (!rom_loaded_in)
                    load_error <= 1'b1;
            end

            if (ddram_dout_ready && !read_pending && !read_accept)
                protocol_error <= 1'b1;
            if (rot_ddram_rd)
                protocol_error <= 1'b1;

            case (state)
                S_ROTATION: begin
                    quiet_cycles <= 2'd0;
                    if (host_rom_start) begin
                        state <= S_ROTATION;
                    end else if (fast_pending) begin
                        fast_pending <= 1'b0;
                        state <= S_QUIESCE_TO_ROM;
                    end
                end

                S_QUIESCE_TO_ROM: begin
                    if (host_rom_start) begin
                        state <= S_ABORT_LOADER;
                        quiet_cycles <= 2'd0;
                    end else if (quiet_bus) begin
                        if (quiet_cycles == 2'd1) begin
                            state <= S_READ_REQUEST;
                            stream_index <= 22'd0;
                            qword_index <= 19'd0;
                            byte_lane <= 3'd0;
                            quiet_cycles <= 2'd0;
                        end else begin
                            quiet_cycles <= quiet_cycles + 2'd1;
                        end
                    end else begin
                        quiet_cycles <= 2'd0;
                    end
                end

                S_READ_REQUEST: begin
                    if (host_rom_start) begin
                        state <= S_ABORT_LOADER;
                        quiet_cycles <= 2'd0;
                    end else if (read_accept) begin
                        if (ddram_dout_ready) begin
                            read_buffer <= ddram_dout;
                            byte_lane <= 3'd0;
                            state <= S_REPLAY_BYTES;
                        end else begin
                            state <= S_WAIT_RESPONSE;
                        end
                    end
                end

                S_WAIT_RESPONSE: begin
                    if (host_rom_start) begin
                        if (ddram_dout_ready)
                            state <= S_ABORT_LOADER;
                        else
                            state <= S_ABORT_WAIT_READ;
                    end else if (ddram_dout_ready && read_pending) begin
                        read_buffer <= ddram_dout;
                        byte_lane <= 3'd0;
                        state <= S_REPLAY_BYTES;
                    end
                end

                S_REPLAY_BYTES: begin
                    if (host_rom_start) begin
                        state <= S_ABORT_LOADER;
                    end else if (!rom_ioctl_wait && !reset && !host_rom_start) begin
                        if (stream_index == LAST_BYTE) begin
                            state <= S_REPLAY_END;
                        end else begin
                            stream_index <= stream_index + 22'd1;
                            if (byte_lane == 3'd7) begin
                                byte_lane <= 3'd0;
                                if (qword_index == LAST_QWORD) begin
                                    protocol_error <= 1'b1;
                                    state <= S_ABORT_LOADER;
                                end else begin
                                    qword_index <= qword_index + 19'd1;
                                    state <= S_READ_REQUEST;
                                end
                            end else begin
                                byte_lane <= byte_lane + 3'd1;
                            end
                        end
                    end
                end

                S_REPLAY_END: begin
                    state <= S_WAIT_LOADER;
                end

                S_WAIT_LOADER: begin
                    if (host_rom_start) begin
                        state <= S_ABORT_LOADER;
                    end else if (rom_loaded_in && !rom_load_mode) begin
                        state <= S_RETURN_DRAIN;
                        quiet_cycles <= 2'd0;
                    end
                end

                S_ABORT_WAIT_READ: begin
                    if (ddram_dout_ready && read_pending)
                        state <= S_ABORT_LOADER;
                end

                S_ABORT_LOADER: begin
                    if (!rom_load_mode) begin
                        state <= S_RETURN_DRAIN;
                        quiet_cycles <= 2'd0;
                    end
                end

                S_RETURN_DRAIN: begin
                    if (quiet_bus) begin
                        if (quiet_cycles == 2'd1) begin
                            state <= S_ROTATION;
                            quiet_cycles <= 2'd0;
                        end else begin
                            quiet_cycles <= quiet_cycles + 2'd1;
                        end
                    end else begin
                        quiet_cycles <= 2'd0;
                    end
                end

                default: begin
                    state <= S_ROTATION;
                    protocol_error <= 1'b1;
                end
            endcase
        end
    end

endmodule
