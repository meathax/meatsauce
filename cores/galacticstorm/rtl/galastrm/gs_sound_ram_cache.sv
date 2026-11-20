// SPDX-License-Identifier: GPL-3.0-or-later
// Sound CPU M10K cache: 2**IW sixteen-bit words, direct mapped, write-through.
// The cached region stays in shared SDRAM; read hits answer in the lookup cycle
// like the PCB's zero-wait memories. Only the sound CPU uses these regions.
// READ_ONLY acknowledges writes without changing memory (mapped program ROM).
// Reset sweeps every tag invalid; hits are disabled until the sweep finishes, and
// any partial write that cannot prove a hit invalidates its entry.
module gs_sound_ram_cache #(
    parameter integer AW=15,       // highest cached word-address bit
    parameter integer IW=11,       // index bits
    parameter bit READ_ONLY=0
)(
    input logic clk,reset,cpu_req,cpu_write,
    input logic [AW:1] cpu_addr,
    input logic [15:0] cpu_wdata,
    input logic [1:0] cpu_be,
    output logic cpu_ack,
    output logic [15:0] cpu_rdata,
    output logic mem_req,
    input logic mem_ack,
    input logic [15:0] mem_rdata
);
    localparam integer TW=AW-IW;   // tag bits, excluding valid
    localparam integer N=1<<IW;
    typedef enum logic [1:0] {IDLE,LOOK,MISS} state_t;
    state_t state;
    (* ramstyle="M10K, no_rw_check" *) logic [7:0] hi [0:N-1];
    (* ramstyle="M10K, no_rw_check" *) logic [7:0] lo [0:N-1];
    // {valid, cpu_addr[AW:IW+1]}
    (* ramstyle="M10K, no_rw_check" *) logic [TW:0] tags [0:N-1];
    logic [7:0] q_hi,q_lo;
    logic [TW:0] q_tag;
    logic [IW-1:0] sweep;
    // swept also excludes the cycle after the last sweep write, whose tag read
    // may share that write address.
    logic sweeping,swept,was_hit,reply_ack;
    logic [15:0] reply_data;
    wire [IW-1:0] index=cpu_addr[IW:1];
    wire hit=swept && q_tag=={1'b1,cpu_addr[AW:IW+1]};
    wire look_hit=state==LOOK && !cpu_write && hit;
    wire fill=state==MISS && mem_ack;
    wire full=&cpu_be;
    wire hi_we=fill && (!cpu_write || !READ_ONLY && cpu_be[1] && (full || was_hit));
    wire lo_we=fill && (!cpu_write || !READ_ONLY && cpu_be[0] && (full || was_hit));
    // Reads and full-word writes allocate; a proven partial-write hit keeps its
    // tag; any other partial write invalidates the entry.
    wire tag_fill=fill && (!cpu_write || !READ_ONLY && (full || !was_hit));
    wire [TW:0] tag_fill_data={!cpu_write || full,cpu_addr[AW:IW+1]};
    wire tag_we=tag_fill || sweeping;
    wire [IW-1:0] tag_addr=tag_fill ? index : sweep;
    wire [TW:0] tag_data=tag_fill ? tag_fill_data : '0;
    wire [7:0] fill_hi=cpu_write ? cpu_wdata[15:8] : mem_rdata[15:8];
    wire [7:0] fill_lo=cpu_write ? cpu_wdata[7:0] : mem_rdata[7:0];
    assign mem_req=state==MISS;
    assign cpu_ack=reply_ack || look_hit;
    assign cpu_rdata=look_hit ? {q_hi,q_lo} : reply_data;
    always_ff @(posedge clk) begin
        q_hi<=hi[index];
        q_lo<=lo[index];
        q_tag<=tags[index];
        if(hi_we) hi[index]<=fill_hi;
        if(lo_we) lo[index]<=fill_lo;
        if(tag_we) tags[tag_addr]<=tag_data;
    end
    always_ff @(posedge clk) begin
        reply_ack<=0;
        if(reset) begin
            state<=IDLE;sweep<=0;sweeping<=1;swept<=0;was_hit<=0;reply_data<=0;
        end else begin
            swept<=!sweeping;
            if(sweeping && !tag_fill) begin
                sweep<=sweep+1'b1;
                if(&sweep) sweeping<=0;
            end
            case(state)
                IDLE: if(cpu_req && !reply_ack) state<=(READ_ONLY && cpu_write) ? IDLE : LOOK;
                LOOK: if(look_hit) state<=IDLE;
                      else begin was_hit<=hit;state<=MISS;end
                MISS: if(mem_ack) begin
                    reply_data<=mem_rdata;reply_ack<=1;state<=IDLE;
                end
                default: state<=IDLE;
            endcase
            // The mapped ROM ignores writes, including disabled byte lanes.
            if(READ_ONLY && state==IDLE && cpu_req && !reply_ack && cpu_write) reply_ack<=1;
        end
    end
endmodule
