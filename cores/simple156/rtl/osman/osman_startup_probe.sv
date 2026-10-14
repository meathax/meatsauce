// SPDX-License-Identifier: GPL-3.0-or-later
// Read-only UIO 0x7e00: signature, then sixteen snapshot words, low word first.
module osman_startup_probe (
    input wire clk,global_reset,
    inout wire [35:0] ext_bus,
    input wire [15:0] flags,ioctl_index,
    input wire [7:0] profile,
    input wire [26:0] ioctl_addr,
    input wire [23:0] accepted_words,memory_writes,
    input wire commit_valid,
    input wire [25:0] commit_addr,
    input wire [31:0] commit_data,raster_frame
);
    reg have_command=0,selected=0;
    reg [15:0] reply=0;
    reg [255:0] snapshot=0;
    reg [31:0] commit_count=0,last_addr=0,last_data=0;
    wire enable=ext_bus[34],strobe=ext_bus[33];
    assign ext_bus[32]=enable && selected;
    assign ext_bus[15:0]=reply;
    always @(posedge clk) begin
        if(global_reset || (flags[9] && ioctl_index==0)) begin
            commit_count<=0;last_addr<=0;last_data<=0;
        end else if(commit_valid) begin
            commit_count<=commit_count+1'b1;
            last_addr<={6'd0,commit_addr};last_data<=commit_data;
        end
        // This decoder stays accessible while the game is held in global reset.
        if(!enable) begin have_command<=0;selected<=0;end
        else if(strobe) begin
            if(!have_command) begin
                have_command<=1;selected<=ext_bus[31:16]==16'h7e00;
                reply<=16'h156d;
                snapshot<={raster_frame[15:0],last_data,last_addr,commit_count,
                    8'd0,memory_writes,8'd0,accepted_words,5'd0,ioctl_addr,
                    ioctl_index,8'd0,profile,flags};
            end else if(selected) begin
                reply<=snapshot[15:0];snapshot<=snapshot>>16;
            end
        end
    end
endmodule
