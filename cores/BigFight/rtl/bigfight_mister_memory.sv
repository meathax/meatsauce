// SPDX-License-Identifier: GPL-3.0-only
// MiSTer physical memory and boot sequencer for the shared Big Fight ROM image.
//
// clk_sys (50MHz) owns the HPS ioctl loader, the cold-boot RAM preload, the
// game reset sequence and the single 64-bit ROM backend bridge. clk_mem is
// connected to clk_sys by the top level (2026-10-23): the controller derived
// from the pinned common7 controller (rtl/bigfight_sdram_ctrl.sv) runs at
// 50MHz CL2. The toggle/held-data handshake works unchanged in one clock.
//
// Image: index-0 bytes 0..IMAGE_BYTES-1 form the packed physical image
// (docs/reference/packed_tile_layout.json). The MRA assembles that exact image;
// ioctl WIDE=1 delivers byte addr in [7:0] and addr+1 in [15:8], which is the
// image wide-data order (byte at address+n in bits 8n).
//
// Boot policy reproduces the qualified simulator protocol (game_main.cpp):
// cold_start pulse, load_mode with all eight RAM banks zeroed, 128 big-endian
// vector words per CPU copied from program ROM, then cold_start for 12 clocks
// and CPU reset for 76 clocks. OSD/user reset repeats the same preload.
module bigfight_mister_memory #(
    parameter logic [25:0] IMAGE_BYTES   = 26'h0800000,
    parameter logic [25:0] MASTER_BASE   = 26'h0500000,
    parameter logic [25:0] SLAVE_BASE    = 26'h0700000
) (
    input  logic        clk_sys,
    input  logic        clk_mem,
    input  logic        mem_init,          // PLL not locked; controller power-up only
    input  logic        sys_reset,         // PLL lock synchronized to clk_sys
    input  logic        user_reset,        // OSD/button reset request (level)

    // HPS ioctl (hps_io WIDE=1)
    input  logic        ioctl_download,
    input  logic [15:0] ioctl_index,
    input  logic        ioctl_wr,
    input  logic [26:0] ioctl_addr,
    input  logic [15:0] ioctl_dout,
    output logic        ioctl_wait,

    // Game control
    output logic        game_cold_start,
    output logic        game_reset,
    output logic        game_load_mode,
    output logic        load_valid,
    output logic [2:0]  load_bank,
    output logic [14:0] load_word_address,
    output logic [15:0] load_data,
    input  logic        load_ready,
    output logic        rom_loaded,
    output logic        game_running,

    // Game ROM backend (clk_sys)
    input  logic        rom_reset_i,
    input  logic        backend_req_valid,
    output logic        backend_req_ready,
    input  logic [25:0] backend_req_address,
    output logic        backend_rsp_valid,
    input  logic        backend_rsp_ready,
    output logic [63:0] backend_rsp_data,

    // SDRAM pins
    inout  wire  [15:0] SDRAM_DQ,
    output logic [12:0] SDRAM_A,
    output logic        SDRAM_DQML,
    output logic        SDRAM_DQMH,
    output logic [1:0]  SDRAM_BA,
    output logic        SDRAM_nCS,
    output logic        SDRAM_nWE,
    output logic        SDRAM_nRAS,
    output logic        SDRAM_nCAS,
    output logic        SDRAM_CKE,
    output logic        SDRAM_CLK,

    output logic        protocol_error
);
    // ------------------------------------------------------------------
    // Single held toggle port into controller channel 3.
    // ------------------------------------------------------------------
    logic        chip_req;
    wire         chip_ack;
    logic [26:0] chip_addr;
    logic        chip_rnw;
    logic [15:0] chip_din;
    wire  [63:0] chip_dout;
    wire         chip_busy = chip_req != chip_ack;

    sdram sdram_i (
        .init(mem_init), .clk(clk_mem), .doRefresh(1'b0),
        .SDRAM_DQ, .SDRAM_A, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA, .SDRAM_nCS,
        .SDRAM_nWE, .SDRAM_nRAS, .SDRAM_nCAS, .SDRAM_CKE, .SDRAM_CLK,
        .ch1_addr(27'd0), .ch1_dout(), .ch1_req(1'b0), .ch1_ack(),
        .ch2_addr(27'd0), .ch2_dout(), .ch2_req(1'b0), .ch2_ack(),
        .ch3_addr(chip_addr), .ch3_dout(chip_dout), .ch3_din(chip_din),
        .ch3_be(2'b11), .ch3_req(chip_req), .ch3_rnw(chip_rnw), .ch3_ack(chip_ack),
        .ch4_addr(27'd0), .ch4_dout(), .ch4_req(1'b0), .ch4_ack()
    );

    // ------------------------------------------------------------------
    // Sequencer
    // ------------------------------------------------------------------
    typedef enum logic [3:0] {
        S_IDLE, S_DOWNLOAD, S_DL_DRAIN, S_PRE_COLD, S_ZERO, S_VEC_REQ, S_VEC_WAIT,
        S_VEC_WRITE, S_RELEASE, S_RUN, S_DRAIN
    } state_t;
    state_t state;

    logic [7:0]  release_count;
    logic [3:0]  pre_count;
    logic [2:0]  zero_bank;
    logic [14:0] zero_word;
    logic        vec_cpu;          // 0 master, 1 slave
    logic [4:0]  vec_granule;      // 32 x 8 bytes = 128 words
    logic [1:0]  vec_word;
    logic [63:0] vec_data;
    logic        dl_pending;       // buffered ioctl word not yet acknowledged
    logic        dl_issued;
    logic [25:0] dl_addr;
    logic [15:0] dl_data;
    logic        dl_active_q;
    logic        user_reset_q;

    // Bank sizes in words: main, sub, extra, vram0, vram1, sprite, object, palette.
    function automatic logic [14:0] bank_last(input logic [2:0] bank);
        case (bank)
            3'd0, 3'd1, 3'd3, 3'd4: bank_last = 15'd32767;
            3'd2:                   bank_last = 15'd2047;
            3'd5, 3'd7:             bank_last = 15'd8191;
            default:                bank_last = 15'd255;
        endcase
    endfunction

    wire rom_download = ioctl_download && (ioctl_index[7:0] == 8'd0);

    // Bridge ownership of the chip port.
    logic bridge_pending, bridge_discard, held_valid;
    logic [63:0] held_data;
    wire bridge_complete = bridge_pending && !chip_busy;
    // In S_RUN the sequencer holds game_cold_start/game_load_mode low, so the
    // game's rom_reset_o (their OR) is low too; using the registered state
    // alone keeps the game's reset fanout out of the backend handshake.
    wire bridge_live = (state == S_RUN);
    wire unused_rom_reset = rom_reset_i;

    assign backend_req_ready = bridge_live && !bridge_pending && !held_valid && !chip_busy;
    assign backend_rsp_valid = bridge_live && (held_valid || (bridge_complete && !bridge_discard));
    assign backend_rsp_data  = held_valid ? held_data : chip_dout;

    assign ioctl_wait = dl_pending;

    always_ff @(posedge clk_sys) begin
        if (sys_reset) begin
            state <= S_IDLE;
            chip_req <= chip_ack;     // seeded from the controller's init-time ACK
            chip_addr <= 0; chip_rnw <= 1'b1; chip_din <= 0;
            game_cold_start <= 1'b1; game_reset <= 1'b1; game_load_mode <= 1'b1;
            load_valid <= 1'b0; load_bank <= 0; load_word_address <= 0; load_data <= 0;
            rom_loaded <= 1'b0; game_running <= 1'b0;
            release_count <= 0; pre_count <= 0; zero_bank <= 0; zero_word <= 0;
            vec_cpu <= 0; vec_granule <= 0; vec_word <= 0; vec_data <= 0;
            dl_pending <= 1'b0; dl_issued <= 1'b0; dl_addr <= 0; dl_data <= 0;
            dl_active_q <= 1'b0; user_reset_q <= 1'b0;
            bridge_pending <= 1'b0; bridge_discard <= 1'b0; held_valid <= 1'b0; held_data <= 0;
            protocol_error <= 1'b0;
        end else begin
            dl_active_q <= rom_download;
            user_reset_q <= user_reset;

            // ---------------- bridge ----------------
            if (held_valid && backend_rsp_ready && bridge_live) held_valid <= 1'b0;
            if (!bridge_live) held_valid <= 1'b0;
            if (bridge_pending && !bridge_live) bridge_discard <= 1'b1;
            if (backend_req_valid && backend_req_ready) begin
                if (backend_req_address[2:0] != 0 || backend_req_address >= IMAGE_BYTES)
                    protocol_error <= 1'b1;
                chip_addr <= {1'b0, backend_req_address};
                chip_rnw <= 1'b1;
                chip_req <= ~chip_req;
                bridge_pending <= 1'b1;
                bridge_discard <= 1'b0;
            end
            if (bridge_complete) begin
                bridge_pending <= 1'b0;
                bridge_discard <= 1'b0;
                if (bridge_live && !bridge_discard && !backend_rsp_ready) begin
                    held_valid <= 1'b1;
                    held_data <= chip_dout;
                end
            end

            // ---------------- ioctl capture (any state) ----------------
            // hps_io honours ioctl_wait, so at most one word is buffered.
            if (ioctl_wr && rom_download && ioctl_addr[25:0] < IMAGE_BYTES && ioctl_addr[26] == 1'b0) begin
                if (dl_pending) protocol_error <= 1'b1;
                dl_pending <= 1'b1; dl_issued <= 1'b0;
                dl_addr <= {ioctl_addr[25:1], 1'b0}; dl_data <= ioctl_dout;
            end
            if ((state == S_DOWNLOAD || state == S_DL_DRAIN) && dl_pending) begin
                if (!dl_issued && !chip_busy) begin
                    chip_addr <= {1'b0, dl_addr};
                    chip_din <= dl_data;
                    chip_rnw <= 1'b0;
                    chip_req <= ~chip_req;
                    dl_issued <= 1'b1;
                end else if (dl_issued && !chip_busy) begin
                    dl_pending <= 1'b0; dl_issued <= 1'b0;
                end
            end

            // ---------------- sequencer ----------------
            case (state)
                S_IDLE: begin
                    // No game image yet: hold the machine, keep the raster running.
                    game_cold_start <= 1'b0; game_reset <= 1'b1; game_load_mode <= 1'b1;
                    if (rom_download) state <= S_DOWNLOAD;
                end

                S_DOWNLOAD: begin
                    game_cold_start <= 1'b0; game_reset <= 1'b1; game_load_mode <= 1'b1;
                    load_valid <= 1'b0;
                    if (!rom_download) state <= S_DL_DRAIN;
                end

                S_DL_DRAIN: if (!chip_busy && !dl_pending) begin
                    rom_loaded <= 1'b1;
                    state <= S_PRE_COLD; pre_count <= 0;
                end

                S_DRAIN: begin
                    // Game reset with a possibly accepted read: wait for the
                    // controller reply before the sequencer reuses the port.
                    game_cold_start <= 1'b0; game_reset <= 1'b1; game_load_mode <= 1'b1;
                    if (!chip_busy && !bridge_pending) begin
                        if (rom_download) state <= S_DOWNLOAD;
                        else begin state <= S_PRE_COLD; pre_count <= 0; end
                    end
                end

                S_PRE_COLD: begin
                    // Matches the simulator: 12 cold-start clocks before preload.
                    game_cold_start <= 1'b1; game_reset <= 1'b1; game_load_mode <= 1'b1;
                    pre_count <= pre_count + 4'd1;
                    if (pre_count == 4'd11) begin
                        game_cold_start <= 1'b0;
                        state <= S_ZERO; zero_bank <= 0; zero_word <= 0;
                        load_bank <= 0; load_word_address <= 0; load_data <= 0; load_valid <= 1'b1;
                    end
                end

                S_ZERO: begin
                    // One word per clock while load_ready; load_* are registered.
                    if (load_valid && load_ready) begin
                        if (zero_word == bank_last(zero_bank)) begin
                            zero_word <= 0;
                            if (zero_bank == 3'd7) begin
                                load_valid <= 1'b0;
                                state <= S_VEC_REQ; vec_cpu <= 0; vec_granule <= 0;
                            end else begin
                                zero_bank <= zero_bank + 3'd1;
                                load_bank <= zero_bank + 3'd1;
                                load_word_address <= 0;
                            end
                        end else begin
                            zero_word <= zero_word + 15'd1;
                            load_word_address <= zero_word + 15'd1;
                        end
                    end
                end

                S_VEC_REQ: if (!chip_busy) begin
                    chip_addr <= {1'b0, (vec_cpu ? SLAVE_BASE : MASTER_BASE) + {18'd0, vec_granule, 3'b000}};
                    chip_rnw <= 1'b1;
                    chip_req <= ~chip_req;
                    state <= S_VEC_WAIT;
                end

                S_VEC_WAIT: if (!chip_busy) begin
                    vec_data <= chip_dout;
                    vec_word <= 0;
                    state <= S_VEC_WRITE;
                end

                S_VEC_WRITE: begin
                    // CPU word = {byte[2w], byte[2w+1]} (big-endian program ROM).
                    load_valid <= 1'b1;
                    load_bank <= {2'b00, vec_cpu};
                    load_word_address <= {8'd0, vec_granule, vec_word};
                    load_data <= {vec_data[16*vec_word +: 8], vec_data[16*vec_word+8 +: 8]};
                    if (load_valid && load_ready) begin
                        if (vec_word == 2'd3) begin
                            load_valid <= 1'b0;
                            if (vec_granule == 5'd31) begin
                                if (vec_cpu) begin
                                    state <= S_RELEASE; release_count <= 0;
                                end else begin
                                    vec_cpu <= 1'b1; vec_granule <= 0; state <= S_VEC_REQ;
                                end
                            end else begin
                                vec_granule <= vec_granule + 5'd1; state <= S_VEC_REQ;
                            end
                        end else begin
                            vec_word <= vec_word + 2'd1;
                            load_word_address <= {8'd0, vec_granule, vec_word + 2'd1};
                            load_data <= {vec_data[16*(vec_word+1) +: 8], vec_data[16*(vec_word+1)+8 +: 8]};
                        end
                    end
                end

                S_RELEASE: begin
                    // Simulator cycles 1..12 cold_start, 1..76 CPU reset.
                    game_load_mode <= 1'b0;
                    load_valid <= 1'b0;
                    release_count <= release_count + 8'd1;
                    game_cold_start <= release_count < 8'd12;
                    game_reset <= release_count < 8'd76;
                    if (release_count == 8'd76) begin
                        game_reset <= 1'b0; game_cold_start <= 1'b0;
                        game_running <= 1'b1; state <= S_RUN;
                    end
                end

                S_RUN: begin
                    if (rom_download || (user_reset && !user_reset_q)) begin
                        game_running <= 1'b0;
                        game_reset <= 1'b1; game_load_mode <= 1'b1;
                        state <= S_DRAIN;
                    end
                end

                default: state <= S_IDLE;
            endcase

            // A held user reset keeps the machine in preload until released.
            if (state == S_RELEASE && user_reset) release_count <= 0;
        end
    end
endmodule
