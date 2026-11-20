// SPDX-License-Identifier: BSD-3-Clause
// Native MAME0.289 MB87078 register semantics, including retained control/data
// on warm reset. Gains are callback percentages (unity=100), not Q15 factors.
module gs_mb87078(
    input wire clk,cold_reset,reset,we,offset,input wire [7:0] data,
    output wire [7:0] rdata,
    output wire [6:0] gain_l,gain_r,
    input wire [1:0] inspect_channel,output wire [6:0] inspect_gain
);
    reg [4:0] control=0;
    reg [5:0] gain_data=0;
    reg [8:0] channel[0:3];
    `include "gs_mb87078_table.svh"
    function automatic [6:0] gain(input [8:0] latch_data);
        reg [6:0] index;
        begin
            index=!latch_data[6] ? 7'd65:latch_data[8] ? 7'd64:latch_data[7] ? 7'd0:{1'b0,~latch_data[5:0]};
            gain=gs_mb_percent(index);
        end
    endfunction
    assign rdata=offset ? {3'b0,control}:{2'b0,gain_data};
    assign gain_l=gain(channel[2]);assign gain_r=gain(channel[3]);
    assign inspect_gain=gain(channel[inspect_channel]);
    integer i;
    always @(posedge clk)begin
        if(we)begin
            if(offset)control<=data[4:0];
            else begin gain_data<=data[5:0];channel[control[1:0]]<={control[4:2],data[5:0]};end
        end
        if(reset || cold_reset)for(i=0;i<4;i=i+1)channel[i]<=9'h07f;
        if(cold_reset)begin control<=0;gain_data<=0;end
    end
endmodule
