// SPDX-License-Identifier: GPL-3.0-or-later
// Index 2: atomic 128-byte, big-endian 64x16 EEPROM load/save.
// The board dump port returns a word two clocks after its address changes.
// Saves pause serial traffic and allow the longest configured chip operation
// to finish before capturing a coherent immutable upload snapshot.
module steel_nvram #(
    parameter integer QUIET_CYCLES=364804
)(
    input wire clk,reset,new_image,
    input wire osd_status,autosave,save_button,
    input wire ioctl_download,ioctl_upload,ioctl_wr,ioctl_rd,upload_commit,
    input wire [15:0] ioctl_index,
    input wire [26:0] ioctl_addr,
    input wire [7:0] ioctl_din,
    output wire [7:0] ioctl_dout,
    output wire ioctl_wait,
    output reg upload_req,
    output wire cpu_hold,pause_request,
    output reg initialized,dirty,load_error,
    output wire [5:0] nv_addr,
    output wire nv_we,
    output wire [15:0] nv_din,
    input wire [15:0] nv_dout
);
    localparam INIT=0,SCAN=1,LOAD=2,COMMIT=3,QUIET=4,CAPTURE=5,BASELINE=6;
    reg [2:0] state=INIT;
    reg [5:0] word_index=0;
    reg [1:0] phase=0;
    reg [7:0] count=0;
    reg [18:0] quiet_left=0;
    reg [15:0] staged[0:63],saved[0:63],snapshot[0:63];
    reg [63:0] changed=0;
    reg download_last=0,upload_last=0,osd_last=0,save_last=0;
    reg save_pending=0,force_save=0,capture_changed=0;
    reg prepared=0,upload_last_byte=0;
    reg [7:0] upload_count=0;
    reg upload_bad=0;
    wire downloading=ioctl_download && ioctl_index==16'd2;
    wire uploading=ioctl_upload && ioctl_index==16'd2;
    wire load_begin=downloading && !download_last;
    wire upload_begin=uploading && !upload_last;
    wire upload_end=!uploading && upload_last;
    wire manual_save=save_button && !save_last;
    wire auto_save=autosave && osd_status && !osd_last;
    wire active_capture=state==QUIET || state==CAPTURE;
    assign cpu_hold=!initialized || downloading || state==LOAD || state==COMMIT || load_error;
    assign pause_request=active_capture;
    assign ioctl_wait=(downloading && state!=LOAD) || (uploading && !prepared);
    assign ioctl_dout=ioctl_addr<128 ?
        (ioctl_addr[0] ? snapshot[ioctl_addr[6:1]][7:0] : snapshot[ioctl_addr[6:1]][15:8]) : 8'hff;
    assign nv_addr=word_index;
    assign nv_we=(state==INIT || state==COMMIT) && phase==0 && !reset && !new_image;
    assign nv_din=state==INIT ? 16'hffff : staged[word_index];

    always @(posedge clk) begin
        download_last<=downloading;upload_last<=uploading;
        osd_last<=osd_status;save_last<=save_button;
        upload_req<=0;
        if(reset || new_image) begin
            state<=INIT;word_index<=0;phase<=0;count<=0;quiet_left<=0;
            initialized<=0;dirty<=0;load_error<=0;changed<=0;
            save_pending<=0;force_save<=0;capture_changed<=0;
            prepared<=0;upload_last_byte<=0;
            upload_count<=0;upload_bad<=0;
            download_last<=0;upload_last<=0;osd_last<=osd_status;save_last<=save_button;
        end else begin
            if(manual_save || auto_save) begin
                save_pending<=1;
                if(manual_save)force_save<=1;
            end
            if(upload_begin)begin
                upload_last_byte<=0;upload_count<=0;upload_bad<=0;
                if(!prepared)begin save_pending<=1;force_save<=1;end
            end
            if(uploading && prepared && ioctl_rd && !ioctl_wait)begin
                if(ioctl_addr!={19'b0,upload_count} || upload_count>=128)upload_bad<=1;
                else begin
                    upload_count<=upload_count+1'b1;
                    if(ioctl_addr==127 && !upload_bad)upload_last_byte<=1;
                end
            end
            if(load_begin) begin
                state<=LOAD;count<=0;phase<=0;word_index<=0;
                load_error<=0;prepared<=0;
                // The transport must wait for LOAD before sending byte zero.
            end else if(upload_end) begin
                prepared<=0;
                if(upload_last_byte && upload_count==128 && !upload_bad && upload_commit)begin
                    state<=BASELINE;word_index<=0;phase<=0;
                end
            end else case(state)
                INIT:begin
                    phase<=phase+1'b1;
                    if(phase==0)begin saved[word_index]<=16'hffff;snapshot[word_index]<=16'hffff;end
                    if(phase==3)begin
                        if(nv_dout!=16'hffff)load_error<=1;
                        if(word_index==63)begin state<=SCAN;initialized<=1;word_index<=0;end
                        else word_index<=word_index+1'b1;
                    end
                end
                LOAD:begin
                    if(downloading && ioctl_wr)begin
                        if(ioctl_addr!={19'b0,count} || count>=128)load_error<=1;
                        else begin
                            if(ioctl_addr[0])staged[ioctl_addr[6:1]][7:0]<=ioctl_din;
                            else staged[ioctl_addr[6:1]][15:8]<=ioctl_din;
                            count<=count+1'b1;
                        end
                    end
                    if(!downloading)begin
                        if(count==128 && !load_error)begin state<=COMMIT;phase<=0;word_index<=0;end
                        else begin state<=SCAN;load_error<=1;end
                    end
                end
                COMMIT:begin
                    phase<=phase+1'b1;
                    if(phase==0)begin
                        saved[word_index]<=staged[word_index];snapshot[word_index]<=staged[word_index];
                        changed[word_index]<=0;
                    end
                    if(phase==3)begin
                        if(nv_dout!=staged[word_index])load_error<=1;
                        if(word_index==63)begin state<=SCAN;initialized<=1;word_index<=0;dirty<=0;end
                        else word_index<=word_index+1'b1;
                    end
                end
                SCAN:begin
                    phase<=phase+1'b1;
                    if(phase==3)begin
                        changed[word_index]<=nv_dout!=saved[word_index];
                        word_index<=word_index+1'b1;
                        dirty<=|(changed & ~(64'b1<<word_index)) || nv_dout!=saved[word_index];
                    end
                    if(save_pending && !prepared)begin
                        state<=QUIET;quiet_left<=QUIET_CYCLES[18:0];phase<=0;word_index<=0;
                        capture_changed<=0;save_pending<=0;
                    end
                end
                QUIET:begin
                    if(quiet_left!=0)quiet_left<=quiet_left-1'b1;
                    else begin state<=CAPTURE;phase<=0;word_index<=0;end
                end
                CAPTURE:begin
                    phase<=phase+1'b1;
                    if(phase==3)begin
                        snapshot[word_index]<=nv_dout;
                        capture_changed<=capture_changed || nv_dout!=saved[word_index];
                        changed[word_index]<=nv_dout!=saved[word_index];
                        if(word_index==63)begin
                            dirty<=capture_changed || nv_dout!=saved[word_index];
                            state<=SCAN;word_index<=0;
                            if(capture_changed || nv_dout!=saved[word_index] || force_save || uploading)begin
                                prepared<=1;
                                if(!uploading)upload_req<=1;
                            end
                            force_save<=0;
                        end else word_index<=word_index+1'b1;
                    end
                end
                BASELINE:begin
                    saved[word_index]<=snapshot[word_index];changed[word_index]<=0;
                    if(word_index==63)begin state<=SCAN;word_index<=0;dirty<=0;phase<=0;end
                    else word_index<=word_index+1'b1;
                end
                default:begin state<=INIT;initialized<=0;end
            endcase
        end
    end
endmodule
