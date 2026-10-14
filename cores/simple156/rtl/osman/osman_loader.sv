// SPDX-License-Identifier: GPL-3.0-or-later
// Explicit ready/valid original-ROM transport. See docs/ROM_LOADER.md.
module osman_loader (
    input wire clk, reset, start, finish,
    input wire in_valid,
    output wire in_ready,
    input wire [23:0] in_addr,
    input wire [15:0] in_data,
    output reg mem_valid,
    input wire mem_ready, mem_error,
    output reg [23:0] mem_addr,
    output reg [15:0] mem_data,
    output reg [1:0] mem_be,
    output reg eeprom_load_en,
    output reg [5:0] eeprom_load_addr,
    output reg [15:0] eeprom_load_data,
    output reg [7:0] profile,
    output reg image_ready, error,
    output reg [23:0] accepted_words, memory_writes
);
    localparam [23:0] HEADER = 24'h000010;
    localparam [23:0] TILES = 24'h080000, SPRITES = 24'h280000;
    localparam [23:0] SFX = 24'ha80000, MUSIC = 24'hac0000, EEPROM = 24'hcc0000;
    // Schema-1 payloads are contiguous; physical banks retain the OSMAN layout.
    // IDs 0/1: OSMAN/Cannon; 2: Joe & Mac Returns; 3: Charlie Ninja.
    wire [23:0] payload_sprites = profile == 8'd2 ? 24'h180000 : SPRITES;
    wire [23:0] payload_sfx = profile == 8'd2 ? 24'h280000 :
                                 profile == 8'd3 ? 24'h480000 : SFX;
    wire [23:0] payload_music = payload_sfx + 24'h040000;
    wire [23:0] payload_eeprom = payload_music + 24'h200000;
    wire [23:0] stream_end = payload_eeprom + HEADER + 24'h80;
    reg active, finish_pending, second_pending, low_pending;
    reg [23:0] expected_addr, second_addr;
    reg [15:0] second_data, raw_low;
    reg [1:0] second_be;
    reg [16:0] raw_low_index;
    wire [23:0] rel = in_addr - HEADER;
    wire [16:0] cpu_dest;
    wire [31:0] cpu_data;
    deco156_word u_cpu_decrypt (
        .physical_word_addr(rel[18:2]), .raw_data({in_data,raw_low}),
        .logical_word_addr(cpu_dest), .decrypted_data(cpu_data)
    );
    wire [23:0] tile_rel = rel - TILES;
    wire [19:0] tile_contiguous_dest;
    // One set of crypto tables serves both raw quarter layouts. Joe's tiles
    // are contiguous; OSMAN/Cannon/Charlie use ROM_CONTINUE quarter order 0,2,1,3.
    wire [19:0] tile_dest = profile == 8'd2 ? tile_contiguous_dest :
        {tile_contiguous_dest[18],tile_contiguous_dest[19],tile_contiguous_dest[17:0]};
    wire [15:0] tile_data;
    deco56_word #(.MCF_QUARTER_SWAP(0)) u_tile_decrypt (
        .physical_word_addr(tile_rel[20:1]), .raw_data(in_data),
        .logical_word_addr(tile_contiguous_dest), .decrypted_data(tile_data)
    );
    // Graphics ROMs are stored so that one 8-byte SDRAM group holds everything
    // a renderer needs per fetch (see osman_memory): tiles {code8,row[2:1]} ->
    // {row[0],plane}; sprites {code,row} -> {second half,plane}.
    wire [19:0] tile_laid = profile == 8'd2 ? {1'b0,tile_dest[17:1],tile_dest[0],tile_dest[18]}
                                            : {tile_dest[18:1],tile_dest[0],tile_dest[19]};
    wire [23:0] sprite_rel = rel - payload_sprites;
    wire [21:0] sprite_word = sprite_rel[22:1];
    wire [21:0] sprite_laid = profile == 8'd2 ? {3'd0,sprite_word[17:5],sprite_word[3:0],~sprite_word[4],sprite_word[18]} :
                              profile == 8'd3 ? {2'd0,sprite_word[18:5],sprite_word[3:0],~sprite_word[4],sprite_word[19]} :
                                                {sprite_word[20:5],sprite_word[3:0],~sprite_word[4],sprite_word[21]};
    wire [23:0] music_rel = rel - payload_music;
    wire [23:0] eeprom_rel = rel - payload_eeprom;
    wire [19:0] music_byte = music_rel[20:1];
    assign in_ready = active && !error && !finish_pending && !mem_valid && !second_pending;
    always @(posedge clk) begin
        eeprom_load_en <= 0;
        if (reset || start) begin
            active <= !reset && start;
            image_ready <= 0; error <= 0; profile <= 0;
            expected_addr <= 0; accepted_words <= 0; memory_writes <= 0;
            mem_valid <= 0; mem_addr <= 0; mem_data <= 0; mem_be <= 0;
            second_pending <= 0; second_addr <= 0; second_data <= 0; second_be <= 0;
            raw_low <= 0; raw_low_index <= 0; low_pending <= 0;
            finish_pending <= 0;
            eeprom_load_addr <= 0; eeprom_load_data <= 0;
        end else if(mem_error) begin
            // Verification failure is not a completed image write. Abort all
            // pending halves/EOF and retain the error until a fresh start.
            active<=0;image_ready<=0;error<=1;mem_valid<=0;
            second_pending<=0;finish_pending<=0;low_pending<=0;
        end else begin
            if (finish && active) finish_pending <= 1;
            if (mem_valid && mem_ready) begin
                memory_writes <= memory_writes + 1'b1;
                if (second_pending) begin
                    mem_addr <= second_addr; mem_data <= second_data; mem_be <= second_be;
                    second_pending <= 0;
                end else mem_valid <= 0;
            end
            if (in_valid && in_ready) begin
                if (in_addr != expected_addr || in_addr[0] || in_addr >= stream_end) begin
                    error <= 1; active <= 0;
                end else begin
                    accepted_words <= accepted_words + 1'b1;
                    expected_addr <= expected_addr + 24'd2;
                    if (in_addr < HEADER) begin
                        case (in_addr[3:1])
                            0: if (in_data != 16'h3153) error <= 1;
                            1: if (in_data != 16'h3635) error <= 1;
                            2: if (in_data != 1) error <= 1;
                            3: begin profile <= in_data[7:0]; if (in_data > 3) error <= 1; end
                            default: if (in_data != 0) error <= 1;
                        endcase
                    end else if (rel < TILES) begin
                        if (!rel[1]) begin
                            raw_low <= in_data; raw_low_index <= rel[18:2]; low_pending <= 1;
                        end else if (!low_pending || raw_low_index != rel[18:2]) begin
                            error <= 1; active <= 0;
                        end else begin
                            mem_valid <= 1; mem_addr <= {5'd0,cpu_dest,2'b00};
                            mem_data <= cpu_data[15:0]; mem_be <= 2'b11;
                            second_pending <= 1; second_addr <= {5'd0,cpu_dest,2'b10};
                            second_data <= cpu_data[31:16]; second_be <= 2'b11; low_pending <= 0;
                        end
                    end else if (rel < payload_sprites) begin
                        mem_valid <= 1; mem_addr <= TILES + {3'd0,tile_laid,1'b0};
                        mem_data <= tile_data; mem_be <= 2'b11;
                    end else if (rel < payload_sfx) begin
                        mem_valid <= 1; mem_addr <= SPRITES + {1'b0,sprite_laid,sprite_rel[0]};
                        mem_data <= in_data; mem_be <= 2'b11;
                    end else if (rel < payload_music) begin
                        mem_valid <= 1; mem_addr <= SFX + (rel - payload_sfx);
                        mem_data <= in_data; mem_be <= 2'b11;
                    end else if (rel < payload_eeprom) begin
                        // Music ROM in byte mode: A0 moves to A20. Two byte writes
                        // retain both original lanes without fetching neighboring data.
                        mem_valid <= 1; mem_addr <= MUSIC + {4'd0,music_byte[19:1],1'b0};
                        mem_data <= music_byte[0] ? {in_data[7:0],8'd0} : {8'd0,in_data[7:0]};
                        mem_be <= music_byte[0] ? 2'b10 : 2'b01;
                        second_pending <= 1;
                        second_addr <= MUSIC + 24'h100000 + {4'd0,music_byte[19:1],1'b0};
                        second_data <= music_byte[0] ? {in_data[15:8],8'd0} : {8'd0,in_data[15:8]};
                        second_be <= music_byte[0] ? 2'b10 : 2'b01;
                    end else begin
                        eeprom_load_en <= 1;
                        eeprom_load_addr <= eeprom_rel[6:1];
                        eeprom_load_data <= {in_data[7:0],in_data[15:8]};
                    end
                end
            end
            // A region boundary never borrows the next input strobe. Finish is
            // retained while the last memory word drains, including CPU high half.
            if (finish_pending && !mem_valid && !second_pending) begin
                active <= 0; finish_pending <= 0;
                if (!error && expected_addr == stream_end && !low_pending) image_ready <= 1;
                else error <= 1;
            end
        end
    end
endmodule
