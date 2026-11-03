// SPDX-License-Identifier: GPL-3.0-or-later
// Main_MiSTer stages address=0x30000000 images before ending download.
// SteelForce/OSMAN replay pattern adapted to Penguin's shared toggle port.
// The unchanged loader owns endian conversion, graphics packing and RAM clear.
module penguin_fast_rom #(
    parameter integer WATCHDOG_BITS=25
)(
    input logic clk,reset,phase_reset,
    input logic hps_download,hps_wr,
    input logic [26:0] hps_addr,input logic [7:0] hps_data,
    output wire hps_wait,busy,
    output wire download,wr,output wire [26:0] addr,output wire [7:0] data,
    input logic core_wait,image_ready,load_error,port_ready,
    output logic error,
    output wire [25:0] preload_addr,output logic preload_req,
    input logic [63:0] preload_data,input logic preload_ack
);
    localparam logic [26:0] IMAGE_SIZE=27'h1300000;
    typedef enum logic [2:0] {IDLE,HOLD,COPY,DRAIN,FAILED} state_t;
    state_t state=IDLE;
    logic previous_download=0,valid=0,gap=0,reading=0;
    logic [26:0] length=0,position=0;
    logic [63:0] line_data=0;
    logic [WATCHDOG_BITS-1:0] watchdog=0;
    wire pending=preload_req!=preload_ack;
    wire fire=state==COPY && valid && !gap && !core_wait && position<length;
    assign busy=state==COPY||state==DRAIN;
    assign download=state==IDLE?hps_download:(state==HOLD||state==COPY);
    assign wr=state==IDLE?hps_wr:fire;
    assign addr=state==IDLE?hps_addr:position;
    assign data=state==IDLE?hps_data:line_data[position[2:0]*8+:8];
    assign hps_wait=(state==HOLD||state==FAILED)?1'b0:(state==IDLE?core_wait:1'b1);
    assign preload_addr={position[25:3],3'b000};
    always_ff @(posedge clk)begin
        previous_download<=hps_download;
        if(reset)begin
            state<=IDLE;previous_download<=0;valid<=0;gap<=0;
            length<=0;position<=0;line_data<=0;watchdog<=0;preload_req<=0;error<=0;reading<=0;
        end else begin
            case(state)
                IDLE:if(hps_download&&!previous_download)begin
                    error<=0;
                    if(hps_addr!=0)begin
                        state<=HOLD;length<=hps_addr;position<=0;valid<=0;gap<=0;watchdog<=0;reading<=0;
                    end
                end
                HOLD:if(!hps_download)begin
                    watchdog<=0;
                    if(length!=IMAGE_SIZE)begin state<=FAILED;error<=1;end
                    else state<=COPY;
                end
                COPY:begin
                    watchdog<=watchdog+1'b1;gap<=fire;
                    if(!valid&&!reading&&!pending&&position<length&&port_ready&&!core_wait)begin
                        preload_req<=~preload_req;reading<=1;
                    end
                    // A request is outstanding until the transport returns its
                    // matching phase. Position stays fixed throughout the read.
                    if(reading&&!pending)begin
                        line_data<=preload_data;valid<=1;reading<=0;watchdog<=0;
                    end
                    if(fire)begin
                        watchdog<=0;position<=position+1'b1;
                        if(position[2:0]==7)valid<=0;
                    end
                    if(load_error||&watchdog)begin state<=FAILED;error<=1;end
                    else if(position==length)begin state<=DRAIN;watchdog<=0;end
                end
                DRAIN:begin
                    watchdog<=watchdog+1'b1;
                    if(image_ready&&!pending)state<=IDLE;
                    else if(load_error||&watchdog)begin state<=FAILED;error<=1;end
                end
                // Release HPS on failure but retain an outstanding read's phase.
                // Never relabel its eventual response as a new image's data.
                FAILED:if(!pending&&!hps_download)state<=IDLE;
                default:begin state<=FAILED;error<=1;end
            endcase
            if(phase_reset)begin
                preload_req<=0;valid<=0;gap<=0;position<=0;watchdog<=0;reading<=0;
            end
        end
    end
endmodule
