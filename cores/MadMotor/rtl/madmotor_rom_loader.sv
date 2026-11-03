// MiSTer byte-stream adapter for the unified Mad Motor ROM image.
// All inputs, outputs, and memory handshakes use the existing clk_sys root.
module madmotor_rom_loader (
    input tri0 bandit,
    input  logic        clk_sys,
    input  logic        reset,

    input  logic        ioctl_download,
    input  logic        ioctl_wr,
    input  logic [15:0] ioctl_index,
    input  logic [26:0] ioctl_addr,
    input  logic [7:0]  ioctl_dout,
    output logic        ioctl_wait,

    output logic        load_mode,
    output logic        load_req,
    output logic [23:0] load_addr,
    output logic [15:0] load_data,
    output logic [1:0]  load_mask,
    input  logic        load_ok,

    output logic        audio_load_we,
    output logic [1:0]  audio_load_region,
    output logic [17:0] audio_load_addr,
    output logic [7:0]  audio_load_data,

    output logic        mcu_rom_we,
    output logic [11:0] mcu_rom_addr,
    output logic [7:0]  mcu_rom_data,

    output logic        rom_loaded
);
    localparam logic [21:0] GRAPHICS_BYTES = 22'h0260000;
    localparam logic [21:0] IMAGE_BYTES    = 22'h02b0000;
    localparam logic [21:0] BANDIT_IMAGE_BYTES = 22'h02b1000;
    localparam logic [21:0] BANDIT_MCU_BASE = 22'h02b0000;
    wire [21:0] expected_image_bytes=bandit ? BANDIT_IMAGE_BYTES : IMAGE_BYTES;

    localparam logic [2:0] IDLE       = 3'd0;
    localparam logic [2:0] RECEIVE    = 3'd1;
    localparam logic [2:0] LOAD_WAIT  = 3'd2;
    localparam logic [2:0] LOAD_DRAIN = 3'd3;
    localparam logic [2:0] FAIL       = 3'd4;

    logic [2:0] state;
    logic [21:0] stream_count;
    logic [7:0] pair_high;
    logic pair_valid;
    logic transfer_end_pending;

    wire target_download = ioctl_download && (ioctl_index == 16'd0);

    assign load_mode = (state != IDLE);
    assign ioctl_wait = (state == LOAD_WAIT) || (state == LOAD_DRAIN);

    function automatic [23:0] physical_word_address(input logic [21:0] byte_addr,input logic bandit_profile);
        logic [21:0] region_offset;
        begin
            if (byte_addr < 22'h0080000) begin
                region_offset = byte_addr;
                physical_word_address = {3'b000, region_offset[21:1]};
            end else if (byte_addr < 22'h00a0000) begin
                region_offset = byte_addr - 22'h0080000;
                physical_word_address = 24'h400000 + {3'b000, region_offset[21:1]};
            end else if (byte_addr < (bandit_profile ? 22'h0120000 : 22'h00e0000)) begin
                region_offset = byte_addr - 22'h00a0000;
                physical_word_address = 24'h410000 + {3'b000, region_offset[21:1]};
            end else if (byte_addr < 22'h0160000) begin
                region_offset = byte_addr - (bandit_profile ? 22'h0120000 : 22'h00e0000);
                physical_word_address = 24'h800000 + {3'b000, region_offset[21:1]};
            end else begin
                region_offset = byte_addr - 22'h0160000;
                physical_word_address = 24'hc00000 + {3'b000, region_offset[21:1]};
            end
        end
    endfunction

    always_ff @(posedge clk_sys) begin
        if (reset) begin
            state <= IDLE;
            stream_count <= 22'd0;
            pair_high <= 8'd0;
            pair_valid <= 1'b0;
            transfer_end_pending <= 1'b0;
            load_req <= 1'b0;
            load_addr <= 24'd0;
            load_data <= 16'd0;
            load_mask <= 2'b00;
            audio_load_we <= 1'b0;
            audio_load_region <= 2'd0;
            audio_load_addr <= 18'd0;
            audio_load_data <= 8'd0;
            mcu_rom_we <= 1'b0;
            mcu_rom_addr <= 12'd0;
            mcu_rom_data <= 8'd0;
            rom_loaded <= 1'b0;
        end else begin
            audio_load_we <= 1'b0;
            mcu_rom_we <= 1'b0;

            case (state)
                IDLE: begin
                    load_req <= 1'b0;
                    transfer_end_pending <= 1'b0;
                    pair_valid <= 1'b0;
                    if (target_download) begin
                        stream_count <= 22'd0;
                        rom_loaded <= 1'b0;
                        state <= RECEIVE;
                        // HPS may present the first byte with the download edge.
                        if (ioctl_wr) begin
                            if (ioctl_addr == 27'd0) begin
                                pair_high <= ioctl_dout;
                                pair_valid <= 1'b1;
                                stream_count <= 22'd1;
                            end else begin
                                state <= FAIL;
                            end
                        end
                    end
                end

                RECEIVE: begin
                    if (!target_download) begin
                        if ((stream_count == expected_image_bytes) && !pair_valid)
                            rom_loaded <= 1'b1;
                        else
                            rom_loaded <= 1'b0;
                        pair_valid <= 1'b0;
                        state <= IDLE;
                    end else if (ioctl_wr) begin
                        if ((stream_count >= expected_image_bytes) ||
                            (ioctl_addr != {5'd0, stream_count})) begin
                            pair_valid <= 1'b0;
                            rom_loaded <= 1'b0;
                            state <= FAIL;
                        end else if (stream_count < GRAPHICS_BYTES) begin
                            if (!stream_count[0] && !pair_valid) begin
                                pair_high <= ioctl_dout;
                                pair_valid <= 1'b1;
                                stream_count <= stream_count + 1'b1;
                            end else if (stream_count[0] && pair_valid) begin
                                load_addr <= physical_word_address(stream_count - 1'b1,bandit);
                                load_data <= {pair_high, ioctl_dout};
                                load_mask <= 2'b00;
                                load_req <= 1'b1;
                                stream_count <= stream_count + 1'b1;
                                pair_valid <= 1'b0;
                                state <= LOAD_WAIT;
                            end else begin
                                pair_valid <= 1'b0;
                                rom_loaded <= 1'b0;
                                state <= FAIL;
                            end
                        end else if (!pair_valid) begin
                            if (stream_count < 22'h0270000) begin
                                audio_load_region <= 2'd0;
                                audio_load_addr <= stream_count[17:0] - 18'h20000;
                            end else if (stream_count < 22'h0290000) begin
                                audio_load_region <= 2'd1;
                                audio_load_addr <= stream_count[17:0] - 18'h30000;
                            end else begin
                                audio_load_region <= 2'd2;
                                audio_load_addr <= stream_count[17:0] - 18'h10000;
                            end
                            if(stream_count < BANDIT_MCU_BASE) begin
                                audio_load_data <= ioctl_dout;
                                audio_load_we <= 1'b1;
                            end else if(bandit) begin
                                mcu_rom_data <= ioctl_dout;
                                mcu_rom_addr <= stream_count[11:0];
                                mcu_rom_we <= 1'b1;
                            end else begin
                                state <= FAIL;
                                rom_loaded <= 1'b0;
                            end
                            stream_count <= stream_count + 1'b1;
                        end else begin
                            pair_valid <= 1'b0;
                            rom_loaded <= 1'b0;
                            state <= FAIL;
                        end
                    end
                end

                LOAD_WAIT: begin
                    if (!target_download)
                        transfer_end_pending <= 1'b1;
                    if (load_ok) begin
                        load_req <= 1'b0;
                        state <= LOAD_DRAIN;
                    end
                end

                LOAD_DRAIN: begin
                    load_req <= 1'b0;
                    if (!target_download)
                        transfer_end_pending <= 1'b1;
                    if (!load_ok) begin
                        if (transfer_end_pending || !target_download) begin
                            if ((stream_count == expected_image_bytes) && !pair_valid)
                                rom_loaded <= 1'b1;
                            else
                                rom_loaded <= 1'b0;
                            transfer_end_pending <= 1'b0;
                            state <= IDLE;
                        end else begin
                            state <= RECEIVE;
                        end
                    end
                end

                FAIL: begin
                    load_req <= 1'b0;
                    rom_loaded <= 1'b0;
                    if (!target_download) begin
                        pair_valid <= 1'b0;
                        transfer_end_pending <= 1'b0;
                        state <= IDLE;
                    end
                end

                default: begin
                    state <= IDLE;
                    load_req <= 1'b0;
                    pair_valid <= 1'b0;
                    rom_loaded <= 1'b0;
                end
            endcase
        end
    end
endmodule
