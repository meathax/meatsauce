// SPDX-License-Identifier: GPL-3.0-or-later
// Index 0 is a contiguous normalized image, including zero alignment padding.
// reset is a storage cold reset. Game soft reset must not reset this module.
module argus_rom_store (
    input  logic clk_sys, reset,
    input  logic [1:0] game_id,
    input  logic ioctl_download, ioctl_wr,
    input  logic [15:0] ioctl_index,
    input  logic [24:0] ioctl_addr,
    input  logic [7:0] ioctl_dout,
    output logic ioctl_wait, load_ready, bounds_error,
    input  logic main_req,
    input  logic [23:0] main_addr,
    output logic main_ready,
    output logic [7:0] main_rdata,
    input  logic video_req,
    input  logic [23:0] video_addr,
    output logic video_ready,
    output logic [63:0] video_rdata,
    input  logic sound_req,
    input  logic [23:0] sound_addr,
    output logic sound_ready,
    output logic [7:0] sound_rdata,
    input  logic mem_init_ready,
    output logic mem_req, mem_we, mem_read_wide,
    output logic [23:0] mem_addr,
    output logic [7:0] mem_wdata,
    input  logic mem_ready,
    input  logic [7:0] mem_rdata,
    input  logic [63:0] mem_rdata64
);
    import argus_rom_layout_pkg::*;
    logic download_d, loading, load_fault, image_valid, busy;
    logic [1:0] loaded_game, owner, next_client;
    logic [24:0] next_byte;
    logic [2:0] client_req, client_active;
    logic [23:0] client_addr [0:2];
    logic [23:0] owner_addr;
    logic [2:0] cache_valid, cache_hit;
    logic [20:0] cache_tag [0:2];
    logic [63:0] cache_data [0:2];
    logic [1:0] choice;
    logic have_choice;
    wire rom_download = ioctl_download && ioctl_index == 16'd0;
    wire start_load = rom_download && !download_d;
    wire [24:0] image_end = rom_image_end(game_id);

    always_comb begin
        load_ready = image_valid && mem_init_ready && !rom_download && loaded_game == game_id;
        ioctl_wait = (ioctl_index == 16'd0) && (!mem_init_ready || busy);
        client_active = {sound_req, video_req, main_req};
        client_req = client_active & ~{sound_ready, video_ready, main_ready};
        client_addr[0] = main_addr;
        client_addr[1] = video_addr;
        client_addr[2] = sound_addr;
        for (int c = 0; c < 3; c = c + 1) begin
            cache_hit[c] = cache_valid[c] && cache_tag[c] == client_addr[c][23:3];
            // Cache hits on another client may complete during a physical miss.
            // The current physical owner is never accepted a second time.
            if ((busy && owner == 2'(c)) || (busy && !mem_ready && !cache_hit[c])) client_req[c] = 1'b0;
        end
        choice = next_client;
        have_choice = 1'b0;
        case (next_client)
            2'd0: begin
                if (client_req[0]) begin choice = 2'd0; have_choice = 1'b1; end
                else if (client_req[1]) begin choice = 2'd1; have_choice = 1'b1; end
                else if (client_req[2]) begin choice = 2'd2; have_choice = 1'b1; end
            end
            2'd1: begin
                if (client_req[1]) begin choice = 2'd1; have_choice = 1'b1; end
                else if (client_req[2]) begin choice = 2'd2; have_choice = 1'b1; end
                else if (client_req[0]) begin choice = 2'd0; have_choice = 1'b1; end
            end
            default: begin
                if (client_req[2]) begin choice = 2'd2; have_choice = 1'b1; end
                else if (client_req[0]) begin choice = 2'd0; have_choice = 1'b1; end
                else if (client_req[1]) begin choice = 2'd1; have_choice = 1'b1; end
            end
        endcase
    end

    task automatic reply(input logic [1:0] client, input logic [63:0] data, input logic [2:0] lane);
        case (client)
            2'd0: begin main_ready <= 1'b1; main_rdata <= data[{lane,3'b000} +: 8]; end
            2'd1: begin video_ready <= 1'b1; video_rdata <= data; end
            2'd2: begin sound_ready <= 1'b1; sound_rdata <= data[{lane,3'b000} +: 8]; end
            default: ;
        endcase
    endtask

    always_ff @(posedge clk_sys) begin
        main_ready <= 1'b0;
        video_ready <= 1'b0;
        sound_ready <= 1'b0;
        if (reset) begin
            download_d <= 1'b0;
            loading <= 1'b0;
            load_fault <= 1'b0;
            image_valid <= 1'b0;
            bounds_error <= 1'b0;
            loaded_game <= game_id;
            next_byte <= 25'd0;
            busy <= 1'b0;
            owner <= 2'd0;
            owner_addr <= 24'd0;
            cache_valid <= 3'd0;
            for (int c = 0; c < 3; c = c + 1) begin
                cache_tag[c] <= 21'd0;
                cache_data[c] <= 64'd0;
            end
            next_client <= 2'd0;
            mem_req <= 1'b0;
            mem_we <= 1'b0;
            mem_read_wide <= 1'b0;
            mem_addr <= 24'd0;
            mem_wdata <= 8'd0;
            main_rdata <= 8'hff;
            video_rdata <= 64'hffffffffffffffff;
            sound_rdata <= 8'hff;
        end else begin
            download_d <= rom_download;
            if (!mem_init_ready || loaded_game != game_id) begin
                image_valid <= 1'b0;
                cache_valid <= 3'd0;
            end
            if (rom_download && !start_load && loaded_game != game_id) begin
                load_fault <= 1'b1;
                bounds_error <= 1'b1;
            end
            if (start_load) begin
                loaded_game <= game_id;
                image_valid <= 1'b0;
                loading <= 1'b1;
                next_byte <= 25'd0;
                load_fault <= (image_end == 25'd0);
                bounds_error <= (image_end == 25'd0);
                next_client <= 2'd0;
                cache_valid <= 3'd0;
            end
            if (busy && mem_ready) begin
                busy <= 1'b0;
                mem_req <= 1'b0;
                // A client reset may abandon a read. Drain its physical
                // transaction, but never deliver the stale byte to a new address.
                if (!mem_we && load_ready) begin
                    cache_valid[owner] <= 1'b1;
                    cache_tag[owner] <= owner_addr[23:3];
                    cache_data[owner] <= mem_rdata64;
                    if (client_active[owner] && client_addr[owner] == owner_addr)
                        reply(owner, mem_rdata64, owner_addr[2:0]);
                end
            end
            // End-of-download waits for the final physical write to complete.
            if (!rom_download && loading && !busy) begin
                loading <= 1'b0;
                if (!load_fault && next_byte == image_end && loaded_game == game_id && mem_init_ready)
                    image_valid <= 1'b1;
                else begin
                    image_valid <= 1'b0;
                    bounds_error <= 1'b1;
                end
            end
            if (rom_download && ioctl_wr && !ioctl_wait) begin
                if (image_end == 25'd0 || ioctl_addr >= image_end ||
                    ioctl_addr != (start_load ? 25'd0 : next_byte) ||
                    (!start_load && (load_fault || loaded_game != game_id))) begin
                    load_fault <= 1'b1;
                    bounds_error <= 1'b1;
                end else begin
                    mem_req <= 1'b1;
                    mem_we <= 1'b1;
                    mem_read_wide <= 1'b0;
                    mem_addr <= ioctl_addr[23:0];
                    mem_wdata <= ioctl_dout;
                    busy <= 1'b1;
                    next_byte <= ioctl_addr + 25'd1;
                    cache_valid <= 3'd0;
                end
            end else if (load_ready && have_choice) begin
                next_client <= (choice == 2'd2) ? 2'd0 : choice + 2'd1;
                if ({1'b0, client_addr[choice]} >= image_end ||
                    (choice == 2'd1 && (client_addr[choice][2:0] != 3'd0 ||
                     {1'b0,client_addr[choice]} + 25'd8 > image_end))) begin
                    bounds_error <= 1'b1;
                    reply(choice, 64'hffffffffffffffff, client_addr[choice][2:0]);
                end else if (cache_hit[choice]) begin
                    reply(choice, cache_data[choice], client_addr[choice][2:0]);
                end else if (!busy || mem_ready) begin
                    mem_req <= 1'b1;
                    mem_we <= 1'b0;
                    mem_read_wide <= 1'b1;
                    mem_addr <= {client_addr[choice][23:3],3'd0};
                    mem_wdata <= 8'd0;
                    owner <= choice;
                    owner_addr <= client_addr[choice];
                    busy <= 1'b1;
                end
            end
        end
    end
endmodule
