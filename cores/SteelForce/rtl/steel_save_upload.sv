// SPDX-License-Identifier: GPL-3.0-or-later
// One firmware NVRAM file: immutable validity header and complete-file commit.
module steel_save_upload(
    input wire clk,reset,mortalr,score_valid,
    input wire ioctl_upload,ioctl_download,ioctl_rd,
    input wire [15:0] ioctl_index,
    input wire [26:0] ioctl_addr,
    input wire [7:0] nv_bytes,score_bytes,
    input wire nv_wait,nv_request,score_request,
    input wire score_hold,                 // hold byte 128 until this OSD session's score extraction has finished
    output wire uploading,score_uploading,pause_upload,complete_upload,
    output wire ioctl_wait,ioctl_upload_req,
    output wire [7:0] ioctl_dout
);
    reg upload_last=0,score_request_last=0,pending=0;
    reg frozen_valid=0,frozen_mortalr=0;
    reg [7:0] count=0;
    reg bad=0;
    reg [26:0] address_q0=0,address_q1=0,address_q2=0;
    assign uploading=ioctl_upload && ioctl_index==16'd2;
    wire begin_upload=uploading && !upload_last;
    wire score_event=score_request && !score_request_last;
    wire new_request=nv_request || score_event;
    wire active_mortalr=upload_last ? frozen_mortalr : mortalr;
    wire active_valid=upload_last ? frozen_valid : score_valid;
    wire [7:0] size=frozen_mortalr ? 8'd128 : 8'd180;
    wire [7:0] expected=begin_upload ? 8'd0 : count;
    assign score_uploading=uploading && !active_mortalr && active_valid && ioctl_addr>=129 && ioctl_addr<180;
    assign pause_upload=uploading;
    assign complete_upload=upload_last && count==size && !bad;
    assign ioctl_wait=nv_wait || (score_uploading && ioctl_addr!=address_q2) ||
        (uploading && ioctl_addr==27'd128 && score_hold);
    assign ioctl_upload_req=pending && !ioctl_upload && !ioctl_download;
    assign ioctl_dout=ioctl_index!=2 ? 8'hff : ioctl_addr<128 ? nv_bytes :
        ioctl_addr==128 && !active_mortalr ? {7'b0,active_valid} : score_uploading ? score_bytes : 8'b0;
    always @(posedge clk)begin
        address_q0<=ioctl_addr;address_q1<=address_q0;address_q2<=address_q1;
        upload_last<=uploading;score_request_last<=score_request;
        if(reset)begin
            upload_last<=0;score_request_last<=0;pending<=0;
            count<=0;bad<=0;frozen_valid<=0;frozen_mortalr<=0;
            address_q0<=0;address_q1<=0;address_q2<=0;
        end else begin
            if(new_request)pending<=1;
            if(begin_upload)begin
                count<=0;bad<=0;
                frozen_valid<=score_valid;frozen_mortalr<=mortalr;
            end
            // The validity byte (128) and score bytes follow the score state at byte 128, which is read only
            // after score_hold releases (the extraction started by this OSD opening has finished).
            if(uploading && ioctl_addr<=27'd128 && !ioctl_wait)frozen_valid<=score_valid;
            if(uploading && ioctl_rd && !ioctl_wait)begin
                if(ioctl_addr!={19'b0,expected} || expected>=(begin_upload ? (mortalr ? 8'd128 : 8'd180) : size))bad<=1;
                else count<=expected+1'b1;
            end
            if(!uploading && upload_last)
                pending<=!complete_upload || new_request;
        end
    end
endmodule
