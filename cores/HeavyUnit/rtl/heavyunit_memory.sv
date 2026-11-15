// SPDX-License-Identifier: GPL-3.0-or-later
// Heavy Unit CPU memory map, from the pinned MAME 0.289 driver.
// All ports use clk. ROM responses must be registered; reset also resets the
// memory state. Warm game reset lets pending storage replies drain before release.
// No game clock is generated here.
// Unmapped reads are 00 in the pinned MAME profile; PCB open-bus voltage/hold
// behavior is unverified and must not be described as an exact hardware fact.
module heavyunit_memory (
    input  logic        clk,
    input  logic        reset,
    output logic        init_done,
    output logic        idle,
    input  logic        req_valid,
    output logic        req_ready,
    input  logic [1:0]  req_cpu,  // 0 main, 1 sub, 2 sound
    input  logic        req_write,
    input  logic [15:0] req_addr,
    input  logic [7:0]  req_data,
    input  logic [2:0]  main_bank,
    input  logic [1:0]  sub_bank,
    input  logic [1:0]  sound_bank,
    output logic        rsp_valid,
    output logic [7:0]  rsp_data,
    output logic        rom_req_valid,
    input  logic        rom_req_ready,
    output logic [21:0] rom_req_addr, // byte address in the selected-set image
    input  logic        rom_rsp_valid,
    input  logic [7:0]  rom_rsp_data,
    input  logic [8:0]  object_addr,  // native Pandora 8-byte entry index
    output logic [63:0] object_data,  // entry bytes 7..0, native order
    input  logic [9:0]  tile_addr,
    output logic [7:0]  tile_code,
    output logic [7:0]  tile_attr,
    input  logic [8:0]  palette_addr,
    output logic [7:0]  palette_low,
    output logic [7:0]  palette_ext
);
    localparam logic [3:0] UNMAPPED=0, ROM=1, OBJECT=2, MAIN_WORK=3,
        SHARED=4, TILE_CODE=5, TILE_ATTR=6, PALETTE_EXT=7,
        PALETTE_LOW=8, SUB_WORK=9, SOUND_WORK=10;
    // Object RAM is eight byte lanes (native address bits 2:0) so the renderer
    // snapshots one whole 8-byte sprite entry per clock at EOF.
    logic [7:0] object_lane_q [0:7];
    logic [2:0] object_lane_sel;
    (* ramstyle = "M10K" *) logic [7:0] main_work [0:4095];
    (* ramstyle = "M10K" *) logic [7:0] shared_ram [0:8191];
    (* ramstyle = "M10K" *) logic [7:0] codes [0:1023];
    (* ramstyle = "M10K" *) logic [7:0] attrs [0:1023];
    (* ramstyle = "M10K" *) logic [7:0] pal_ext [0:511];
    (* ramstyle = "M10K" *) logic [7:0] pal_low [0:511];
    (* ramstyle = "M10K" *) logic [7:0] sub_work [0:4095];
    (* ramstyle = "M10K" *) logic [7:0] sound_work [0:2047];
    logic [3:0] target;
    logic [12:0] ram_addr;
    logic [21:0] decoded_rom;
    logic [13:0] clear_addr;
    logic [10:2][7:0] cpu_ram_q;
    logic [10:2] bank_we;
    logic [12:0] bank_addr;
    logic [7:0] bank_data;
    logic [3:0] accepted_ram_target;
    logic response_valid_q;
    logic [7:0] response_data_q;
    logic [1:0] rom_response_age;
    typedef enum logic [1:0] {IDLE, ROM_ISSUE, ROM_WAIT, RAM_WAIT} state_t;
    state_t state;
    // PRIVATE REVIEW CANDIDATE. Forward only the existing two-edge cache
    // return after acceptance. Later (miss) returns retain registered timing.
    wire early_rom_response = !reset && init_done && state == ROM_WAIT &&
        rom_rsp_valid && rom_response_age == 2'd1;
    assign rsp_valid = response_valid_q || early_rom_response;
    assign rsp_data = early_rom_response ? rom_rsp_data : response_data_q;

    // The 8-bit Pandora interface rotates three address bits, not a simple
    // bit0/bit10 swap: native = {cpu[11],cpu[7:0],cpu[10:8]} (kan_pand.cpp).
    always_comb begin
        target = UNMAPPED;
        ram_addr = {1'b0, req_addr[11:0]};
        decoded_rom = 22'd0;
        if (req_cpu != 2'd3 && req_addr < 16'hc000) begin
            target = ROM;
            case (req_cpu)
                2'd0: decoded_rom = req_addr < 16'h8000
                    ? {6'd0,req_addr} : {5'd0,main_bank,req_addr[13:0]};
                2'd1: decoded_rom = 22'h020000 + (req_addr < 16'h8000
                    ? {6'd0,req_addr} : {6'd0,sub_bank,req_addr[13:0]});
                2'd2: decoded_rom = 22'h030000 + (req_addr < 16'h8000
                    ? {6'd0,req_addr} : {6'd0,sound_bank,req_addr[13:0]});
                default: decoded_rom = 22'd0;
            endcase
        end else begin
            case (req_cpu)
                2'd0: begin
                    if (req_addr < 16'hd000) begin
                        target = OBJECT;
                        ram_addr = {1'b0,req_addr[11],req_addr[7:0],req_addr[10:8]};
                    end else if (req_addr < 16'he000) target = MAIN_WORK;
                    else begin target = SHARED; ram_addr = req_addr[12:0]; end
                end
                2'd1: begin
                    if      (req_addr < 16'hc400) target = TILE_CODE;
                    else if (req_addr < 16'hc800) target = TILE_ATTR;
                    else if (req_addr < 16'hd000) target = UNMAPPED;
                    else if (req_addr < 16'hd200) target = PALETTE_EXT;
                    else if (req_addr < 16'hd800) target = SUB_WORK;
                    else if (req_addr < 16'hda00) target = PALETTE_LOW;
                    else if (req_addr < 16'he000) target = SUB_WORK;
                    else begin target = SHARED; ram_addr = req_addr[12:0]; end
                end
                2'd2: if (req_addr < 16'hc800) target = SOUND_WORK;
                default: target = UNMAPPED;
            endcase
        end
    end

    assign idle = init_done && state == IDLE && !rsp_valid && !reset;
    assign req_ready = init_done && state == IDLE && !reset;
    assign rom_req_valid = state == ROM_ISSUE && !reset;

    // Each bank has an independent synchronous read output. Multiplexing nine
    // array reads into the resettable response register prevented M10K inference.
    // Initialization and CPU writes share the same bank address/write port.
    always_comb begin
        bank_addr = init_done ? ram_addr : clear_addr[12:0];
        bank_data = init_done ? req_data : 8'd0;
        bank_we = '0;
        if (!reset) begin
            if (!init_done) begin
                bank_we[SHARED] = 1'b1;
                if (clear_addr < 14'd4096) begin
                    bank_we[OBJECT] = 1'b1;
                    bank_we[MAIN_WORK] = 1'b1;
                    bank_we[SUB_WORK] = 1'b1;
                end
                if (clear_addr < 14'd2048) bank_we[SOUND_WORK] = 1'b1;
                if (clear_addr < 14'd1024) begin
                    bank_we[TILE_CODE] = 1'b1;
                    bank_we[TILE_ATTR] = 1'b1;
                end
                if (clear_addr < 14'd512) begin
                    bank_we[PALETTE_EXT] = 1'b1;
                    bank_we[PALETTE_LOW] = 1'b1;
                end
            end else if (state == IDLE && req_valid && req_write &&
                         target >= OBJECT && target <= SOUND_WORK) begin
                bank_we[target] = 1'b1;
            end
        end
    end

    genvar lane;
    generate
    for (lane = 0; lane < 8; lane = lane + 1) begin : object_bank
        (* ramstyle = "M10K" *) logic [7:0] objects [0:511];
        always_ff @(posedge clk) begin
            if (bank_we[OBJECT] && bank_addr[2:0] == lane) objects[bank_addr[11:3]] <= bank_data;
            object_lane_q[lane] <= objects[bank_addr[11:3]];
            object_data[8*lane+:8] <= objects[object_addr];
        end
    end
    endgenerate

    always_ff @(posedge clk) begin
        object_lane_sel <= bank_addr[2:0];
        if (bank_we[MAIN_WORK]) main_work[bank_addr[11:0]] <= bank_data;
        if (bank_we[SHARED]) shared_ram[bank_addr] <= bank_data;
        if (bank_we[TILE_CODE]) codes[bank_addr[9:0]] <= bank_data;
        if (bank_we[TILE_ATTR]) attrs[bank_addr[9:0]] <= bank_data;
        if (bank_we[PALETTE_EXT]) pal_ext[bank_addr[8:0]] <= bank_data;
        if (bank_we[PALETTE_LOW]) pal_low[bank_addr[8:0]] <= bank_data;
        if (bank_we[SUB_WORK]) sub_work[bank_addr[11:0]] <= bank_data;
        if (bank_we[SOUND_WORK]) sound_work[bank_addr[10:0]] <= bank_data;
        cpu_ram_q[MAIN_WORK] <= main_work[bank_addr[11:0]];
        cpu_ram_q[SHARED] <= shared_ram[bank_addr];
        cpu_ram_q[TILE_CODE] <= codes[bank_addr[9:0]];
        cpu_ram_q[TILE_ATTR] <= attrs[bank_addr[9:0]];
        cpu_ram_q[PALETTE_EXT] <= pal_ext[bank_addr[8:0]];
        cpu_ram_q[PALETTE_LOW] <= pal_low[bank_addr[8:0]];
        cpu_ram_q[SUB_WORK] <= sub_work[bank_addr[11:0]];
        cpu_ram_q[SOUND_WORK] <= sound_work[bank_addr[10:0]];
    end

    always_ff @(posedge clk) begin
        response_valid_q <= 1'b0;
        if (reset) begin
            init_done <= 1'b0;
            clear_addr <= 14'd0;
            state <= IDLE;
            response_data_q <= 8'hff;
            rom_req_addr <= 22'd0;
            accepted_ram_target <= UNMAPPED;
            rom_response_age <= 2'd0;
        end else if (!init_done) begin
            if (clear_addr == 14'd8191) init_done <= 1'b1;
            else clear_addr <= clear_addr + 14'd1;
        end else begin
            case (state)
                IDLE: if (req_valid) begin
                    if (target == ROM && !req_write) begin
                        rom_req_addr <= decoded_rom;
                        state <= ROM_ISSUE;
                    end else if (target >= OBJECT && target <= SOUND_WORK && !req_write) begin
                        accepted_ram_target <= target;
                        state <= RAM_WAIT;
                    end else begin
                        response_valid_q <= 1'b1;
                        response_data_q <= target >= OBJECT && target <= SOUND_WORK
                            ? req_data : (req_write ? 8'hff : 8'h00);
                    end
                end
                RAM_WAIT: begin
                    response_data_q <= accepted_ram_target == OBJECT ?
                        object_lane_q[object_lane_sel] : cpu_ram_q[accepted_ram_target];
                    response_valid_q <= 1'b1;
                    state <= IDLE;
                end
                ROM_ISSUE: if (rom_req_ready) begin
                    rom_response_age <= 2'd0;
                    state <= ROM_WAIT;
                end
                ROM_WAIT: begin
                    if (rom_rsp_valid) begin
                        response_data_q <= rom_rsp_data;
                        // The forwarded pulse is consumed at this edge. Never
                        // repeat it from the retained response register.
                        response_valid_q <= !early_rom_response;
                        state <= IDLE;
                    end else if (rom_response_age != 2'd2) begin
                        rom_response_age <= rom_response_age + 2'd1;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end

    // Renderer ports are synchronous, native-addressed and read old data on a
    // coincident CPU write. Their clock must remain clk (or use a real CDC).
    always_ff @(posedge clk) begin
        tile_code <= codes[tile_addr];
        tile_attr <= attrs[tile_addr];
        palette_low <= pal_low[palette_addr];
        palette_ext <= pal_ext[palette_addr];
    end
endmodule
