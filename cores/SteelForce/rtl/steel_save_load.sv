// SPDX-License-Identifier: GPL-3.0-or-later
// Validate one complete firmware file before either persistence donor sees it.
// SF accepts its 128-byte factory EEPROM or 180-byte combined save; MR: 128.
module steel_save_load(
    input wire clk,reset,mortalr,ioctl_download,ioctl_wr,
    input wire [15:0] ioctl_index,
    input wire [26:0] ioctl_addr,
    input wire [7:0] ioctl_din,
    input wire nv_wait,nv_hold,
    output wire ioctl_wait,cpu_hold,
    output reg load_error=0,load_commit=0,score_valid=0,
    output wire nv_download,nv_wr,score_download,score_wr,
    output wire [7:0] replay_addr,replay_data
);
    localparam IDLE=0,RECEIVE=1,NV_OPEN=2,NV_READ=3,NV_SEND=4,
        NV_FINISH=5,SCORE_OPEN=6,SCORE_READ=7,SCORE_SEND=8,DONE=9;
    reg [3:0] state=IDLE;
    reg [7:0] staged[0:179];
    reg [7:0] count=0,pointer=0,data=0;
    reg bad=0,profile=0,valid=0;
    wire downloading=ioctl_download && ioctl_index==16'd2;
    wire replaying=state!=IDLE && state!=RECEIVE;
    assign ioctl_wait=replaying || (downloading && state!=RECEIVE);
    assign cpu_hold=state!=IDLE || downloading || load_error;
    assign nv_download=state==NV_OPEN || state==NV_READ || state==NV_SEND;
    assign nv_wr=state==NV_SEND && !nv_wait;
    assign score_download=state==SCORE_OPEN || state==SCORE_READ || state==SCORE_SEND;
    assign score_wr=state==SCORE_SEND;
    assign replay_addr=score_download ? pointer-8'd129 : pointer;
    assign replay_data=data;
    always @(posedge clk)begin
        load_commit<=0;
        if(reset)begin
            state<=IDLE;count<=0;pointer<=0;data<=0;bad<=0;
            profile<=0;valid<=0;score_valid<=0;load_error<=0;
        end else case(state)
            IDLE:if(downloading)begin
                state<=RECEIVE;count<=0;bad<=0;profile<=mortalr;valid<=0;
            end
            RECEIVE:begin
                if(downloading && ioctl_wr)begin
                    if(ioctl_addr!={19'b0,count} || count>=180 || (profile && count>=128))bad<=1;
                    else begin
                        staged[count]<=ioctl_din;count<=count+1'b1;
                        if(count==128)begin valid<=ioctl_din[0];if(ioctl_din>1)bad<=1;end
                    end
                end
                if(!downloading)begin
                    if(!bad && (count==128 || (!profile && count==180)))begin
                        state<=NV_OPEN;pointer<=0;load_error<=0;
                    end else begin state<=IDLE;load_error<=1;end
                end
            end
            NV_OPEN:state<=NV_READ;
            NV_READ:begin data<=staged[pointer];state<=NV_SEND;end
            NV_SEND:if(!nv_wait)begin
                if(pointer==127)state<=NV_FINISH;
                else begin pointer<=pointer+1'b1;state<=NV_READ;end
            end
            NV_FINISH:if(!nv_hold)begin
                if(count==180 && valid)begin state<=SCORE_OPEN;pointer<=129;end
                else state<=DONE;
            end
            SCORE_OPEN:state<=SCORE_READ;
            SCORE_READ:begin data<=staged[pointer];state<=SCORE_SEND;end
            SCORE_SEND:begin
                if(pointer==179)state<=DONE;
                else begin pointer<=pointer+1'b1;state<=SCORE_READ;end
            end
            DONE:begin
                score_valid<=count==180 && valid;load_commit<=1;state<=IDLE;
            end
            default:begin state<=IDLE;load_error<=1;end
        endcase
    end
endmodule
