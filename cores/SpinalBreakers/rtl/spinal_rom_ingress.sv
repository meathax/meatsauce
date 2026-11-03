// SPDX-License-Identifier: GPL-3.0-or-later
// Download service with an ordered last-word readback before game release.
// Read and write ports are held transactions; platform arbitration must drain
// accepted transactions before ownership changes or controller reinitializes.
module spinal_rom_ingress #(parameter integer IMAGE_BYTES=25'h07ac000) (
    input logic clk,reset,ioctl_download,ioctl_wr,
    input logic [15:0] ioctl_index,input logic [26:0] ioctl_addr,input logic [7:0] ioctl_data,
    output wire ioctl_wait,write_request,output wire [24:0] write_address,
    output wire [15:0] write_data,input logic write_ack,
    output wire read_request,output wire [24:0] read_address,
    input logic read_ready,input logic [63:0] read_data,
    output wire image_acknowledged,image_verified,download_error,fence_fault,invalidate_cache
);
    spinal_rom_loader #(.IMAGE_BYTES(IMAGE_BYTES)) loader(
        .clk(clk),.reset(reset),.ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),
        .ioctl_index(ioctl_index),.ioctl_addr(ioctl_addr),.ioctl_data(ioctl_data),.ioctl_wait(ioctl_wait),
        .write_request(write_request),.write_address(write_address),.write_data(write_data),.write_ack(write_ack),
        .image_acknowledged(image_acknowledged),.download_error(download_error),.invalidate_cache(invalidate_cache));
    spinal_rom_fence fence(.clk(clk),.reset(reset),.download_active(ioctl_download && ioctl_index==0),
        .image_acknowledged(image_acknowledged),.write_request(write_request),.write_ack(write_ack),
        .write_address(write_address),.write_data(write_data),.backend_request(read_request),.backend_address(read_address),
        .backend_ready(read_ready),.backend_data(read_data),.image_verified(image_verified),.fault(fence_fault));
endmodule
