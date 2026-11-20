// SPDX-License-Identifier: GPL-3.0-or-later
// Main 68020 program-ROM line cache: 2**IW lines of four 16-bit words in M10K,
// direct mapped, filled with the aligned 64-bit SDRAM line returned by one
// read. Read-only: writes to mapped ROM are acknowledged and ignored.
//
// Hit latency equals the replaced 128-word MLAB cache: the reply is registered
// on the first edge after the request appears. The M10K read address is the
// CPU's next bus address (look_addr) while no request is held, so the data and
// tag for the request latched by gs_cpu are already on the RAM output in the
// request's first cycle. A request that appears without that lookahead (e.g.
// the held address changed) takes one extra LOOK cycle, never a wrong word.
// Reset sweeps every tag invalid; lookups miss until the sweep completes.
module gs_main_rom_cache #(
    parameter integer IW=9              // line index bits (2**IW lines)
)(
    input logic clk,reset,
    input logic cpu_req,cpu_write,
    input logic [23:0] cpu_addr,        // held request address
    input logic look_valid,             // no CPU transfer is held this cycle
    input logic [23:0] look_addr,       // address gs_cpu latches on its next issue
    output logic cpu_ack,
    output logic [15:0] cpu_rdata,
    output logic mem_req,               // aligned line read
    output logic [23:0] mem_addr,
    input logic mem_ack,
    input logic [63:0] mem_rline
);
    localparam integer TW=17-IW;        // tag bits: line address [19:3] minus index
    localparam integer N=1<<IW;
    (* ramstyle="M10K, no_rw_check" *) logic [63:0] lines [0:N-1];
    // {valid, line tag}
    (* ramstyle="M10K, no_rw_check" *) logic [TW:0] tags [0:N-1];
    logic [63:0] q_line;
    logic [TW:0] q_tag;
    logic [23:0] q_addr;                // address whose index the RAM output holds
    logic [IW-1:0] sweep;
    logic sweeping,swept,reply_ack,pending;
    logic [15:0] reply_data;
    logic [23:0] pending_addr;
    wire [IW-1:0] req_index=cpu_addr[IW+2:3];
    wire [IW-1:0] look_index=look_addr[IW+2:3];
    // Hold the RAM address on the request while one is presented.
    wire [IW-1:0] rd_index=(cpu_req || !look_valid) ? req_index : look_index;
    wire [23:0] rd_addr=(cpu_req || !look_valid) ? cpu_addr : look_addr;
    wire fill=pending && mem_ack;
    wire [IW-1:0] fill_index=pending_addr[IW+2:3];
    wire tag_we=fill || sweeping;
    wire [IW-1:0] tag_waddr=fill ? fill_index : sweep;
    wire [TW:0] tag_wdata=fill ? {1'b1,pending_addr[19:IW+3]} : '0;
    // The RAM output belongs to this request only if it was read for the same
    // line index, and no write could have changed that entry since.
    wire q_current=q_addr[IW+2:3]==req_index;
    wire hit=swept && q_current && q_tag=={1'b1,cpu_addr[19:IW+3]};
    wire start=cpu_req && !reply_ack && !pending;
    assign cpu_ack=reply_ack;
    assign cpu_rdata=reply_data;
    assign mem_req=pending;
    assign mem_addr=pending_addr;
    always_ff @(posedge clk) begin
        q_line<=lines[rd_index];
        q_tag<=tags[rd_index];
        if(fill) lines[fill_index]<=mem_rline;
        if(tag_we) tags[tag_waddr]<=tag_wdata;
    end
    always_ff @(posedge clk) begin
        reply_ack<=0;
        // A fill (or sweep write) makes the previously read output stale for
        // that index: force a re-read by invalidating the address record.
        q_addr<=rd_addr;
        if(reset) begin
            sweep<=0;sweeping<=1;swept<=0;pending<=0;pending_addr<=0;reply_data<=0;
        end else begin
            swept<=!sweeping;
            if(sweeping && !fill) begin
                sweep<=sweep+1'b1;
                if(&sweep) sweeping<=0;
            end
            if(fill) begin
                // pending_addr is line aligned; the held request keeps its lane.
                reply_data<=mem_rline[16*cpu_addr[2:1] +: 16];
                reply_ack<=1;pending<=0;
                q_addr<=~rd_addr;       // output was read before this write
            end else if(start) begin
                if(cpu_write) reply_ack<=1;   // mapped ROM ignores writes
                else if(hit) begin
                    reply_data<=q_line[16*cpu_addr[2:1] +: 16];
                    reply_ack<=1;
                end else if(swept && q_current) begin
                    pending<=1;pending_addr<={cpu_addr[23:3],3'b000};
                end
                // Otherwise the RAM is re-reading req_index this edge (or the
                // sweep is running); decide on the next cycle.
            end
        end
    end
endmodule
