// SPDX-License-Identifier: GPL-3.0-or-later
// Explicit 256x40 M10K pages; one synchronous read and one write per page.
// No reset touches RAM contents. The selected page is registered with its read.
module argus_paged_sdp_ram40 #(
    parameter integer DATA_W = 120,
    parameter integer DEPTH = 4096,
    // Only clients that ignore inactive q may remove all read-enable fanout.
    parameter bit ALWAYS_READ = 1'b0,
    parameter integer ADDR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input logic clk,
    input logic we,
    input logic [ADDR_W-1:0] waddr,
    input logic [DATA_W-1:0] wdata,
    input logic re,
    input logic [ADDR_W-1:0] raddr,
    output logic [DATA_W-1:0] q
);
    localparam integer PAGES = (DEPTH+255)/256;
    localparam integer BANKS = (DATA_W+39)/40;
    localparam integer PAGE_W = (PAGES > 1) ? $clog2(PAGES) : 1;
    localparam integer PADDED_W = BANKS*40;
    logic [PAGE_W-1:0] selected_page;
    logic [PADDED_W-1:0] padded_wdata;
    wire [PADDED_W-1:0] page_q[0:PAGES-1];
    assign padded_wdata = PADDED_W'(wdata);
    assign q = page_q[selected_page][DATA_W-1:0];
    always_ff @(posedge clk) if (ALWAYS_READ || re) selected_page <= PAGE_W'(32'(raddr)/256);
    genvar p,b;
    generate for(p=0;p<PAGES;p=p+1) begin: page
        for(b=0;b<BANKS;b=b+1) begin: bank
            (* ramstyle = "M10K" *) logic [39:0] words[0:255];
            logic [39:0] read_q;
            always_ff @(posedge clk) begin
                if (we && (32'(waddr)/256 == p)) words[8'(waddr)] <= padded_wdata[b*40 +: 40];
                if (ALWAYS_READ || (re && (32'(raddr)/256 == p))) read_q <= words[8'(raddr)];
            end
            assign page_q[p][b*40 +: 40] = read_q;
        end
    end endgenerate
endmodule
