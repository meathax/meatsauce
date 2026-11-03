// SPDX-License-Identifier: GPL-3.0-or-later
// CPU side of ThunderJaws 2048x16 palette at3e0000..3e0fff (MAME0.289).
// Byte-array RAM idiom adapted from pinned Batman batman_cram.sv.
// Independent registered renderer read, with explicit byte-write forwarding
// for a same-address CPU collision. No mixed-port RAM value is trusted then.
module thunderjaws_palette_ram #(parameter integer SNAPSHOT_ENABLE=0) (
    input wire clk_sys,init_reset,request_valid,
    input wire snapshot_start,
    output wire snapshot_initialized,snapshot_fault,
    output wire request_ready,
    input wire [10:0] word_address,
    input wire request_read,
    input wire [1:0] request_lanes,
    input wire [15:0] request_data,
    output reg response_valid,
    output wire [15:0] response_data,
    input wire [10:0] render_address,
    output wire [15:0] render_data
);
    reg [7:0] hi[0:2047],lo[0:2047];
    integer i;
    initial for(i=0;i<2048;i=i+1)begin hi[i]=0;lo[i]=0;end
    reg [7:0] render_hi,render_lo;
    reg [1:0] forward_lanes;
    reg [15:0] forward_data;
    reg [15:0] live_response_data;
    generate if(SNAPSHOT_ENABLE!=0)begin:snapshot
    wire accept=request_valid && request_ready;
    thunderjaws_snapshot_ram #(.ADDRESS_BITS(11)) storage(.clk(clk_sys),.init_reset(init_reset),.snapshot_start(snapshot_start),
        .initialized(snapshot_initialized),.a_ready(request_ready),.fault(snapshot_fault),
        .a_enable(accept),.a_write(!request_read),.a_address(word_address),.a_lanes(request_lanes),.a_write_data(request_data),.a_data(response_data),
        .b_enable(1'b1),.b_snapshot(1'b1),.b_address(render_address),.b_data(render_data));
    always @(posedge clk_sys)response_valid<=!init_reset && accept;
    end else begin:live
    assign snapshot_initialized=!init_reset;assign snapshot_fault=0;
    assign response_data=live_response_data;
    always @(posedge clk_sys)begin
        render_hi<=hi[render_address];render_lo<=lo[render_address];
        forward_lanes<=!init_reset && request_valid && !request_read && word_address==render_address ? request_lanes : 2'b00;
        forward_data<=request_data;
    end
    assign render_data={forward_lanes[1] ? forward_data[15:8] : render_hi,
                        forward_lanes[0] ? forward_data[7:0] : render_lo};
    assign request_ready=!init_reset;
    always @(posedge clk_sys)begin
        response_valid<=0;
        if(init_reset)live_response_data<=0;
        else if(request_valid)begin
            response_valid<=1;
            live_response_data<={hi[word_address],lo[word_address]};
            if(!request_read)begin
                if(request_lanes[1])hi[word_address]<=request_data[15:8];
                if(request_lanes[0])lo[word_address]<=request_data[7:0];
            end
        end
    end
    end endgenerate
endmodule
