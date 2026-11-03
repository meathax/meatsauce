// SPDX-License-Identifier: GPL-3.0-or-later
// UIO publication stays unacknowledged until the 50MHz receiver owns the word.
// A registered management request remains asserted through waitrequest.
module hangzo_pll_cfg_bridge(
    input wire src_clk,dst_clk,src_cfg_set,src_vsync,src_custom_toggle,
    input wire [5:0] src_custom_address,
    input wire [31:0] src_custom_data,
    output wire src_pending,src_cfg_ready,
    input wire dst_waitrequest,
    output reg dst_write=0,
    output reg [5:0] dst_address=0,
    output reg [31:0] dst_data=0
);
    reg custom_sent=0;
    wire custom_valid=src_custom_toggle!=custom_sent;
    wire custom_ready,custom_strobe;
    wire [37:0] custom_word;
    wire receiver_ready;
    (* preserve, dont_merge *) reg done_dst=0,done_meta=0,done_sync=0;
    (* preserve, dont_merge *) reg vs_meta=0,vs_sync=0;
    reg vs_previous=0;
    (* preserve, dont_merge *) reg got=0,got_meta=0,got_sync=0;
    reg got_previous=0,start_pending=0,start_inflight=0,is_start=0,old_wait=0;
    assign src_pending=custom_valid || !custom_ready;
    assign src_cfg_ready=done_sync;
    assign receiver_ready=!dst_write && !custom_strobe && !start_pending && !got_sync;
    hangzo_cdc_latest #(.WIDTH(38)) custom_cdc(
        .src_clk(src_clk),.src_valid(custom_valid),
        .src_data({src_custom_address,src_custom_data}),.src_ready(custom_ready),
        .dst_clk(dst_clk),.dst_ready(receiver_ready),.dst_data(custom_word),.dst_strobe(custom_strobe));
    always @(posedge src_clk) begin
        done_meta<=done_dst;done_sync<=done_meta;
        vs_meta<=src_vsync;vs_sync<=vs_meta;vs_previous<=vs_sync;
        if(custom_valid && custom_ready)custom_sent<=src_custom_toggle;
        if(!done_sync || !src_cfg_set)got<=src_cfg_set;
        else if(vs_sync && !vs_previous)got<=src_cfg_set;
    end
    always @(posedge dst_clk) begin
        got_meta<=got;got_sync<=got_meta;got_previous<=got_sync;
        old_wait<=dst_waitrequest;
        if(got_sync && !got_previous)start_pending<=1;
        if(!got_sync)start_pending<=0;
        if(dst_write)begin
            if(!dst_waitrequest)begin
                dst_write<=0;
                if(is_start)start_inflight<=1;
            end
        end else if(custom_strobe)begin
            {dst_address,dst_data}<=custom_word;
            dst_write<=1;is_start<=0;
        end else if(start_pending)begin
            dst_address<=6'd2;dst_data<=0;
            dst_write<=1;is_start<=1;start_pending<=0;
        end
        if(start_inflight && old_wait && !dst_waitrequest)begin
            done_dst<=1;start_inflight<=0;
        end
    end
endmodule
