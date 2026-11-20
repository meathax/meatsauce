// SPDX-License-Identifier: BSD-3-Clause
// Live/snapshot 16-bit VRAM in one true dual-port memory.
// Epochs 0..2; 3 invalid. Scrubbing prevents aliases at every wrap.
// Cut must be held until ready; the board controller drains bus writes first.
module gs_snapshot_ram #(
    parameter WORDS=73728,
    parameter ADDR_BITS=17,
    parameter EPOCH_BITS=2,
    parameter PIPELINED_GPU=0,
    parameter BANK_READS=0
)(
    input wire clk,reset,
    output reg initialized,
    input wire cut,
    output wire cut_ready,
    output reg cut_ack,
    input wire cpu_req,cpu_write,
    input wire [ADDR_BITS-1:0] cpu_addr,
    input wire [15:0] cpu_wdata,
    input wire [1:0] cpu_bytes,
    output wire cpu_ack,
    output reg [15:0] cpu_rdata,
    input wire gpu_req,
    input wire [ADDR_BITS-1:0] gpu_addr,
    output wire gpu_ack,
    output reg [15:0] gpu_rdata
);
    localparam INIT=0,IDLE=1,CPU_READ=2,CPU_WRITE=3,CPU_REPLY=4,
        SCRUB_CHECK=5,SCRUB_WRITE=6;
    localparam RECORD_BITS=32+EPOCH_BITS;
    localparam [EPOCH_BITS-1:0] INVALID_EPOCH={EPOCH_BITS{1'b1}};
    reg [2:0] state;
    reg [ADDR_BITS-1:0] cursor,saved_cpu_addr;
    reg [15:0] saved_cpu_data;
    reg [1:0] saved_cpu_bytes;
    reg saved_cpu_write,scrub_done;
    reg [EPOCH_BITS-1:0] epoch;
    wire [EPOCH_BITS-1:0] next_epoch=epoch==INVALID_EPOCH-1'b1 ? {EPOCH_BITS{1'b0}} : epoch+1'b1;
    // 2048x5 M10Ks retain one 34-bit record per word, with no neighbor RMW.
    reg [RECORD_BITS-1:0] forward_data;
    wire [RECORD_BITS-1:0] a_data,b_data;
    reg forward_valid,gpu_pending,gpu_reply;
    reg [EPOCH_BITS-1:0] gpu_epoch;
    wire [ADDR_BITS-1:0] a_address=
        state==INIT || state==SCRUB_CHECK || state==SCRUB_WRITE ? cursor :
        state==IDLE ? (cpu_req ? cpu_addr : cursor) : saved_cpu_addr;
    wire a_write=state==INIT || state==CPU_WRITE || state==SCRUB_WRITE;
    wire [RECORD_BITS-1:0] a_write_data={INVALID_EPOCH,32'b0};
    wire [RECORD_BITS-1:0] gpu_record=forward_valid ? forward_data : b_data;
    wire [15:0] merged_cpu_data={
        saved_cpu_bytes[1] ? saved_cpu_data[15:8] : a_data[15:8],
        saved_cpu_bytes[0] ? saved_cpu_data[7:0] : a_data[7:0]};
    assign cpu_ack=state==CPU_REPLY && cpu_req;
    assign gpu_ack=gpu_reply && (PIPELINED_GPU || gpu_req);
    assign cut_ready=initialized && scrub_done && state==IDLE &&
        !cpu_req && !gpu_req && !gpu_pending && !gpu_reply;

    wire [RECORD_BITS-1:0] staged_record=state==CPU_READ ?
        {epoch,a_data[RECORD_BITS-1:32]==epoch ? a_data[31:16] : a_data[15:0],merged_cpu_data} :
        {INVALID_EPOCH,a_data[31:0]};
    wire [RECORD_BITS-1:0] a_write_record_data=state==INIT ? a_write_data : forward_data;
    (* ramstyle="M10K, no_rw_check", max_depth=2048 *) reg [RECORD_BITS-1:0] records[0:WORDS-1];
    reg [RECORD_BITS-1:0] a_read,b_read;
    // Optional explicit physical-bank read selection. The selected bank and its
    // synchronous data advance together, preserving the existing one-clock
    // record read and two-clock GPU reply. Production keeps this disabled until
    // the fitted capacity/timing checkpoint qualifies the proposed mux reduction.
    generate if(BANK_READS && WORDS>2048) begin: banked_reads
        localparam BANK_WORDS=2048;
        localparam BANKS=(WORDS+BANK_WORDS-1)/BANK_WORDS;
        wire [RECORD_BITS-1:0] bank_a[0:BANKS-1],bank_b[0:BANKS-1];
        reg [BANKS-1:0] select_a,select_b;
        reg [RECORD_BITS-1:0] selected_a,selected_b;
        genvar bank;
        for(bank=0;bank<BANKS;bank=bank+1) begin: slice
            localparam DEPTH=WORDS-bank*BANK_WORDS<BANK_WORDS ?
                WORDS-bank*BANK_WORDS : BANK_WORDS;
            wire address_a_here=(a_address>>11)==bank;
            wire address_b_here=(gpu_addr>>11)==bank;
            (* ramstyle="M10K, no_rw_check", max_depth=2048 *)
                reg [RECORD_BITS-1:0] records[0:DEPTH-1];
            reg [RECORD_BITS-1:0] read_a,read_b;
            always @(posedge clk) begin
                select_a[bank]<=address_a_here;
                select_b[bank]<=address_b_here;
                // Shared true dual-port RAM needs unconditional read ports.
                // The registered selectors suppress inactive bank outputs.
                read_a<=records[a_address[10:0]];
                read_b<=records[gpu_addr[10:0]];
                if(a_write && address_a_here)
                    records[a_address[10:0]]<=a_write_record_data;
            end
            assign bank_a[bank]=read_a;
            assign bank_b[bank]=read_b;
        end
        always @* begin
            selected_a=0;selected_b=0;
            for(integer bank=0;bank<BANKS;bank=bank+1) begin
                selected_a=selected_a | (select_a[bank] ? bank_a[bank] : {RECORD_BITS{1'b0}});
                selected_b=selected_b | (select_b[bank] ? bank_b[bank] : {RECORD_BITS{1'b0}});
            end
        end
        assign a_data=selected_a;assign b_data=selected_b;
    end else begin: inferred_reads
        always @(posedge clk) begin
            a_read<=records[a_address];b_read<=records[gpu_addr];
            if(a_write) records[a_address]<=a_write_record_data;
        end
        assign a_data=a_read;assign b_data=b_read;
    end endgenerate
    // Forward the written record on a same-word collision.
    always @(posedge clk) begin
        if((state==CPU_READ && saved_cpu_write) ||
           (state==SCRUB_CHECK && a_data[RECORD_BITS-1:32]==next_epoch))
            forward_data<=staged_record;
        else if(state==INIT) forward_data<=a_write_record_data;
        forward_valid<=a_write && a_address==gpu_addr;
    end
    always @(posedge clk) begin
        cut_ack<=0;
        if(PIPELINED_GPU) begin
            gpu_pending<=gpu_req && initialized;
            gpu_reply<=gpu_pending;
            if(gpu_req && initialized) gpu_epoch<=epoch;
            if(gpu_pending)
                gpu_rdata<=gpu_record[RECORD_BITS-1:32]==gpu_epoch ? gpu_record[31:16] : gpu_record[15:0];
        end else if(!gpu_pending && !gpu_reply && gpu_req && initialized) begin
            gpu_pending<=1;gpu_epoch<=epoch;
        end else if(gpu_pending) begin
            gpu_rdata<=gpu_record[RECORD_BITS-1:32]==gpu_epoch ? gpu_record[31:16] : gpu_record[15:0];
            gpu_pending<=0;gpu_reply<=1;
        end else if(gpu_reply && !gpu_req) gpu_reply<=0;
        case(state)
        INIT: begin
            if(cursor==WORDS-1) begin initialized<=1;scrub_done<=1;cursor<=0;state<=IDLE;end
            else cursor<=cursor+1'b1;
        end
        IDLE: begin
            if(cut && cut_ready) begin
                epoch<=next_epoch;scrub_done<=0;cursor<=0;cut_ack<=1;
            end else if(cpu_req && initialized) begin
                saved_cpu_addr<=cpu_addr;saved_cpu_data<=cpu_wdata;
                saved_cpu_bytes<=cpu_bytes;saved_cpu_write<=cpu_write;state<=CPU_READ;
            end else if(!scrub_done) state<=SCRUB_CHECK;
        end
        CPU_READ: begin
            cpu_rdata<=a_data[15:0];
            if(saved_cpu_write) begin
                state<=CPU_WRITE;
            end else state<=CPU_REPLY;
        end
        CPU_WRITE: state<=CPU_REPLY;
        CPU_REPLY: if(!cpu_req) state<=IDLE;
        SCRUB_CHECK: begin
            if(a_data[RECORD_BITS-1:32]==next_epoch) state<=SCRUB_WRITE;
            else begin
                if(cursor==WORDS-1) begin scrub_done<=1;cursor<=0;end
                else cursor<=cursor+1'b1;
                state<=IDLE;
            end
        end
        SCRUB_WRITE: begin
            if(cursor==WORDS-1) begin scrub_done<=1;cursor<=0;end
            else cursor<=cursor+1'b1;
            state<=IDLE;
        end
        endcase
        if(reset) begin
            state<=INIT;initialized<=0;cursor<=0;saved_cpu_addr<=0;saved_cpu_data<=0;
            saved_cpu_bytes<=0;saved_cpu_write<=0;scrub_done<=0;epoch<=0;
            cut_ack<=0;cpu_rdata<=0;gpu_rdata<=0;gpu_epoch<=0;gpu_pending<=0;gpu_reply<=0;
        end
    end
endmodule
