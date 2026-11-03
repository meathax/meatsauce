// SPDX-License-Identifier: GPL-3.0-or-later
// Single-clock ROM download and three-client memory service. The controller
// must not be reinitialized while an accepted physical transaction is live.
module spinal_platform_memory #(parameter integer IMAGE_BYTES=25'h07ac000) (
    input logic clk,reset,ioctl_download,ioctl_wr,
    input logic [15:0] ioctl_index,input logic [26:0] ioctl_addr,input logic [7:0] ioctl_data,
    output wire ioctl_wait,game_reset,invalidate,download_error,fence_fault,image_acknowledged,
    output wire port0_idle,port1_idle,port2_idle,
    input logic main_req,sound_req,sample_req,
    input logic [24:0] main_addr,sound_addr,sample_addr,
    output wire main_ready,sound_ready,sample_ready,
    output wire [63:0] main_data,sound_data,sample_data,
    output wire [2:0] physical_req,physical_write,
    output wire [74:0] physical_addr,output wire [47:0] physical_data,
    input logic [2:0] physical_ack,input logic [191:0] physical_reply
);
    wire wr,wr_ack,fr,fr_ready,verified,loader_invalidate;
    wire [24:0] wa,fa;wire [15:0] wd;wire [63:0] fd;
    assign game_reset=reset || !verified || download_error || fence_fault;
    assign invalidate=loader_invalidate || !verified;
    spinal_rom_ingress #(.IMAGE_BYTES(IMAGE_BYTES)) ingress(.clk(clk),.reset(reset),
        .ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),.ioctl_index(ioctl_index),.ioctl_addr(ioctl_addr),
        .ioctl_data(ioctl_data),.ioctl_wait(ioctl_wait),.write_request(wr),.write_address(wa),.write_data(wd),.write_ack(wr_ack),
        .read_request(fr),.read_address(fa),.read_ready(fr_ready),.read_data(fd),.image_acknowledged(image_acknowledged),
        .image_verified(verified),.download_error(download_error),.fence_fault(fence_fault),.invalidate_cache(loader_invalidate));
    wire [2:0] req,ready,write;wire [24:0] a0,a1;wire [15:0] d0;wire [63:0] q0,q1,q2;
    wire arbiter0_idle,arbiter1_idle,transport0_idle,transport1_idle,transport2_idle;
    assign port0_idle=arbiter0_idle && transport0_idle;
    assign port1_idle=arbiter1_idle && transport1_idle;
    assign port2_idle=transport2_idle;
    wire main_r,sound_r,sample_r;
    assign main_ready=main_r && !game_reset;assign sound_ready=sound_r && !game_reset;assign sample_ready=sample_r && !game_reset;
    assign sample_data=q2;
    spinal_memory_arbiter p0(.clk(clk),.reset(reset),.request0(wr),.request1(main_req && !game_reset),
        .address0(wa),.address1(main_addr),.write0(1'b1),.write1(1'b0),.write_data0(wd),.write_data1(16'b0),
        .ready0(wr_ack),.ready1(main_r),.data0(),.data1(main_data),.backend_request(req[0]),.backend_address(a0),
        .backend_write(write[0]),.backend_write_data(d0),.backend_ready(ready[0]),.backend_data(q0),.idle(arbiter0_idle));
    spinal_rom_arbiter p1(.clk(clk),.reset(reset),.request0(fr),.request1(sound_req && !game_reset),
        .address0(fa),.address1(sound_addr),.ready0(fr_ready),.ready1(sound_r),.data0(fd),.data1(sound_data),
        .backend_request(req[1]),.backend_address(a1),.backend_ready(ready[1]),.backend_data(q1),.idle(arbiter1_idle));
    assign req[2]=sample_req && !game_reset;assign write[1]=1'b0;assign write[2]=1'b0;assign sample_r=ready[2];
    spinal_sdram_toggle_adapter t0(.clk(clk),.reset(reset),.request(req[0]),.write(write[0]),.address(a0),.write_data(d0),
        .ready(ready[0]),.idle(transport0_idle),.read_data(q0),.physical_request(physical_req[0]),.physical_address(physical_addr[24:0]),
        .physical_write_data(physical_data[15:0]),.physical_write(physical_write[0]),.physical_ack(physical_ack[0]),.physical_read_data(physical_reply[63:0]));
    spinal_sdram_toggle_adapter t1(.clk(clk),.reset(reset),.request(req[1]),.write(1'b0),.address(a1),.write_data(16'b0),
        .ready(ready[1]),.idle(transport1_idle),.read_data(q1),.physical_request(physical_req[1]),.physical_address(physical_addr[49:25]),
        .physical_write_data(physical_data[31:16]),.physical_write(physical_write[1]),.physical_ack(physical_ack[1]),.physical_read_data(physical_reply[127:64]));
    spinal_sdram_toggle_adapter t2(.clk(clk),.reset(reset),.request(req[2]),.write(1'b0),.address(sample_addr),.write_data(16'b0),
        .ready(ready[2]),.idle(transport2_idle),.read_data(q2),.physical_request(physical_req[2]),.physical_address(physical_addr[74:50]),
        .physical_write_data(physical_data[47:32]),.physical_write(physical_write[2]),.physical_ack(physical_ack[2]),.physical_read_data(physical_reply[191:128]));
endmodule
