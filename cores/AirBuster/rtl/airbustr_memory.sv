// SPDX-License-Identifier: GPL-3.0-or-later
// Air Buster CPU RAM map, from the pinned MAME 0.289 kaneko/airbustr.cpp.
// Program ROM reads never reach this module (airbustr_machine routes them to
// the program-ROM path). All ports use clk; every RAM read is registered.
//   main : C000-CFFF Pandora (bitswapped), D000-DFFF work, E000-EFFF devram
//          (EFE0-EFF5 CALC1 when fitted), F000-FFFF shared with sub
//   sub  : C000-C3FF/C400-C7FF fg code/attr, C800-CBFF/CC00-CFFF bg code/attr,
//          D000-D5FF palette (xGRB_555 little-endian pairs), D600-EFFF work,
//          F000-FFFF shared
//   sound: C000-DFFF work
// Unmapped reads return 00 as in MAME's open-bus default for this driver.
module airbustr_memory (
    input  logic        clk,
    input  logic        reset,
    input  logic        calc1_present,
    input  logic        clear_objects,   // soft reset: Pandora spriteram memset 0
    output logic        init_done,
    output logic        idle,
    input  logic        req_valid,
    output logic        req_ready,
    input  logic [1:0]  req_cpu,  // 0 main, 1 sub, 2 sound
    input  logic        req_write,
    input  logic [15:0] req_addr,
    input  logic [7:0]  req_data,
    output logic        rsp_valid,
    output logic [7:0]  rsp_data,
    output logic        calc1_watchdog,
    input  logic [8:0]  object_addr,  // native Pandora 8-byte entry index
    output logic [63:0] object_data,  // entry bytes 7..0, native order
    input  logic [9:0]  bg_tile_addr,
    output logic [7:0]  bg_tile_code, bg_tile_attr,
    input  logic [9:0]  fg_tile_addr,
    output logic [7:0]  fg_tile_code, fg_tile_attr,
    input  logic [9:0]  palette_addr,
    output logic [15:0] palette_data
);
    typedef enum logic [3:0] {UNMAPPED, OBJECT, MAIN_WORK, DEVRAM, SHARED,
        FG_CODE, FG_ATTR, BG_CODE, BG_ATTR, PAL_LO, PAL_HI, SUB_WORK,
        SOUND_WORK, CALC1} target_t;
    target_t target, accepted_target;
    logic [12:0] ram_addr;
    logic [12:0] clear_addr;
    logic [12:0] bank_addr;
    logic [7:0] bank_data;
    logic [15:0] bank_we;
    logic [7:0] q [0:15];
    logic [7:0] object_lane_q [0:7];
    logic [2:0] object_lane_sel;
    logic [7:0] calc1_q;
    logic response_valid_q;
    logic [7:0] response_data_q;
    logic state_wait;
    assign rsp_valid = response_valid_q;
    assign rsp_data = response_data_q;

    always_comb begin
        target = UNMAPPED;
        ram_addr = {1'b0, req_addr[11:0]};
        case (req_cpu)
            2'd0: begin
                if (req_addr[15:12] == 4'hc) begin
                    // Pandora 8-bit wiring: native = {cpu[11],cpu[7:0],cpu[10:8]}
                    target = OBJECT;
                    ram_addr = {1'b0,req_addr[11],req_addr[7:0],req_addr[10:8]};
                end else if (req_addr[15:12] == 4'hd) target = MAIN_WORK;
                else if (req_addr[15:12] == 4'he) begin
                    if (calc1_present && req_addr[11:0] >= 12'hfe0 && req_addr[11:0] <= 12'hff5)
                        target = CALC1;
                    else target = DEVRAM;
                end else if (req_addr[15:12] == 4'hf) target = SHARED;
            end
            2'd1: begin
                if      (req_addr[15:10] == 6'b110000) target = FG_CODE;
                else if (req_addr[15:10] == 6'b110001) target = FG_ATTR;
                else if (req_addr[15:10] == 6'b110010) target = BG_CODE;
                else if (req_addr[15:10] == 6'b110011) target = BG_ATTR;
                else if (req_addr >= 16'hd000 && req_addr < 16'hd600) begin
                    target = req_addr[0] ? PAL_HI : PAL_LO;
                    ram_addr = {3'd0, 10'(req_addr[10:1])};
                end else if (req_addr >= 16'hd600 && req_addr < 16'hf000) begin
                    target = SUB_WORK; ram_addr = req_addr[12:0];
                end else if (req_addr[15:12] == 4'hf) target = SHARED;
            end
            2'd2: if (req_addr >= 16'hc000 && req_addr < 16'he000) begin
                target = SOUND_WORK; ram_addr = req_addr[12:0];
            end
            default: target = UNMAPPED;
        endcase
    end

    assign idle = init_done && !state_wait && !rsp_valid && !reset;
    assign req_ready = init_done && !state_wait && !reset;
    wire accept = req_valid && req_ready;

    always_comb begin
        bank_addr = init_done ? ram_addr : clear_addr;
        bank_data = init_done ? req_data : 8'd0;
        bank_we = '0;
        if (!reset) begin
            if (!init_done) bank_we = 16'hffff;
            else if (accept && req_write && target != UNMAPPED) begin
                bank_we[target] = 1'b1;
                if (target == CALC1) bank_we[DEVRAM] = 1'b1;
            end
        end
    end

    logic [8:0] obj_clear_addr;
    always_ff @(posedge clk) begin
        if (reset || !clear_objects) obj_clear_addr <= 9'd0;
        else if (obj_clear_addr != 9'h1ff) obj_clear_addr <= obj_clear_addr + 9'd1;
    end
    // One write port per lane: the soft-reset clear and CPU writes are muxed
    // before the array so Quartus infers block RAM (two write addresses do not).
    wire obj_we = clear_objects || bank_we[OBJECT];
    wire [8:0] obj_waddr = clear_objects ? obj_clear_addr : bank_addr[11:3];
    wire [7:0] obj_wdata = clear_objects ? 8'h00 : bank_data;
    genvar lane;
    generate
    for (lane = 0; lane < 8; lane = lane + 1) begin : object_bank
        (* ramstyle = "M10K" *) logic [7:0] objects [0:511];
        always_ff @(posedge clk) begin
            if (obj_we && (clear_objects || bank_addr[2:0] == lane)) objects[obj_waddr] <= obj_wdata;
            object_lane_q[lane] <= objects[bank_addr[11:3]];
            object_data[8*lane+:8] <= objects[object_addr];
        end
    end
    endgenerate

    (* ramstyle = "M10K" *) logic [7:0] main_work [0:4095];
    (* ramstyle = "M10K" *) logic [7:0] devram [0:4095];
    (* ramstyle = "M10K" *) logic [7:0] shared_ram [0:4095];
    (* ramstyle = "M10K" *) logic [7:0] fg_code [0:1023];
    (* ramstyle = "M10K" *) logic [7:0] fg_attr [0:1023];
    (* ramstyle = "M10K" *) logic [7:0] bg_code [0:1023];
    (* ramstyle = "M10K" *) logic [7:0] bg_attr [0:1023];
    (* ramstyle = "M10K" *) logic [7:0] pal_lo [0:1023];
    (* ramstyle = "M10K" *) logic [7:0] pal_hi [0:1023];
    (* ramstyle = "M10K" *) logic [7:0] sub_work [0:8191];
    (* ramstyle = "M10K" *) logic [7:0] sound_work [0:8191];
    always_ff @(posedge clk) begin
        object_lane_sel <= bank_addr[2:0];
        if (bank_we[MAIN_WORK]) main_work[bank_addr[11:0]] <= bank_data;
        if (bank_we[DEVRAM]) devram[bank_addr[11:0]] <= bank_data;
        if (bank_we[SHARED]) shared_ram[bank_addr[11:0]] <= bank_data;
        if (bank_we[FG_CODE]) fg_code[bank_addr[9:0]] <= bank_data;
        if (bank_we[FG_ATTR]) fg_attr[bank_addr[9:0]] <= bank_data;
        if (bank_we[BG_CODE]) bg_code[bank_addr[9:0]] <= bank_data;
        if (bank_we[BG_ATTR]) bg_attr[bank_addr[9:0]] <= bank_data;
        if (bank_we[PAL_LO]) pal_lo[bank_addr[9:0]] <= bank_data;
        if (bank_we[PAL_HI]) pal_hi[bank_addr[9:0]] <= bank_data;
        if (bank_we[SUB_WORK]) sub_work[bank_addr] <= bank_data;
        if (bank_we[SOUND_WORK]) sound_work[bank_addr] <= bank_data;
        q[MAIN_WORK] <= main_work[bank_addr[11:0]];
        q[DEVRAM] <= devram[bank_addr[11:0]];
        q[SHARED] <= shared_ram[bank_addr[11:0]];
        q[FG_CODE] <= fg_code[bank_addr[9:0]];
        q[FG_ATTR] <= fg_attr[bank_addr[9:0]];
        q[BG_CODE] <= bg_code[bank_addr[9:0]];
        q[BG_ATTR] <= bg_attr[bank_addr[9:0]];
        q[PAL_LO] <= pal_lo[bank_addr[9:0]];
        q[PAL_HI] <= pal_hi[bank_addr[9:0]];
        q[SUB_WORK] <= sub_work[bank_addr];
        q[SOUND_WORK] <= sound_work[bank_addr];
    end

    airbustr_calc1 calc1 (
        .clk, .reset(reset || !calc1_present),
        .wr(accept && req_write && target == CALC1),
        .rd(accept && !req_write && target == CALC1),
        .addr(5'(req_addr[11:0] - 12'hfe0)), .din(req_data),
        .dout(calc1_q), .watchdog_kick(calc1_watchdog)
    );

    always_ff @(posedge clk) begin
        response_valid_q <= 1'b0;
        if (reset) begin
            init_done <= 1'b0;
            clear_addr <= 13'd0;
            state_wait <= 1'b0;
            response_data_q <= 8'hff;
            accepted_target <= UNMAPPED;
        end else if (!init_done) begin
            if (clear_addr == 13'd8191) init_done <= 1'b1;
            else clear_addr <= clear_addr + 13'd1;
        end else if (state_wait) begin
            response_data_q <= accepted_target == OBJECT ? object_lane_q[object_lane_sel] :
                               accepted_target == CALC1 ? calc1_q : q[accepted_target];
            response_valid_q <= 1'b1;
            state_wait <= 1'b0;
        end else if (accept) begin
            if (!req_write && target != UNMAPPED) begin
                accepted_target <= target;
                state_wait <= 1'b1;
            end else begin
                response_valid_q <= 1'b1;
                response_data_q <= req_write ? 8'hff : 8'h00;
            end
        end
    end

    // Renderer ports: synchronous, read old data on a coincident CPU write.
    always_ff @(posedge clk) begin
        bg_tile_code <= bg_code[bg_tile_addr];
        bg_tile_attr <= bg_attr[bg_tile_addr];
        fg_tile_code <= fg_code[fg_tile_addr];
        fg_tile_attr <= fg_attr[fg_tile_addr];
        palette_data <= {pal_hi[palette_addr], pal_lo[palette_addr]};
    end
endmodule
