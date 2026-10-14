// SPDX-License-Identifier: GPL-3.0-or-later
// MiSTer sends table entries as R[index], G[index], B[index], then index+1.
// Bypass an unconfigured gamma LUT even if HPS gamma_en powers up high.
// Game reset does not invalidate the independently configured platform LUT.
module n8080_gamma_guard (
    input wire clk, enable_requested, write_entry,
    input wire [9:0] write_address,
    output wire enable_validated
);
    reg [7:0] index_expected=0;
    reg [1:0] channel_expected=0;
    reg table_ready=0;
    always @(posedge clk) begin
        if(write_entry) begin
            if(write_address=={channel_expected,index_expected}) begin
                if(channel_expected==2) begin
                    channel_expected<=0;
                    index_expected<=index_expected+8'd1;
                    if(index_expected==255)table_ready<=1;
                end else channel_expected<=channel_expected+2'd1;
            end else if(write_address==0) begin
                // Restart an interrupted upload at its first red entry.
                index_expected<=0;channel_expected<=1;
            end else begin
                index_expected<=0;channel_expected<=0;
            end
        end
    end
    assign enable_validated=enable_requested&&table_ready;
endmodule
