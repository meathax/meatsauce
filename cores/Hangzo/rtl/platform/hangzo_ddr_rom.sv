// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from the pristine OSMAN byte replay in donors/osman-ddr.
// One clk domain. Accepted Avalon reads survive reset/timeout until drained.
// No storage write is retired on a timer; the existing loader owns completion.
module hangzo_ddr_rom #(
    parameter [26:0] IMAGE_BYTES=27'h0c00000,
    parameter [28:0] DDR_BASE=29'h6000000,
    parameter integer WATCHDOG_BITS=25
)(
    input wire clk,reset,
    input wire hps_download,hps_wr,
    input wire [15:0] hps_index,
    input wire [26:0] hps_addr,
    input wire [7:0] hps_data,
    output wire hps_wait,
    output wire loader_download,loader_wr,
    output wire [15:0] loader_index,
    output wire [26:0] loader_addr,
    output wire [7:0] loader_data,
    input wire loader_wait,memory_ready,image_ready,load_error,
    input wire ddr_grant,ddr_busy,ddr_data_ready,
    input wire [63:0] ddr_data,
    output wire ddr_rd,
    output wire [28:0] ddr_addr,
    output wire [7:0] ddr_burstcnt,
    output wire load_claim,reader_drained,
    output reg copy_done,fault,
    output reg [26:0] copied_bytes
);
    localparam [3:0] IDLE=0,HOLD=1,READY=2,REQUEST=3,RESPONSE=4,
        EMIT=5,GAP=6,DRAIN=7,ABORT_WAIT=8;
    reg [3:0] state;
    reg previous_rom;
    reg [63:0] buffer;
    reg [WATCHDOG_BITS-1:0] idle_count;
    wire rom_download=hps_download && hps_index==16'd0;
    wire start=rom_download && !previous_rom;
    wire fast_start=state==IDLE && start && hps_addr!=0;
    wire owns=state!=IDLE || fast_start;
    wire emit=state==EMIT && !loader_wait && !reset;
    assign load_claim=owns;
    assign reader_drained=state==IDLE && !fast_start;
    // HOLD permits Main to finish its DDR copy and send download-end.
    // A timed-out accepted read retains ownership but releases the HPS wait.
    assign hps_wait=owns ? (state!=HOLD && state!=ABORT_WAIT && !fast_start) : loader_wait;
    assign loader_download=owns ? (!reset && state!=DRAIN && state!=ABORT_WAIT) : hps_download;
    assign loader_index=owns ? 16'd0 : hps_index;
    assign loader_wr=owns ? emit : hps_wr;
    assign loader_addr=owns ? copied_bytes : hps_addr;
    assign loader_data=owns ? buffer[{copied_bytes[2:0],3'b000}+:8] : hps_data;
    assign ddr_rd=state==REQUEST && ddr_grant && !reset;
    assign ddr_addr=DDR_BASE+{5'd0,copied_bytes[26:3]};
    assign ddr_burstcnt=8'd1;
    always @(posedge clk)begin
        previous_rom<=rom_download;
        copy_done<=0;
        if(reset)begin
            previous_rom<=0;copy_done<=0;copied_bytes<=0;idle_count<=0;buffer<=0;fault<=0;
            // An unaccepted command can be withdrawn. An accepted read cannot.
            if(state==RESPONSE || state==ABORT_WAIT)
                state<=ddr_data_ready ? IDLE : ABORT_WAIT;
            else state<=IDLE;
        end else begin
            if(state!=IDLE && state!=HOLD && state!=ABORT_WAIT)idle_count<=idle_count+1'b1;
            case(state)
                IDLE:begin
                    idle_count<=0;
                    if(fast_start)begin
                        copied_bytes<=0;fault<=hps_addr!=IMAGE_BYTES || hps_wr;
                        state<=HOLD;
                    end
                end
                HOLD:begin
                    if(hps_wr || (hps_download && hps_index!=0))fault<=1;
                    if(!hps_download)state<=fault ? DRAIN : READY;
                end
                READY:if(memory_ready && ddr_grant)begin state<=REQUEST;idle_count<=0;end
                REQUEST:if(ddr_rd && !ddr_busy)begin
                    idle_count<=0;
                    if(ddr_data_ready)begin buffer<=ddr_data;state<=EMIT;end
                    else state<=RESPONSE;
                end
                RESPONSE:if(ddr_data_ready)begin buffer<=ddr_data;state<=EMIT;idle_count<=0;end
                EMIT:if(emit)begin
                    copied_bytes<=copied_bytes+27'd1;idle_count<=0;
                    state<=copied_bytes+27'd1==IMAGE_BYTES ? DRAIN : GAP;
                end
                GAP:state<=copied_bytes[2:0]==0 ? REQUEST : EMIT;
                DRAIN:if(image_ready || load_error)begin
                    copy_done<=image_ready && !load_error && !fault;
                    fault<=fault || load_error;state<=IDLE;
                end
                ABORT_WAIT:if(ddr_data_ready)state<=IDLE;
                default:begin state<=IDLE;fault<=1;end
            endcase
            // A timeout rejects the entire image, never skips a byte or read.
            // RESPONSE owns one accepted command, including on its timeout edge.
            if(&idle_count && state!=IDLE && state!=HOLD && state!=ABORT_WAIT)begin
                fault<=1;idle_count<=0;
                state<=((state==RESPONSE && !ddr_data_ready) ||
                        (state==REQUEST && ddr_rd && !ddr_busy && !ddr_data_ready)) ? ABORT_WAIT : DRAIN;
            end
        end
    end
`ifdef SIMULATION
    initial begin
        state=IDLE;previous_rom=0;copy_done=0;fault=0;copied_bytes=0;idle_count=0;buffer=0;
        if(IMAGE_BYTES==0 || IMAGE_BYTES[0] || WATCHDOG_BITS<2)
            $fatal(1,"Invalid DDR replay image/watchdog profile");
    end
`endif
endmodule
