// SPDX-License-Identifier: GPL-3.0-or-later
// Main_MiSTer index-4 transport for the board's single physical SRAM.
// No second memory: byte restores and prefetched upload words use backup bus.
module cs_nvram_host #(parameter WORD_BITS=14) (
    input logic clk, memory_reset, osd_open, cpu_quiet, nvram_written,
    input logic ioctl_download, ioctl_upload, ioctl_wr, ioctl_rd,
    input logic [15:0] ioctl_index,
    input logic [26:0] ioctl_addr,
    input logic [7:0] ioctl_dout,
    output logic [7:0] ioctl_din,
    output logic ioctl_wait, ioctl_upload_req, pause_cpu, dirty,
    output logic restore_reset=0,
    output logic backup_valid, backup_write,
    input logic backup_ready, backup_rsp_valid,
    output logic [13:0] backup_address,
    output logic [31:0] backup_data,
    output logic [3:0] backup_strobe,
    input logic [31:0] backup_rsp_data
);
    localparam BYTES=1<<(WORD_BITS+2);
    typedef enum logic [1:0] {IDLE,SEND,RESPONSE} state_t;
    state_t state;
    logic [13:0] address, cached_address;
    logic [31:0] data, cached_data;
    logic [3:0] strobe;
    logic write_request, cache_valid, saving, osd_previous, upload_previous;
    logic upload_invalid;
    logic [WORD_BITS+2:0] upload_count;
    logic [26:0] previous_address;
    logic [2:0] quiet_pad;
    // A completed index-4 restore restarts the game so it never keeps state
    // it derived from pre-restore (zeroed) SRAM while the file was loading.
    logic restoring_previous, restore_pending;
    logic [3:0] restore_count;
    // Accepted board writes include address decode/arbitration. Capture that
    // event before save control; delay OSD by the same edge so a coincident
    // write/open still starts a save. CPU quiescence remains a live handshake.
    // The extra register stage keeps the arbiter-derived write strobe off the save-control logic.
    logic nvram_written_s, osd_open_s, nvram_written_q, osd_open_q;
    wire selected=ioctl_index==16'd4;
    wire in_range=ioctl_addr<27'(BYTES);
    wire restoring=selected && ioctl_download;
    wire uploading=selected && ioctl_upload;
    wire cache_hit=cache_valid && cached_address==14'(ioctl_addr[WORD_BITS+1:2]);
    assign pause_cpu=saving || restoring || uploading;
    assign backup_valid=state==SEND && cpu_quiet && !memory_reset;
    assign backup_write=write_request;
    assign backup_address=address;
    assign backup_data=data;
    assign backup_strobe=strobe;
    assign ioctl_wait=state!=IDLE || (uploading && in_range && !cache_hit);
    assign ioctl_din=selected && in_range && cache_hit ?
                    8'(cached_data>>(ioctl_addr[1:0]*8)) : 8'd0;
    always_ff @(posedge clk) begin
        if(memory_reset) begin
            state<=IDLE;address<=0;data<=0;strobe<=0;write_request<=0;
            cached_address<=0;cached_data<=0;cache_valid<=0;
            saving<=0;osd_previous<=0;upload_previous<=0;upload_invalid<=0;
            upload_count<=0;previous_address<=0;quiet_pad<=0;
            ioctl_upload_req<=0;dirty<=0;
            nvram_written_s<=0;osd_open_s<=0;nvram_written_q<=0;osd_open_q<=0;
            restoring_previous<=0;restore_pending<=0;restore_count<=0;restore_reset<=0;
        end else begin
            restoring_previous<=restoring;
            if(restoring_previous && !restoring) restore_pending<=1;
            if(restore_pending && state==IDLE && !restoring) begin
                restore_pending<=0;restore_reset<=1;restore_count<=4'd15;
            end else if(restore_reset) begin
                if(restore_count==0) restore_reset<=0;
                else restore_count<=restore_count-1'b1;
            end
            nvram_written_s<=nvram_written;osd_open_s<=osd_open;
            nvram_written_q<=nvram_written_s;osd_open_q<=osd_open_s;
            osd_previous<=osd_open_q;upload_previous<=uploading;
            previous_address<=ioctl_addr;
            if(nvram_written_q) begin dirty<=1;cache_valid<=0;end
            if(osd_open_q && !osd_previous && (dirty || nvram_written_q)) begin
                saving<=1;quiet_pad<=0;
            end
            if(saving && !ioctl_upload_req && !uploading) begin
                if(!cpu_quiet) quiet_pad<=0;
                else if(quiet_pad==4) ioctl_upload_req<=1;
                else quiet_pad<=quiet_pad+1'b1;
            end
            if(uploading) begin
                saving<=1;ioctl_upload_req<=0;
                if(!upload_previous) begin
                    upload_count<=0;upload_invalid<=0;cache_valid<=0;
                    // hps_io pulses ioctl_rd on upload start to prime byte 0.
                    // It is not a byte consumed by FIO_FILE_TX_DAT.
                end else if(ioctl_rd) begin
                    // hps_io advances ioctl_addr when consuming DIN, one edge
                    // before this strobe is observed. Use the served address.
                    if(previous_address==27'(upload_count) &&
                       upload_count<(WORD_BITS+3)'(BYTES)) upload_count<=upload_count+1'b1;
                    else upload_invalid<=1;
                end
            end
            if(!uploading && upload_previous) begin
                saving<=0;ioctl_upload_req<=0;cache_valid<=0;
                if(!upload_invalid && upload_count==(WORD_BITS+3)'(BYTES) &&
                   !nvram_written_q) dirty<=0;
            end
            case(state)
                IDLE: begin
                    if(restoring && ioctl_wr && in_range) begin
                        address<=14'(ioctl_addr[WORD_BITS+1:2]);
                        data<=32'(ioctl_dout)<<(ioctl_addr[1:0]*8);
                        strobe<=4'b0001<<ioctl_addr[1:0];
                        write_request<=1;cache_valid<=0;state<=SEND;
                    end else if(uploading && in_range && !cache_hit && cpu_quiet) begin
                        address<=14'(ioctl_addr[WORD_BITS+1:2]);
                        data<=0;strobe<=0;write_request<=0;state<=SEND;
                    end
                end
                SEND: if(backup_ready && cpu_quiet) state<=RESPONSE;
                RESPONSE: if(backup_rsp_valid) begin
                    if(!write_request) begin
                        cached_address<=address;cached_data<=backup_rsp_data;cache_valid<=1;
                    end
                    state<=IDLE;
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
