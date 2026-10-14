// SPDX-License-Identifier: GPL-3.0-or-later
// Board-visible behaviour follows MAME 0.289 simpl156.cpp (BSD-3-Clause).
module osman_bus (
    input logic clk, reset,
    input logic [7:0] profile,
    input logic cpu_req, cpu_we,
    input logic [25:0] cpu_addr,
    input logic [3:0] cpu_be,
    input logic [31:0] cpu_wdata,
    output logic cpu_ready,
    output logic [31:0] cpu_rdata,
    output logic rom_req,
    output logic [16:0] rom_word_addr,
    input logic rom_ready,
    input logic [31:0] rom_rdata,
    input logic [15:0] inputs_0, inputs_1,
    input logic vblank, eeprom_do,
    output logic eeprom_cs, eeprom_sk, eeprom_di,
    output logic [2:0] music_bank,
    input logic [7:0] oki_sfx_status, oki_music_status,
    output logic oki_sfx_wr, oki_music_wr,
    output logic [7:0] oki_data,
    input logic [25:0] state_addr,
    output logic [31:0] state_data,
    input logic score_req, score_we, score_paused,
    input logic [25:0] score_addr,
    input logic [7:0] score_wdata,
    output logic score_valid,
    output logic [7:0] score_rdata,
    input logic video_req,
    input logic [25:0] video_addr,
    output logic video_valid,
    output logic [31:0] video_data,
    output logic commit_valid, commit_we,
    output logic [25:0] commit_addr,
    output logic [3:0] commit_be,
    output logic [31:0] commit_data,
    output logic [31:0] write_count, unmapped_count
);
    // Canonical decoder addresses retain the reviewed Mitchell map. Joe & Mac
    // relocates the common window by -0x80000 and both OKI ports independently.
    // Tuple capture/commit addresses remain the actual CPU-visible addresses.
    function automatic logic [25:0] canonical_address(input logic [25:0] address);
        canonical_address = address;
        if (profile == 8'd2) begin
            if (address[25:19] == 7'd2) canonical_address = address + 26'h080000;
            else if (address == 26'h180000) canonical_address = 26'h100000;
            else if (address == 26'h1c0000) canonical_address = 26'h140000;
            else if (address[25:19] == 7'd3) canonical_address = 26'h3ffffff;
        end
    endfunction
    wire [25:0] decoded_cpu_addr = canonical_address(cpu_addr);
    wire [25:0] decoded_score_addr = canonical_address(score_addr);
    wire [25:0] decoded_state_addr = canonical_address(state_addr);
    wire [25:0] decoded_video_addr = canonical_address(video_addr);
    // EEPROM/vblank replace these input bits; score indexing uses the raw
    // address below. Retain the complete interfaces without unused-bit noise.
    wire unused_bus_interface_bits = &{1'b0, inputs_0[8:7], decoded_score_addr[14:0]};
    typedef enum logic [1:0] { IDLE, ROM_WAIT, RESPONSE, RAM_WAIT } bus_state_t;
    bus_state_t state;
    logic [25:0] held_addr;
    logic [25:0] held_ram_addr;
    logic held_we;
    logic [3:0] held_be;
    logic [31:0] held_wdata;
    // Immutable program-ROM L0: one aligned dword per direct-mapped entry.
    // Only genuine downstream completions fill; reset invalidates the image.
    logic [31:0] rom_l0_data [0:31];
    logic [11:0] rom_l0_tag [0:31];
    logic [31:0] rom_l0_valid;
    wire [4:0] rom_l0_index = cpu_addr[6:2];
    wire rom_l0_hit = rom_l0_valid[rom_l0_index]
        && rom_l0_tag[rom_l0_index] == cpu_addr[18:7];
    wire same_request = cpu_req && cpu_addr == held_addr && cpu_we == held_we
        && cpu_be == held_be && (!cpu_we || cpu_wdata == held_wdata);
    (* ramstyle="M10K" *) logic [7:0] systemram_b0 [0:1023], systemram_b1 [0:1023], systemram_b2 [0:1023], systemram_b3 [0:1023];
    (* ramstyle="M10K" *) logic [7:0] mainram_b0 [0:8191], mainram_b1 [0:8191];
    (* ramstyle="M10K" *) logic [7:0] spriteram_b0 [0:2047], spriteram_b1 [0:2047];
    (* ramstyle="M10K" *) logic [7:0] palette_b0 [0:1023], palette_b1 [0:1023];
    (* ramstyle="M10K" *) logic [7:0] pf1_b0 [0:2047], pf1_b1 [0:2047];
    (* ramstyle="M10K" *) logic [7:0] pf2_b0 [0:2047], pf2_b1 [0:2047];
    (* ramstyle="M10K" *) logic [7:0] rows1_b0 [0:2047], rows1_b1 [0:2047];
    (* ramstyle="M10K" *) logic [7:0] rows2_b0 [0:2047], rows2_b1 [0:2047];
    logic [15:0] controls [0:7];
    logic score_completed, score_held_we;
    logic score_reply_pending, score_reply_ready, score_held_main_valid;
    // CPU and score share the main-RAM A port. CPU reads also win contention.
    wire cpu_main_access = state==IDLE && cpu_req && decoded_cpu_addr[25:15]==11'h030;
    logic [25:0] score_held_addr;
    logic [7:0] score_held_data;
    wire same_score = score_req && score_addr==score_held_addr && score_we==score_held_we &&
        (!score_we || score_wdata==score_held_data);
    wire cpu_main_write = state==IDLE && cpu_req && cpu_we && decoded_cpu_addr[25:15]==11'h030;
    wire score_accept = !reset && score_req && score_paused && !(score_completed && same_score) && !cpu_main_access;
    wire score_main_write = score_accept && score_we && decoded_score_addr[25:15]==11'h030 && !score_addr[1];
    wire [15:0] score_main_word = cpu_main_word;
    wire main_write_enable = cpu_main_write || score_main_write;
    wire [12:0] main_write_index = main_read_index;
    wire [1:0] main_write_be = cpu_main_write ? cpu_be[1:0] :
        (score_addr[0] ? 2'b10 : 2'b01);
    wire [15:0] main_write_data = cpu_main_write ? cpu_wdata[15:0] :
        {score_wdata,score_wdata};
    integer i;
    initial begin
        for (i=0; i<1024; i=i+1) begin systemram_b0[i]=8'h00; systemram_b1[i]=8'h00; systemram_b2[i]=8'h00; systemram_b3[i]=8'h00; palette_b0[i]=8'h00; palette_b1[i]=8'h00; end
        for (i=0; i<4096; i=i+1) begin mainram_b0[i]=8'h00; mainram_b1[i]=8'h00; end
        for (i=4096; i<8192; i=i+1) begin mainram_b0[i]=8'h00; mainram_b1[i]=8'h00; end
        for (i=0; i<2048; i=i+1) begin
            spriteram_b0[i]=8'hff; spriteram_b1[i]=8'hff; pf1_b0[i]=8'h00; pf1_b1[i]=8'h00; pf2_b0[i]=8'h00; pf2_b1[i]=8'h00; rows1_b0[i]=8'h00; rows1_b1[i]=8'h00; rows2_b0[i]=8'h00; rows2_b1[i]=8'h00;
        end
        for (i=0; i<8; i=i+1) controls[i]=0;
    end
    function automatic logic is_system(input logic [25:0] address);
        logic unused_address_bits;
        unused_address_bits = &{1'b0, address[11:0]};
        is_system = address[25:12] == 14'h201 || address[25:12] == 14'h203;
    endfunction
    function automatic logic is_pf1(input logic [25:0] address);
        logic unused_address_bits;
        unused_address_bits = &{1'b0, address[13:0]};
        is_pf1 = address[25:14] == 12'h074; // 1d0000-1d3fff, explicit +0x2000 alias
    endfunction
    function automatic logic is_mapped(input logic [25:0] address);
        is_mapped = address < 26'h080000 || is_system(address)
            || address[25:15] == 11'h030
            || address[25:13] == 13'h0c8 || address[25:12] == 14'h1a0
            || is_pf1(address) || address[25:13] == 13'h0ea
            || address[25:13] == 13'h0f0 || address[25:13] == 13'h0f2
            || (address >= 26'h1c0000 && address <= 26'h1c001f)
            || address[25:2] == (24'h1b0000 >> 2)
            || address[25:2] == (24'h200000 >> 2)
            || address[25:2] == (24'h1f0000 >> 2)
            || address == 26'h100000 || address == 26'h140000;
    endfunction
    // Address/scalar mux only: each client has an explicit indexed RAM read port.
    function automatic logic [31:0] read_local(
        input logic [25:0] address,
        input logic [31:0] system_word,
        input logic [15:0] main_word,
        input logic [15:0] sprite_word,
        input logic [15:0] palette_word,
        input logic [15:0] pf1_word,
        input logic [15:0] pf2_word,
        input logic [15:0] rows1_word,
        input logic [15:0] rows2_word,
        input logic [15:0] control_word
    );
        read_local = 32'hffffffff;
        if (is_system(address)) read_local = system_word;
        else if (address[25:15] == 11'h030) read_local = {16'hffff,main_word};
        else if (address[25:13] == 13'h0c8) read_local = {16'hffff,sprite_word};
        else if (address[25:12] == 14'h1a0) read_local = {16'hffff,palette_word};
        else if (is_pf1(address)) read_local = {16'hffff,pf1_word};
        else if (address[25:13] == 13'h0ea) read_local = {16'hffff,pf2_word};
        else if (address[25:13] == 13'h0f0) read_local = {16'hffff,rows1_word};
        else if (address[25:13] == 13'h0f2) read_local = {16'hffff,rows2_word};
        else if (address >= 26'h1c0000 && address <= 26'h1c001f)
            read_local = {16'hffff,control_word};
        else if (address[25:2] == (24'h1b0000 >> 2)) read_local = {16'hffff,inputs_1};
        else if (address[25:2] == (24'h200000 >> 2))
            read_local = {16'hffff, inputs_0[15:9],eeprom_do, vblank,inputs_0[6:0]};
        else if (address == 26'h100000) read_local = {24'hffffff,oki_sfx_status};
        else if (address == 26'h140000) read_local = {24'hffffff,oki_music_status};
    endfunction
    // CPU RAM read words; indexed independently of the other clients.
    // M10K reads register each array output before the address/type mux.
    // Port A serves one accepted CPU tuple or one paused score tuple; port B
    // serves the renderer. Do not add no_rw_check: collisions return old data.
    function automatic logic is_board_ram(input logic [25:0] address);
        is_board_ram = is_system(address) || address[25:15] == 11'h030
            || address[25:13] == 13'h0c8 || address[25:12] == 14'h1a0
            || is_pf1(address) || address[25:13] == 13'h0ea
            || address[25:13] == 13'h0f0 || address[25:13] == 13'h0f2
            || (address >= 26'h1c0000 && address <= 26'h1c001f);
    endfunction
    wire cpu_ram_accept = !reset && state == IDLE && cpu_req && is_board_ram(decoded_cpu_addr);
    wire [12:0] main_read_index = score_accept ? score_addr[14:2] : decoded_cpu_addr[14:2];
    logic [31:0] cpu_system_word, video_system_word;
    logic [15:0] cpu_main_word, cpu_sprite_word, cpu_palette_word;
    logic [15:0] cpu_pf1_word, cpu_pf2_word, cpu_rows1_word, cpu_rows2_word, cpu_control_word;
    logic [15:0] video_main_word, video_sprite_word, video_palette_word;
    logic [15:0] video_pf1_word, video_pf2_word, video_rows1_word, video_rows2_word, video_control_word;
    logic [25:0] video_read_addr;
    logic video_read_is_ram;
    logic [31:0] video_mmio_data;
    wire [31:0] local_read_data = read_local(decoded_cpu_addr,
        cpu_system_word, cpu_main_word, cpu_sprite_word, cpu_palette_word,
        cpu_pf1_word, cpu_pf2_word, cpu_rows1_word, cpu_rows2_word, cpu_control_word);
    wire [31:0] completed_ram_data = read_local(held_ram_addr,
        cpu_system_word, cpu_main_word, cpu_sprite_word, cpu_palette_word,
        cpu_pf1_word, cpu_pf2_word, cpu_rows1_word, cpu_rows2_word, cpu_control_word);
    wire [31:0] video_read_data = read_local(video_read_addr,
        video_system_word, video_main_word, video_sprite_word, video_palette_word,
        video_pf1_word, video_pf2_word, video_rows1_word, video_rows2_word, video_control_word);
    // Post-register mux preserves the existing one-clock renderer/owner pairing.
    assign video_data = video_read_is_ram ? video_read_data : video_mmio_data;

    // This port is a simulation observation interface, never an FPGA RAM port.
    // The machine facade evaluates it without advancing any simulation clock.
`ifdef ALTERA_RESERVED_QIS
    wire [31:0] state_read_data = 32'hffffffff;
    wire unused_state_address = &{1'b0, decoded_state_addr};
`elsif SYNTHESIS
    wire [31:0] state_read_data = 32'hffffffff;
    wire unused_state_address = &{1'b0, decoded_state_addr};
`else
    wire [31:0] state_read_data = read_local(decoded_state_addr,
        {systemram_b3[decoded_state_addr[11:2]], systemram_b2[decoded_state_addr[11:2]], systemram_b1[decoded_state_addr[11:2]], systemram_b0[decoded_state_addr[11:2]]}, {mainram_b1[decoded_state_addr[14:2]], mainram_b0[decoded_state_addr[14:2]]},
        {spriteram_b1[decoded_state_addr[12:2]], spriteram_b0[decoded_state_addr[12:2]]}, {palette_b1[decoded_state_addr[11:2]], palette_b0[decoded_state_addr[11:2]]},
        {pf1_b1[decoded_state_addr[12:2]], pf1_b0[decoded_state_addr[12:2]]}, {pf2_b1[decoded_state_addr[12:2]], pf2_b0[decoded_state_addr[12:2]]},
        {rows1_b1[decoded_state_addr[12:2]], rows1_b0[decoded_state_addr[12:2]]}, {rows2_b1[decoded_state_addr[12:2]], rows2_b0[decoded_state_addr[12:2]]},
        controls[decoded_state_addr[4:2]]);
`endif

    always_ff @(posedge clk) begin
        if (cpu_ram_accept) begin
            cpu_system_word <= {systemram_b3[decoded_cpu_addr[11:2]], systemram_b2[decoded_cpu_addr[11:2]], systemram_b1[decoded_cpu_addr[11:2]], systemram_b0[decoded_cpu_addr[11:2]]};
            cpu_sprite_word <= {spriteram_b1[decoded_cpu_addr[12:2]], spriteram_b0[decoded_cpu_addr[12:2]]};
            cpu_palette_word <= {palette_b1[decoded_cpu_addr[11:2]], palette_b0[decoded_cpu_addr[11:2]]};
            cpu_pf1_word <= {pf1_b1[decoded_cpu_addr[12:2]], pf1_b0[decoded_cpu_addr[12:2]]};
            cpu_pf2_word <= {pf2_b1[decoded_cpu_addr[12:2]], pf2_b0[decoded_cpu_addr[12:2]]};
            cpu_rows1_word <= {rows1_b1[decoded_cpu_addr[12:2]], rows1_b0[decoded_cpu_addr[12:2]]};
            cpu_rows2_word <= {rows2_b1[decoded_cpu_addr[12:2]], rows2_b0[decoded_cpu_addr[12:2]]};
            cpu_control_word <= controls[decoded_cpu_addr[4:2]];
        end
        if (cpu_ram_accept || score_accept) cpu_main_word <= {mainram_b1[main_read_index], mainram_b0[main_read_index]};
        if (video_req && !reset) begin
            video_system_word <= {systemram_b3[decoded_video_addr[11:2]], systemram_b2[decoded_video_addr[11:2]], systemram_b1[decoded_video_addr[11:2]], systemram_b0[decoded_video_addr[11:2]]};
            video_main_word <= {mainram_b1[decoded_video_addr[14:2]], mainram_b0[decoded_video_addr[14:2]]};
            video_sprite_word <= {spriteram_b1[decoded_video_addr[12:2]], spriteram_b0[decoded_video_addr[12:2]]};
            video_palette_word <= {palette_b1[decoded_video_addr[11:2]], palette_b0[decoded_video_addr[11:2]]};
            video_pf1_word <= {pf1_b1[decoded_video_addr[12:2]], pf1_b0[decoded_video_addr[12:2]]};
            video_pf2_word <= {pf2_b1[decoded_video_addr[12:2]], pf2_b0[decoded_video_addr[12:2]]};
            video_rows1_word <= {rows1_b1[decoded_video_addr[12:2]], rows1_b0[decoded_video_addr[12:2]]};
            video_rows2_word <= {rows2_b1[decoded_video_addr[12:2]], rows2_b0[decoded_video_addr[12:2]]};
            video_control_word <= controls[decoded_video_addr[4:2]];
        end
        if (!reset && main_write_enable) begin
            if (main_write_be[0]) mainram_b0[main_write_index] <= main_write_data[7:0];
            if (main_write_be[1]) mainram_b1[main_write_index] <= main_write_data[15:8];
        end
        if (!reset && state == IDLE && cpu_req && cpu_we) begin
            if (is_system(decoded_cpu_addr)) begin
                if (cpu_be[0]) systemram_b0[cpu_addr[11:2]] <= cpu_wdata[7:0];
                if (cpu_be[1]) systemram_b1[cpu_addr[11:2]] <= cpu_wdata[15:8];
                if (cpu_be[2]) systemram_b2[cpu_addr[11:2]] <= cpu_wdata[23:16];
                if (cpu_be[3]) systemram_b3[cpu_addr[11:2]] <= cpu_wdata[31:24];
            end else if (decoded_cpu_addr[25:13] == 13'h0c8) begin
                if (cpu_be[0]) spriteram_b0[cpu_addr[12:2]] <= cpu_wdata[7:0];
                if (cpu_be[1]) spriteram_b1[cpu_addr[12:2]] <= cpu_wdata[15:8];
            end else if (decoded_cpu_addr[25:12] == 14'h1a0) begin
                if (cpu_be[0]) palette_b0[cpu_addr[11:2]] <= cpu_wdata[7:0];
                if (cpu_be[1]) palette_b1[cpu_addr[11:2]] <= cpu_wdata[15:8];
            end else if (is_pf1(decoded_cpu_addr)) begin
                if (cpu_be[0]) pf1_b0[cpu_addr[12:2]] <= cpu_wdata[7:0];
                if (cpu_be[1]) pf1_b1[cpu_addr[12:2]] <= cpu_wdata[15:8];
            end else if (decoded_cpu_addr[25:13] == 13'h0ea) begin
                if (cpu_be[0]) pf2_b0[cpu_addr[12:2]] <= cpu_wdata[7:0];
                if (cpu_be[1]) pf2_b1[cpu_addr[12:2]] <= cpu_wdata[15:8];
            end else if (decoded_cpu_addr[25:13] == 13'h0f0) begin
                if (cpu_be[0]) rows1_b0[cpu_addr[12:2]] <= cpu_wdata[7:0];
                if (cpu_be[1]) rows1_b1[cpu_addr[12:2]] <= cpu_wdata[15:8];
            end else if (decoded_cpu_addr[25:13] == 13'h0f2) begin
                if (cpu_be[0]) rows2_b0[cpu_addr[12:2]] <= cpu_wdata[7:0];
                if (cpu_be[1]) rows2_b1[cpu_addr[12:2]] <= cpu_wdata[15:8];
            end else if (decoded_cpu_addr >= 26'h1c0000 && decoded_cpu_addr <= 26'h1c001f) begin
                if (cpu_be[0]) controls[cpu_addr[4:2]][7:0] <= cpu_wdata[7:0];
                if (cpu_be[1]) controls[cpu_addr[4:2]][15:8] <= cpu_wdata[15:8];
            end
        end
    end
    assign cpu_ready = state == RESPONSE && same_request;
    // Completion belongs to one captured tuple. Mask it immediately on a tuple
    // change or lost pause acknowledgement, retaining it while the same request
    // is held so resume cannot repeat a completed score write.
    assign score_valid = !reset && score_paused && score_completed && score_reply_ready && same_score;
    assign rom_req = state == ROM_WAIT;
    assign rom_word_addr = held_addr[18:2];
    // The previous read data stays valid after STB drops: Amber's CE-paced pipeline
    // can consume the sticky completed read later than its unpaced Wishbone engine.
    always_ff @(posedge clk) begin
        state_data <= state_read_data;
        video_valid <= video_req && !reset;
        if (video_req && !reset) begin
            video_read_addr <= decoded_video_addr;
            video_read_is_ram <= is_board_ram(decoded_video_addr);
            video_mmio_data <= read_local(decoded_video_addr,32'd0,16'd0,16'd0,
                16'd0,16'd0,16'd0,16'd0,16'd0,16'd0);
        end
        commit_valid <= 0;
        oki_sfx_wr <= 0;
        oki_music_wr <= 0;
        if (reset) begin
            state <= IDLE;
            rom_l0_valid <= 0;
            held_addr <= 0; held_ram_addr <= 0; held_we <= 0; held_be <= 0; held_wdata <= 0;
            cpu_rdata <= 32'hffffffff;
            eeprom_cs <= 0; eeprom_sk <= 0; eeprom_di <= 0;
            music_bank <= 0; oki_data <= 0;
            commit_addr <= 0; commit_be <= 0; commit_we <= 0; commit_data <= 0;
            write_count <= 0; unmapped_count <= 0;
            score_completed<=0;score_held_we<=0;score_held_addr<=0;score_held_data<=0;
            score_rdata<=8'hff;
            score_reply_pending<=0; score_reply_ready<=0; score_held_main_valid<=0;
            video_read_addr<=0; video_read_is_ram<=0; video_mmio_data<=32'hffffffff;
        end else begin
            score_reply_pending<=0;
            if(score_reply_pending) begin
                score_reply_ready<=1;
                score_rdata <= score_held_main_valid ?
                    (score_held_addr[0] ? score_main_word[15:8] : score_main_word[7:0]) : 8'hff;
            end
            if(!score_req || !same_score) begin score_completed<=0; score_reply_ready<=0; end
            if(score_accept) begin
                score_completed<=1; score_held_we<=score_we; score_held_addr<=score_addr;
                score_held_data<=score_wdata;
                score_held_main_valid<=decoded_score_addr[25:15]==11'h030 && !score_addr[1];
                score_reply_pending<=1; score_reply_ready<=0;
            end
            case (state)
                IDLE: if (cpu_req) begin
                    held_addr <= cpu_addr; held_ram_addr <= decoded_cpu_addr; held_we <= cpu_we;
                    held_be <= cpu_be; held_wdata <= cpu_wdata;
                    if (!cpu_we && cpu_addr < 26'h080000) begin
                        if (rom_l0_hit) begin
                            state <= RESPONSE;
                            cpu_rdata <= rom_l0_data[rom_l0_index];
                            commit_valid <= 1; commit_we <= 0;
                            commit_addr <= cpu_addr; commit_be <= cpu_be;
                            commit_data <= rom_l0_data[rom_l0_index];
                        end else state <= ROM_WAIT;
                    end
                    else begin
                        if (is_board_ram(decoded_cpu_addr)) begin
                            state <= RAM_WAIT;
                            // Production palette and checkpoint consumers need
                            // the write commit on the actual mutation edge.
                            if (cpu_we) begin
                                commit_valid <= 1; commit_we <= 1;
                                commit_addr <= cpu_addr; commit_be <= cpu_be;
                                commit_data <= cpu_wdata;
                            end
                        end
                        else begin
                            state <= RESPONSE;
                            cpu_rdata <= local_read_data;
                            commit_valid <= 1; commit_we <= cpu_we;
                            commit_addr <= cpu_addr; commit_be <= cpu_be;
                            commit_data <= cpu_we ? cpu_wdata : local_read_data;
                        end
                        if (!is_mapped(decoded_cpu_addr)) unmapped_count <= unmapped_count + 1;
                        if (cpu_we) begin
                            write_count <= write_count + 1;
                            if (decoded_cpu_addr[25:2] == (24'h1b0000 >> 2) && cpu_be[0]) begin
                                music_bank <= cpu_wdata[2:0];
                                eeprom_di <= cpu_wdata[4]; eeprom_sk <= cpu_wdata[5]; eeprom_cs <= cpu_wdata[6];
                            end else if (decoded_cpu_addr == 26'h100000 && cpu_be[0]) begin
                                oki_sfx_wr <= 1; oki_data <= cpu_wdata[7:0];
                            end else if (decoded_cpu_addr == 26'h140000 && cpu_be[0]) begin
                                oki_music_wr <= 1; oki_data <= cpu_wdata[7:0];
                            end
                        end
                    end
                end
                RAM_WAIT: begin
                    cpu_rdata <= completed_ram_data;
                    state <= RESPONSE;
                    if (!held_we) begin
                        commit_valid <= 1; commit_we <= 0;
                        commit_addr <= held_addr; commit_be <= held_be;
                        commit_data <= completed_ram_data;
                    end
                end
                ROM_WAIT: if (rom_ready) begin
                    rom_l0_data[held_addr[6:2]] <= rom_rdata;
                    rom_l0_tag[held_addr[6:2]] <= held_addr[18:7];
                    rom_l0_valid[held_addr[6:2]] <= 1;
                    cpu_rdata <= rom_rdata; state <= RESPONSE;
                    commit_valid <= 1; commit_we <= 0;
                    commit_addr <= held_addr; commit_be <= held_be; commit_data <= rom_rdata;
                end
                RESPONSE: if (!same_request) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
