// SPDX-License-Identifier: GPL-3.0-or-later
// MiSTer Avalon DDR: cart (cart_banks x 16 MiB, 48 MiB for crysking) at 30000000, BIOS immediately
// after the populated banks. Unpopulated banks read 0xFF as MAME's dummy flash region.
// Run on clk_sys, which drives DDRAM_CLK in the MiSTer wrapper. Framework
// sysmem owns the crossing into the HPS memory controller.
module cs_ddr_rom_backend (
    input logic clk, reset,
    input logic [3:0] cart_banks, // 0 = legacy 3
    input logic req_valid,
    output logic req_ready,
    input logic [3:0] req_target,
    input logic [31:0] req_offset,
    input logic req_write,
    output logic rsp_valid,
    output logic [31:0] rsp_data,
    output logic rsp_error,
    input logic load_valid,
    output logic load_ready,
    input logic [3:0] load_target,
    input logic [31:0] load_offset,
    input logic [63:0] load_data,
    input logic [7:0] load_be,
    output logic load_done, load_error,
    input logic DDRAM_BUSY,
    output logic [7:0] DDRAM_BURSTCNT,
    output logic [28:0] DDRAM_ADDR,
    input logic [63:0] DDRAM_DOUT,
    input logic DDRAM_DOUT_READY,
    output logic DDRAM_RD,
    output logic [63:0] DDRAM_DIN,
    output logic [7:0] DDRAM_BE,
    output logic DDRAM_WE
);
    localparam logic [28:0] CART_WORD_BASE=29'h06000000;
    wire [3:0] banks=cart_banks==0 ? 4'd3 : cart_banks;
    wire [31:0] cart_bytes={4'b0,banks,24'b0};
    // 16 MiB = 0x200000 64-bit words per bank.
    wire [28:0] BIOS_WORD_BASE=CART_WORD_BASE+{4'b0,banks,21'b0};
    typedef enum logic [2:0] {IDLE,FILL_CMD,FILL_DATA,REPLY,LOAD_CMD,LOAD_REPLY,DRAIN} state_t;
    state_t state;
    logic cache_valid, reply_cached, reply_error;
    logic [28:0] cache_base, command_address;
    logic [7:0][63:0] cache_data;
    logic [2:0] beat;
    logic [3:0] wanted_word;
    logic [31:0] reply_data;
    logic [63:0] write_data;
    logic [7:0] write_be;
    wire request_region=req_target==0 || req_target==4;
    wire request_aligned=req_offset[1:0]==0;
    wire request_in_range=req_target==0 ? req_offset<32'h00020000 : req_offset<cart_bytes;
    wire [28:0] request_line=(req_target==0 ? BIOS_WORD_BASE : CART_WORD_BASE)+{req_offset[31:6],3'b000};
    wire loader_region=load_target==0 || load_target==4;
    wire loader_in_range=load_target==0 ? load_offset<32'h00020000 : load_offset<cart_bytes;
    wire loader_ok=loader_region && loader_in_range && load_offset[2:0]==0;
    assign req_ready=!reset && state==IDLE && !load_valid;
    assign load_ready=!reset && state==IDLE;
    assign DDRAM_RD=!reset && state==FILL_CMD;
    assign DDRAM_WE=!reset && state==LOAD_CMD;
    assign DDRAM_ADDR=command_address;
    assign DDRAM_BURSTCNT=state==LOAD_CMD ? 8'd1 : 8'd8;
    assign DDRAM_DIN=write_data;
    assign DDRAM_BE=state==LOAD_CMD ? write_be : 8'hff;
    always_ff @(posedge clk) begin
        rsp_valid<=0;load_done<=0;
        if(reset) begin
            cache_valid<=0;reply_cached<=0;rsp_error<=0;load_error<=0;
            // A core reset cannot cancel an accepted HPS read. Drain its
            // remaining beats before accepting a new owner after reset.
            if(state==FILL_DATA || state==DRAIN) begin
                if(DDRAM_DOUT_READY) begin
                    if(beat==7) state<=IDLE;
                    else begin beat<=beat+1'b1;state<=DRAIN;end
                end else state<=DRAIN;
            end else begin state<=IDLE;beat<=0;end
        end else case(state)
            IDLE: begin
                if(load_valid && load_ready) begin
                    cache_valid<=0;load_error<=!loader_ok;
                    command_address<=(load_target==0 ? BIOS_WORD_BASE : CART_WORD_BASE)+load_offset[31:3];
                    write_data<=load_data;write_be<=load_be;
                    state<=loader_ok && load_be!=0 ? LOAD_CMD : LOAD_REPLY;
                end else if(req_valid && req_ready) begin
                    wanted_word<=req_offset[5:2];reply_cached<=0;reply_error<=0;
                    if(!request_region || !request_aligned || (req_target==0 && !request_in_range)) begin
                        reply_data<=32'hffffffff;reply_error<=1;state<=REPLY;
                    end else if(req_write) begin
                        reply_data<=0;state<=REPLY; // BIOS/cart ROM ignores CPU writes.
                    end else if(!request_in_range) begin
                        reply_data<=32'hffffffff;state<=REPLY;
                    end else if(cache_valid && cache_base==request_line) begin
                        reply_cached<=1;state<=REPLY;
                    end else begin
                        cache_valid<=0;command_address<=request_line;
                        beat<=0;state<=FILL_CMD;
                    end
                end
            end
            FILL_CMD: if(!DDRAM_BUSY) state<=FILL_DATA;
            FILL_DATA: if(DDRAM_DOUT_READY) begin
                cache_data[beat]<=DDRAM_DOUT;
                if(beat==7) begin
                    cache_valid<=1;cache_base<=command_address;
                    reply_cached<=1;reply_error<=0;state<=REPLY;
                end else beat<=beat+1'b1;
            end
            REPLY: begin
                rsp_valid<=1;rsp_error<=reply_error;
                rsp_data<=reply_cached ? (wanted_word[0] ? cache_data[wanted_word[3:1]][63:32] : cache_data[wanted_word[3:1]][31:0]) : reply_data;
                state<=IDLE;
            end
            LOAD_CMD: if(!DDRAM_BUSY) begin load_done<=1;load_error<=0;state<=IDLE;end
            LOAD_REPLY: begin load_done<=1;state<=IDLE;end
            DRAIN: if(DDRAM_DOUT_READY) begin
                if(beat==7) state<=IDLE;
                else beat<=beat+1'b1;
            end
            default: state<=IDLE;
        endcase
    end
endmodule
