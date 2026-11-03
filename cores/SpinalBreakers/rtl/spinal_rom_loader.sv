// SPDX-License-Identifier: GPL-3.0-or-later
// Candidate index-0 HPS byte stream to held full-word backend writes. This is
// independent of game reset; image_acknowledged means all expected writes
// were acknowledged, not that physical SDRAM readback has been verified.
module spinal_rom_loader #(parameter integer IMAGE_BYTES=25'h07ac000) (
    input logic clk,reset,
    input logic ioctl_download,ioctl_wr,
    input logic [15:0] ioctl_index,
    input logic [26:0] ioctl_addr,
    input logic [7:0] ioctl_data,
    output wire ioctl_wait,
    output wire write_request,
    output wire [24:0] write_address,
    output wire [15:0] write_data,
    input logic write_ack,
    output logic image_acknowledged,
    output logic download_error,
    output wire invalidate_cache
);
    logic [24:0] fifo_address[0:3];
    logic [15:0] fifo_data[0:3];
    logic [1:0] rd_ptr=0,wr_ptr=0;
    logic [2:0] count=0;
    logic wait_low=0,active_d=0,ended=0,aborted=0,half=0;
    logic [24:0] next_byte=0;
    logic [7:0] even_byte;
    wire active=ioctl_download && ioctl_index==0;
    wire begin_stream=active && !active_d;
    wire end_stream=!active && active_d;
    wire pop=count!=0 && !wait_low && write_ack;
    wire byte_ok=active && ioctl_wr && !reset && !begin_stream && !aborted && !download_error &&
                 ioctl_addr=={2'b00,next_byte} && next_byte<IMAGE_BYTES;
    wire push=byte_ok && next_byte[0] && (count<4 || pop);
    // Leave one word of skid space for bytes already in the HPS pipeline.
    assign ioctl_wait=active && count>=3 && !aborted && !download_error;
    assign write_request=count!=0 && !wait_low;
    assign write_address=fifo_address[rd_ptr];
    assign write_data=fifo_data[rd_ptr];
    assign invalidate_cache=!image_acknowledged || active || reset;

    initial begin image_acknowledged=0;download_error=0;end
    always_ff @(posedge clk) begin
        active_d<=active;
        if(reset) begin
            image_acknowledged<=0;
            if(active || count!=0 || wait_low) begin aborted<=1;download_error<=1;end
        end
        if(begin_stream) begin
            image_acknowledged<=0;ended<=0;
            if(!reset && count==0 && !wait_low && !write_ack) begin
                next_byte<=0;half<=0;aborted<=0;download_error<=0;
            end else begin aborted<=1;download_error<=1;end
        end
        if(active && ioctl_wr && !begin_stream && !aborted && !download_error && !reset) begin
            if(!byte_ok || (next_byte[0] && count==4 && !pop)) begin
                aborted<=1;download_error<=1;
            end else begin
                next_byte<=next_byte+1'b1;
                if(!next_byte[0]) begin even_byte<=ioctl_data;half<=1;end
                else half<=0;
            end
        end
        if(push) begin
            fifo_address[wr_ptr]<=next_byte-1'b1;
            fifo_data[wr_ptr]<={ioctl_data,even_byte};
            wr_ptr<=wr_ptr+1'b1;
        end
        if(pop) begin rd_ptr<=rd_ptr+1'b1;wait_low<=1;end
        else if(wait_low && !write_ack) wait_low<=0;
        case({push,pop})
            2'b10:count<=count+1'b1;
            2'b01:count<=count-1'b1;
            default:count<=count;
        endcase
        if(end_stream) ended<=1;
        if(ended && !active && count==0 && !wait_low && !write_ack && !reset) begin
            if(!aborted && !download_error && next_byte==IMAGE_BYTES && !half) image_acknowledged<=1;
            else download_error<=1;
            ended<=0;
        end
    end
endmodule
