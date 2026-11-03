// SPDX-License-Identifier: GPL-3.0-or-later
// Exact MAME layouts, fetched as two/four adjacent packed plane-pair words.
// A request is accepted once by rom_ack; responses may contain arbitrary gaps.
module darkmist_gfx_row (
    input wire clk, reset, start,
    input wire [1:0] region, // 0=text, 1=BG, 2=FG, 3=sprites
    input wire [10:0] code,
    input wire [3:0] row,
    output reg busy, done, protocol_error,
    output reg [63:0] pixels, // pixel x occupies bits x*4 +: 4
    output wire rom_req,
    output reg [1:0] rom_region,
    output reg [16:0] rom_word_addr,
    output reg [2:0] rom_words,
    input wire rom_ack, rom_valid, rom_last,
    input wire [15:0] rom_data
);
    reg accepted;
    reg [1:0] beat;
    integer bitpos;
    assign rom_req = busy && !accepted;
    always @(posedge clk) begin
        if (reset) begin
            busy <= 1'b0;
            done <= 1'b0;
            protocol_error <= 1'b0;
            accepted <= 1'b0;
            beat <= 2'd0;
            pixels <= 64'd0;
            rom_region <= 2'd0;
            rom_word_addr <= 17'd0;
            rom_words <= 3'd0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                busy <= 1'b1;
                accepted <= 1'b0;
                beat <= 2'd0;
                pixels <= 64'd0;
                rom_region <= region;
                rom_words <= region == 2'd0 ? 3'd2 : 3'd4;
                // gfx_element wraps code modulo the region's actual tile count.
                if (region == 2'd0) rom_word_addr <= {4'd0,code[8:0],row[2:0],1'b0};
                else if (region == 2'd3) rom_word_addr <= {code,row,2'd0};
                else rom_word_addr <= {1'b0,code[9:0],row,2'd0};
            end
            if (rom_req && rom_ack) accepted <= 1'b1;
            if (busy && rom_valid) begin
                if (!accepted && !(rom_req && rom_ack)) protocol_error <= 1'b1;
                for (bitpos=0;bitpos<4;bitpos=bitpos+1)
                    pixels[(int'(beat)*4+bitpos)*4 +: 4] <=
                        {rom_data[7-bitpos],rom_data[3-bitpos],
                         rom_data[15-bitpos],rom_data[11-bitpos]};
                if ({1'b0,beat} == rom_words-3'd1) begin
                    if (!rom_last) protocol_error <= 1'b1;
                    busy <= 1'b0;
                    done <= 1'b1;
                    accepted <= 1'b0;
                end else begin
                    if (rom_last) protocol_error <= 1'b1;
                    beat <= beat+2'd1;
                end
            end
            if (start && busy) protocol_error <= 1'b1;
        end
    end
endmodule
