// SPDX-License-Identifier: GPL-3.0-or-later
// Capture MiSTer index-254 switch bytes atomically at the end of a transfer.
// Main sends its 64-bit switch word little-endian; this game uses bytes 0,1.
module spinal_mister_dips (
    input logic clk,cold_reset,ioctl_download,ioctl_wr,
    input logic [15:0] ioctl_index,input logic [26:0] ioctl_addr,input logic [7:0] ioctl_data,
    output logic [15:0] dips=16'hffff
);
    logic active_d=0;logic [1:0] seen=0;logic [7:0] low_byte,high_byte;
    wire active=ioctl_download && ioctl_index==16'd254;
    wire write_byte=ioctl_wr && ioctl_index==16'd254 && (active || active_d);
    wire write_low=write_byte && ioctl_addr==0;
    wire write_high=write_byte && ioctl_addr==1;
    always_ff @(posedge clk) begin
        active_d<=active;
        if(cold_reset)begin dips<=16'hffff;seen<=0;active_d<=0;end
        else begin
            if(active && !active_d)seen<={write_high,write_low};
            else begin
                if(write_low)seen[0]<=1;
                if(write_high)seen[1]<=1;
            end
            if(write_low)low_byte<=ioctl_data;
            if(write_high)high_byte<=ioctl_data;
            if(active_d && !active)begin
                if((seen[0] || write_low) && (seen[1] || write_high))
                    dips<={write_high ? ioctl_data : high_byte,write_low ? ioctl_data : low_byte};
                seen<=0;
            end
        end
    end
endmodule
