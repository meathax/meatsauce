// SPDX-License-Identifier: GPL-3.0-or-later
// Byte-lane RAM idiom adapted from Batman rtl/video/batman_vram.sv at
// 34783858f6e1511e299ef159d6316544934f8fb5 (Skull & Crossbones core authors,
// GPL-3.0-or-later). Donor slot schedule is not used.
// ThunderJaws shared SRAM: 64KiB at 160000..16ffff in BOTH CPU maps.
// One synchronous port, serialized by thunderjaws_cpu_arbiter. Initial FPGA
// configuration image is zero; resets cancel response state, not stored RAM.
module thunderjaws_shared_ram (
    input wire clk_sys,init_reset,request_valid,
    output wire request_ready,
    input wire [14:0] word_address,
    input wire request_read,
    input wire [1:0] request_lanes,
    input wire [15:0] request_data,
    output reg response_valid,
    output reg [15:0] response_data
);
    reg [7:0] ram_hi[0:32767];
    reg [7:0] ram_lo[0:32767];
    integer i;
    initial for(i=0;i<32768;i=i+1) begin ram_hi[i]=0;ram_lo[i]=0;end
    assign request_ready=!init_reset;
    always @(posedge clk_sys) begin
        response_valid<=0;
        if(init_reset) response_data<=0;
        else if(request_valid) begin
            response_valid<=1;
            if(request_read) response_data<={ram_hi[word_address],ram_lo[word_address]};
            else begin
                response_data<=0;
                if(request_lanes[1]) ram_hi[word_address]<=request_data[15:8];
                if(request_lanes[0]) ram_lo[word_address]<=request_data[7:0];
            end
        end
    end
endmodule
