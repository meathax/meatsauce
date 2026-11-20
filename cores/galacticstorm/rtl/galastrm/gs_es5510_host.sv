// SPDX-License-Identifier: BSD-3-Clause
// Native ES5510 host byte protocol, MAME/Christian Brunschen.
// Storage/special-register/clear clients are held until ACK. The integration
// serializes host commands with completed DSP instructions, not RAM cycles.
module gs_es5510_host(
    input wire clk,reset,
    input wire req,write,input wire [7:0] reg_addr,wdata,
    output reg ack,output reg [7:0] rdata,
    input wire engine_idle,halted,halt_asserted,
    output wire gpr_req,gpr_write,output wire [7:0] gpr_addr,
    output wire [23:0] gpr_wdata,input wire gpr_ack,input wire [23:0] gpr_rdata,
    output wire instr_req,instr_write,output wire [7:0] instr_addr,
    output wire [47:0] instr_wdata,input wire instr_ack,input wire [47:0] instr_rdata,
    output wire special_req,special_write,output wire [7:0] special_addr,
    output wire [23:0] special_wdata,input wire special_ack,input wire [31:0] special_rdata,
    output wire dram_req,dram_write,output wire [19:0] dram_addr,
    output wire [15:0] dram_wdata,input wire dram_ack,input wire [15:0] dram_rdata,
    output wire clear_req,input wire clear_ack,
    output wire force_halt,input wire halt_ack,
    output wire busy,output reg fault,
    output reg [7:0] serial_control,
    output reg refresh_disable
);
    typedef enum logic [2:0] {IDLE,SELECT_READ,SELECT_WRITE,RAM,CLEAR,HALT,REPLY} state_t;
    state_t state;
    reg seen;
    reg [23:0] gpr_latch,dil_latch,dol_latch,dadr_latch;
    reg [47:0] instr_latch;
    reg ram_sel;
    reg [7:0] target;
    reg do_gpr,do_instr,do_special;
    reg gpr_done,instr_done,special_done;
    reg saved_ram_write;
    wire selecting=state==SELECT_READ || state==SELECT_WRITE;
    assign busy=state!=IDLE;
    assign gpr_req=selecting && do_gpr && !gpr_done;
    assign instr_req=selecting && do_instr && !instr_done;
    assign special_req=selecting && do_special && !special_done;
    assign gpr_write=state==SELECT_WRITE;
    assign instr_write=state==SELECT_WRITE;
    assign special_write=state==SELECT_WRITE;
    assign gpr_addr=target;assign instr_addr=target;assign special_addr=target;
    assign gpr_wdata=gpr_latch;assign instr_wdata=instr_latch;assign special_wdata=gpr_latch;
    assign dram_req=state==RAM;
    assign dram_write=saved_ram_write;
    assign dram_addr=dadr_latch[19:0];assign dram_wdata=dol_latch[23:8];
    assign clear_req=state==CLEAR;
    assign force_halt=state==HALT;
    function automatic [7:0] read_byte(input [7:0] address);
        case(address)
        0:read_byte=gpr_latch[23:16];1:read_byte=gpr_latch[15:8];2:read_byte=gpr_latch[7:0];
        3:read_byte=instr_latch[47:40];4:read_byte=instr_latch[39:32];5:read_byte=instr_latch[31:24];
        6:read_byte=instr_latch[23:16];7:read_byte=instr_latch[15:8];8:read_byte=instr_latch[7:0];
        9:read_byte=dil_latch[23:16];10:read_byte=dil_latch[15:8];11:read_byte=0;
        12:read_byte=dol_latch[23:16];13:read_byte=dol_latch[15:8];14:read_byte=8'hff;
        15:read_byte=dadr_latch[23:16];16:read_byte=dadr_latch[15:8];17:read_byte=dadr_latch[7:0];
        22:read_byte=8'h27;
        default:read_byte=0;
        endcase
    endfunction
    always @(posedge clk) begin
        ack<=0;
        if(!req)seen<=0;
        case(state)
        IDLE:if(req && !seen && engine_idle)begin
            seen<=1;
            if(!write)begin rdata<=read_byte(reg_addr);state<=REPLY;end
            else begin
                state<=REPLY;
                case(reg_addr)
                0:gpr_latch[23:16]<=wdata;
                1:gpr_latch[15:8]<=wdata;
                2:gpr_latch[7:0]<=wdata;
                3:instr_latch[47:40]<=wdata;
                4:instr_latch[39:32]<=wdata;
                5:instr_latch[31:24]<=wdata;
                6:instr_latch[23:16]<=wdata;
                7:instr_latch[15:8]<=wdata;
                8:instr_latch[7:0]<=wdata;
                12:dol_latch[23:16]<=wdata;
                13:dol_latch[15:8]<=wdata;
                14:dol_latch[7:0]<=wdata;
                15:begin dadr_latch[23:16]<=wdata;saved_ram_write<=!ram_sel;state<=RAM;end
                16:dadr_latch[15:8]<=wdata;
                17:dadr_latch[7:0]<=wdata;
                18:begin refresh_disable<=wdata[0];if(wdata[1] && halted)state<=CLEAR;end
                20:ram_sel<=wdata[7];
                24:serial_control<=wdata;
                31:if(halt_asserted)state<=HALT;
                128,160,192,224:begin
                    target<=wdata;
                    do_gpr<=wdata<192 && reg_addr!=192;
                    do_special<=wdata>=234 && reg_addr!=192;
                    do_instr<=wdata<160 && reg_addr!=160;
                    gpr_done<=0;instr_done<=0;special_done<=0;
                    state<=reg_addr==128 ? SELECT_READ:SELECT_WRITE;
                    // Native invalid IRAM writes have undefined array behavior.
                    // Valid firmware uses only 0..159; report invalid writes.
                    if((reg_addr==192 || reg_addr==224) && wdata>=160)fault<=1;
                end
                default:begin end
                endcase
            end
        end
        SELECT_READ,SELECT_WRITE:begin
            if(gpr_req && gpr_ack)begin
                gpr_done<=1;if(state==SELECT_READ)gpr_latch<=gpr_rdata;
            end
            if(instr_req && instr_ack)begin
                instr_done<=1;if(state==SELECT_READ)instr_latch<=instr_rdata;
            end
            if(special_req && special_ack)begin
                special_done<=1;if(state==SELECT_READ)gpr_latch<=special_rdata[23:0];
            end
            if((!do_gpr || gpr_done) && (!do_instr || instr_done) && (!do_special || special_done))state<=REPLY;
        end
        RAM:if(dram_ack)begin if(!saved_ram_write)dil_latch<={dram_rdata,8'b0};state<=REPLY;end
        CLEAR:if(clear_ack)state<=REPLY;
        HALT:if(halt_ack)state<=REPLY;
        REPLY:begin ack<=1;state<=IDLE;end
        default:state<=IDLE;
        endcase
        if(reset)begin
            state<=IDLE;seen<=0;ack<=0;rdata<=0;fault<=0;
            gpr_latch<=0;instr_latch<=0;dil_latch<=0;dol_latch<=0;dadr_latch<=0;
            ram_sel<=0;serial_control<=0;refresh_disable<=0;
            do_gpr<=0;do_instr<=0;do_special<=0;target<=0;
            gpr_done<=0;instr_done<=0;special_done<=0;saved_ram_write<=0;
        end
    end
endmodule
