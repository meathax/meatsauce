// SPDX-License-Identifier: GPL-3.0-or-later
// Existing CPU port plus EOF/PF1/PF2/alpha sharing one registered auxiliary
// port. A code read returns the attribute bank at the same word index/edge.
// CPU writes retain existing priority; deadline qualification is external.
module thunderjaws_video_ports #(parameter integer PACKED_ENABLE=0,SNAPSHOT_ENABLE=0) (
    input wire clk_sys,init_reset,
    input wire snapshot_start,
    output wire snapshot_initialized,snapshot_fault,
    input wire cpu_valid,
    output wire cpu_ready,
    input wire [14:0] cpu_address,
    input wire cpu_read,
    input wire [1:0] cpu_lanes,
    input wire [15:0] cpu_data,
    input wire attribute_enable,
    input wire [7:0] attribute_msb,attribute_lsb,
    output wire cpu_response_valid,
    output wire [15:0] cpu_response_data,
    input wire eof_valid,
    output wire eof_ready,
    input wire [14:0] eof_address,
    output wire eof_response_valid,
    output wire [15:0] eof_response_data,
    input wire pf1_fetch,pf2_fetch,alpha_fetch,
    input wire [14:0] pf1_address,pf2_address,alpha_address,
    output wire [15:0] pf1_code,pf1_attr,pf2_code,pf2_attr,alpha_data,
    output wire [2:0] late,
    input wire mo_valid,
    output wire mo_ready,
    input wire [14:0] mo_address,
    output wire mo_response_valid,
    output wire [63:0] mo_response_data
);
    wire [3:0] valid,ready,reply;
    wire [59:0] address;
    wire [31:0] reply_data,q1,q2,qa;
    wire memory_valid,memory_ready,memory_reply;
    wire memory_snapshot;
    wire client_reset=init_reset || !snapshot_initialized;
    wire [14:0] memory_address;
    wire [15:0] memory_data,memory_attr;
    assign valid[0]=eof_valid;
    assign address[14:0]=eof_address;
    assign eof_ready=ready[0];
    assign eof_response_valid=reply[0];
    assign eof_response_data=reply_data[15:0];
    thunderjaws_video_client pf1(.clk_sys(clk_sys),.init_reset(client_reset),.fetch(pf1_fetch),
        .fetch_address(pf1_address),.request_valid(valid[1]),.request_ready(ready[1]),
        .request_address(address[29:15]),.response_valid(reply[1]),.response_data(reply_data),.read_data(q1),.late(late[0]));
    thunderjaws_video_client pf2(.clk_sys(clk_sys),.init_reset(client_reset),.fetch(pf2_fetch),
        .fetch_address(pf2_address),.request_valid(valid[2]),.request_ready(ready[2]),
        .request_address(address[44:30]),.response_valid(reply[2]),.response_data(reply_data),.read_data(q2),.late(late[1]));
    thunderjaws_video_client alpha(.clk_sys(clk_sys),.init_reset(client_reset),.fetch(alpha_fetch),
        .fetch_address(alpha_address),.request_valid(valid[3]),.request_ready(ready[3]),
        .request_address(address[59:45]),.response_valid(reply[3]),.response_data(reply_data),.read_data(qa),.late(late[2]));
    assign pf1_code=q1[15:0];assign pf1_attr=q1[31:16];
    assign pf2_code=q2[15:0];assign pf2_attr=q2[31:16];assign alpha_data=qa[15:0];
    thunderjaws_video_arbiter arbiter(.clk_sys(clk_sys),.init_reset(client_reset),
        .request_valid(valid),.request_ready(ready),.request_address(address),
        .response_valid(reply),.response_data(reply_data),.backend_valid(memory_valid),
        .backend_ready(memory_ready),.backend_address(memory_address),.backend_snapshot(memory_snapshot),
        .backend_response_valid(memory_reply),.backend_response_data({memory_attr,memory_data}));
    generate if(PACKED_ENABLE!=0)begin:g_packed
    thunderjaws_video_ram_packed #(.SNAPSHOT_ENABLE(SNAPSHOT_ENABLE)) memory(.clk_sys(clk_sys),.init_reset(init_reset),
        .snapshot_start(snapshot_start),.aux_snapshot(memory_snapshot),.snapshot_initialized(snapshot_initialized),.snapshot_fault(snapshot_fault),
        .request_valid(cpu_valid),.request_ready(cpu_ready),.word_address(cpu_address),
        .request_read(cpu_read),.request_lanes(cpu_lanes),.request_data(cpu_data),
        .attribute_enable(attribute_enable),.attribute_msb(attribute_msb),.attribute_lsb(attribute_lsb),
        .response_valid(cpu_response_valid),.response_data(cpu_response_data),
        .aux_valid(memory_valid),.aux_ready(memory_ready),.aux_address(memory_address),
        .aux_response_valid(memory_reply),.aux_response_data(memory_data),.aux_attribute_data(memory_attr),
        .mo_valid(mo_valid),.mo_ready(mo_ready),.mo_address(mo_address),
        .mo_response_valid(mo_response_valid),.mo_response_data(mo_response_data));
    end else begin:g_words
    assign snapshot_initialized=!init_reset;assign snapshot_fault=0;
    assign mo_ready=0;assign mo_response_valid=0;assign mo_response_data=0;
    thunderjaws_video_ram memory(.clk_sys(clk_sys),.init_reset(init_reset),
        .request_valid(cpu_valid),.request_ready(cpu_ready),.word_address(cpu_address),
        .request_read(cpu_read),.request_lanes(cpu_lanes),.request_data(cpu_data),
        .attribute_enable(attribute_enable),.attribute_msb(attribute_msb),.attribute_lsb(attribute_lsb),
        .response_valid(cpu_response_valid),.response_data(cpu_response_data),
        .aux_valid(memory_valid),.aux_ready(memory_ready),.aux_address(memory_address),
        .aux_response_valid(memory_reply),.aux_response_data(memory_data),.aux_attribute_data(memory_attr));
    end endgenerate
endmodule
