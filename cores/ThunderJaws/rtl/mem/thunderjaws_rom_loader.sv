// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ThunderJaws MiSTer contributors
// Router structure adapted from Arcade-Batman_MiSTer commit
// 34783858f6e1511e299ef159d6316544934f8fb5 (GPL-3.0-or-later), specifically
// rtl/mem/batman_rom_loader.sv and batman_sdram_loader.sv. The byte-to-word
// transport uses ThunderJaws' held-valid/ready/response contract.
`timescale 1ns/1ps

module thunderjaws_rom_loader (
    input  logic        clk,
    input  logic        reset,                 // global init, shared with the SDRAM transport

    input  logic        ioctl_download,
    input  logic        ioctl_wr,
    input  logic [26:0] ioctl_addr,             // byte offset in the index-0 raw stream
    input  logic [7:0]  ioctl_dout,
    input  logic [15:0] ioctl_index,
    output logic        ioctl_wait,

    output logic        write_valid,
    output logic [23:0] write_address,          // SDRAM word address
    output logic [15:0] write_data,
    input  logic        write_ready,            // one acceptance pulse per descriptor
    input  logic        write_response_valid,    // physical write is committed

    output logic        char_wr,
    output logic [15:0] char_addr,
    output logic [7:0]  char_data,
    output logic        sound_wr,
    output logic [15:0] sound_addr,
    output logic [7:0]  sound_data,

    output logic        rom_loaded,
    output logic        load_error,
    output logic        busy
);

    localparam logic [26:0] STREAM_BYTES       = 27'h0380000;
    localparam logic [25:0] SDRAM_WORDS        = 26'h01b0000;
    localparam logic [26:0] MAIN_END           = 27'h00a0000;
    localparam logic [26:0] EXTRA_END          = 27'h0120000;
    localparam logic [26:0] TILES_BASE         = 27'h0120000;
    localparam logic [26:0] TILES_END          = 27'h0220000;
    localparam logic [26:0] SPRITES_BASE       = 27'h0220000;
    localparam logic [26:0] SPRITES_END        = 27'h0320000;
    localparam logic [26:0] CHARS_BASE         = 27'h0320000;
    localparam logic [26:0] CHARS_END          = 27'h0330000;
    localparam logic [26:0] SOUND_BASE         = 27'h0330000;
    localparam logic [26:0] SOUND_END          = 27'h0340000;

    typedef enum logic [1:0] { S_WAIT, S_STREAM, S_DRAIN, S_DONE } session_state_t;
    typedef enum logic [1:0] { W_IDLE, W_OFFER, W_RESPONSE } write_state_t;

    session_state_t session_state;
    write_state_t   write_state;

    logic [26:0] bytes_seen;
    logic [25:0] committed_words;
    logic        transfer_bad;
    logic        have_even;
    logic [7:0]  even_data;
    logic [23:0] even_word_address;

    wire download0 = ioctl_download && (ioctl_index == 16'd0);
    wire start_now = (session_state == S_WAIT) && download0 &&
                     (write_state == W_IDLE) && !reset;
    wire session_can_take = (session_state == S_STREAM) || start_now;

    assign write_valid = (write_state == W_OFFER);
    assign ioctl_wait = download0 &&
                        (reset || (write_state != W_IDLE) ||
                         (session_state == S_DRAIN) || (session_state == S_DONE));
    wire take_byte = session_can_take && download0 && ioctl_wr &&
                     !ioctl_wait && !reset;
    wire byte_order_ok = (ioctl_addr < STREAM_BYTES) &&
                         (ioctl_addr == (start_now ? 27'd0 : bytes_seen));

    wire is_tiles  = (ioctl_addr >= TILES_BASE)   && (ioctl_addr < TILES_END);
    wire is_sprites= (ioctl_addr >= SPRITES_BASE) && (ioctl_addr < SPRITES_END);
    wire is_chars  = (ioctl_addr >= CHARS_BASE)   && (ioctl_addr < CHARS_END);
    wire is_sound  = (ioctl_addr >= SOUND_BASE)   && (ioctl_addr < SOUND_END);
    wire is_local  = is_chars || is_sound;
    wire is_gfx    = is_tiles || is_sprites;

    logic [19:0] gfx_relative;
    logic [1:0]  gfx_plane;
    logic [14:0] gfx_code;
    logic [2:0]  gfx_row;
    logic [19:0] gfx_scattered;
    logic [23:0] mapped_byte_address;
    logic [23:0] mapped_word_address;
    logic [7:0]  mapped_byte_data;

    always_comb begin
        gfx_relative      = 20'd0;
        gfx_plane         = 2'd0;
        gfx_code          = 15'd0;
        gfx_row           = 3'd0;
        gfx_scattered     = 20'd0;
        mapped_byte_address = ioctl_addr[23:0];
        mapped_byte_data  = ioctl_dout;

        if (is_gfx) begin
            // Source is plane-major. Destination groups a row pair from all
            // four planes into eight consecutive bytes, in donor decoder order.
            gfx_relative = ioctl_addr[19:0] - 20'h20000;
            gfx_plane    = gfx_relative[19:18];
            gfx_code     = gfx_relative[17:3];
            gfx_row      = gfx_relative[2:0];
            gfx_scattered = {gfx_code, gfx_row[2:1], ~gfx_plane, gfx_row[0]};
            if (is_tiles)
                mapped_byte_address = 24'h120000 + {4'd0, gfx_scattered};
            else
                mapped_byte_address = 24'h220000 + {4'd0, gfx_scattered};
            mapped_byte_data = ~ioctl_dout;
        end

        mapped_word_address = {1'b0, mapped_byte_address[23:1]};
    end

    wire [23:0] current_even_word = start_now ? 24'd0 : even_word_address;
    wire current_have_even = start_now ? 1'b0 : have_even;
    wire byte_pair_error = take_byte && byte_order_ok && !transfer_bad &&
        ((is_local && current_have_even) ||
         (!is_local && ((mapped_byte_address[0] != ioctl_addr[0]) ||
          (ioctl_addr[0] ?
              (!current_have_even || (mapped_word_address != current_even_word)) :
              current_have_even))));
    wire take_valid_byte = take_byte && byte_order_ok &&
                           (!transfer_bad || start_now) && !byte_pair_error;

    assign busy = start_now || (session_state == S_STREAM) ||
                  (session_state == S_DRAIN) || (write_state != W_IDLE);

    always_ff @(posedge clk) begin
        if (reset) begin
            session_state <= S_WAIT;
            bytes_seen    <= 27'd0;
            transfer_bad  <= 1'b0;
            rom_loaded    <= 1'b0;
            load_error    <= 1'b0;
        end else begin
            if (start_now) begin
                session_state <= S_STREAM;
                bytes_seen    <= 27'd0;
                transfer_bad  <= 1'b0;
                rom_loaded    <= 1'b0;
                load_error    <= 1'b0;
            end else begin
                case (session_state)
                    S_WAIT: begin end
                    S_STREAM: begin
                        if (!download0) begin
                            session_state <= S_DRAIN;
                            if (bytes_seen != STREAM_BYTES)
                                transfer_bad <= 1'b1;
                        end
                    end
                    S_DRAIN: begin
                        if (write_state == W_IDLE) begin
                            if (!transfer_bad && (bytes_seen == STREAM_BYTES) &&
                                !have_even && (committed_words == SDRAM_WORDS)) begin
                                rom_loaded    <= 1'b1;
                                session_state <= S_DONE;
                            end else begin
                                load_error    <= 1'b1;
                                session_state <= S_WAIT;
                            end
                        end
                    end
                    S_DONE: begin
                        if (download0)
                            session_state <= S_WAIT;
                    end
                    default: session_state <= S_WAIT;
                endcase
            end

            if (take_byte) begin
                if (!byte_order_ok || byte_pair_error) begin
                    transfer_bad <= 1'b1;
                end else if (!transfer_bad || start_now) begin
                    bytes_seen <= (start_now ? 27'd1 : bytes_seen + 27'd1);
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            write_state       <= W_IDLE;
            write_address     <= 24'd0;
            write_data        <= 16'd0;
            committed_words   <= 26'd0;
            have_even         <= 1'b0;
            even_data         <= 8'd0;
            even_word_address <= 24'd0;
            char_wr           <= 1'b0;
            char_addr         <= 16'd0;
            char_data         <= 8'd0;
            sound_wr          <= 1'b0;
            sound_addr        <= 16'd0;
            sound_data        <= 8'd0;
        end else begin
            char_wr  <= 1'b0;
            sound_wr <= 1'b0;

            if (start_now) begin
                committed_words <= 26'd0;
                have_even       <= 1'b0;
            end

            case (write_state)
                W_IDLE: begin end
                W_OFFER: begin
                    if (write_ready) begin
                        write_state <= W_RESPONSE;
                    end else if ((session_state == S_DRAIN) &&
                                 ((bytes_seen != STREAM_BYTES) || transfer_bad)) begin
                        // An aborted, not-yet-accepted word has no memory owner.
                        write_state <= W_IDLE;
                        have_even   <= 1'b0;
                    end
                end
                W_RESPONSE: begin
                    if (write_response_valid) begin
                        write_state     <= W_IDLE;
                        committed_words <= committed_words + 26'd1;
                    end
                end
                default: write_state <= W_IDLE;
            endcase

            if (session_state == S_DRAIN && (bytes_seen != STREAM_BYTES))
                have_even <= 1'b0;

            if (take_valid_byte) begin
                if (is_chars) begin
                    char_wr   <= 1'b1;
                    char_addr <= ioctl_addr[15:0];
                    char_data <= ioctl_dout;
                end else if (is_sound) begin
                    sound_wr   <= 1'b1;
                    sound_addr <= ioctl_addr[15:0];
                    sound_data <= ioctl_dout;
                end else if (!ioctl_addr[0]) begin
                    even_data         <= mapped_byte_data;
                    even_word_address <= mapped_word_address;
                    have_even         <= 1'b1;
                end else begin
                    write_address <= even_word_address;
                    write_data    <= {even_data, mapped_byte_data};
                    write_state   <= W_OFFER;
                    have_even     <= 1'b0;
                end
            end
        end
    end

endmodule
