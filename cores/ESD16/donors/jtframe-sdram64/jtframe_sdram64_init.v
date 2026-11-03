/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 29-4-2021 */
/* verilator coverage_off */
module jtframe_sdram64_init #(parameter
    HF      =1,
    BURSTLEN=64,
    XL      =0,
    CAS_LATENCY=2
) (
    input               rst,
    input               clk,

    output   reg        init,
    output   reg        chip,
    output   reg  [3:0] cmd,
    output   reg [12:0] sdram_a
);

localparam [14:0] INIT_WAIT = HF ? 15'd21_560 : 15'd5_000; // 220us at the pinned 98MHz HF profile
localparam [2:0] CAS_CODE = CAS_LATENCY==3 ? 3'b011 : 3'b010;
initial if(CAS_LATENCY!=2 && CAS_LATENCY!=3) $error("CAS_LATENCY must be 2 or 3");

//                             /CS /RAS /CAS /WE
localparam CMD_LOAD_MODE   = 4'b0___0____0____0, // 0
           CMD_REFRESH     = 4'b0___0____0____1, // 1
           CMD_PRECHARGE   = 4'b0___0____1____0, // 2
           CMD_ACTIVE      = 4'b0___0____1____1, // 3
           CMD_WRITE       = 4'b0___1____0____0, // 4
           CMD_READ        = 4'b0___1____0____1, // 5
           CMD_STOP        = 4'b0___1____1____0, // 6 Burst terminate
           CMD_NOP         = 4'b0___1____1____1, // 7
           CMD_INHIBIT     = 4'b1___0____0____0; // 8

// initialization signals
reg [14:0] wait_cnt;
reg [ 2:0] init_st;
reg [ 3:0] init_cmd;
// Memory remains powered across controller reset. Distinguish the first power epoch.
reg warm = 1'b0;
reg rst_d = 1'b0;

always @(posedge clk) begin
    rst_d <= rst;
    if( rst && (!warm || !rst_d) ) begin
        // initialization loop
        init     <= 1;
        chip     <= 0;
        wait_cnt <= warm ? 15'd16 : INIT_WAIT; // cold220us; warmdrain163ns at98MHz
        init_st  <= 3'd0;
        init_cmd <= CMD_NOP;
        // SDRAM pins
        cmd      <= CMD_NOP;
        sdram_a  <= 13'd0;
    end else if( init ) begin
        if( |wait_cnt ) begin
            wait_cnt <= wait_cnt-15'd1;
            init_cmd <= CMD_NOP;
            cmd      <= init_cmd;
        end else begin
            sdram_a  <= 13'd0;
            if(!init_st[2]) init_st <= init_st+3'd1;
            case(init_st)
                3'd0: begin
                    init_cmd   <= CMD_PRECHARGE;
                    sdram_a[10]<= 1; // all banks
                    wait_cnt   <= 15'd2;
                end
                3'd1: begin
                    init_cmd <= CMD_REFRESH;
                    wait_cnt <= 15'd11;
                end
                3'd2: begin
                    init_cmd <= CMD_REFRESH;
                    wait_cnt <= 15'd11;
                end
                3'd3: begin
                    init_cmd <= CMD_LOAD_MODE;
                    sdram_a  <= {3'b000,1'b1,2'b00,CAS_CODE,1'b0,BURSTLEN==64?3'b010:(BURSTLEN==32?3'b001:3'b000)}; // A9 single write; CAS and read burst are profile parameters
                    wait_cnt <= 15'd3;
                end
                3'd4: begin
                    if( XL && !chip ) begin
                        chip     <= 1;
                        init_st  <= 3'd0;
                        init_cmd <= CMD_NOP;
                        wait_cnt <= 15'd2;
                    end else if( rst ) begin
                        // All rows are now precharged. Keep refreshing while reset is held.
                        init_cmd <= CMD_REFRESH;
                        wait_cnt <= 15'd399; // <=4.1us at the pinned98MHz profile
                    end else begin
                        init <= 0;
                        warm <= 1'b1;
                    end
                end
                default: begin
                    cmd  <= init_cmd;
                    init <= 0;
                end
            endcase
        end
    end
end

endmodule