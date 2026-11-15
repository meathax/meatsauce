// SPDX-License-Identifier: GPL-3.0-or-later
// F3 geometry follows HeavyUnit's controls. Source resampling, rather than
// changing the read CE, keeps every output pixel eight fabric clocks wide.
module rf_crt_adjust (
    input logic clk, reset, ce_in, enable, rate_60,
    input logic [1:0] vis_mode,
    input logic [2:0] size_option,
    input logic signed [4:0] hposition, vposition,
    input logic [8:0] x, y,
    input logic [23:0] rgb_in,
    input logic hs_in, vs_in, hb_in, vb_in,
    output wire ce_out, active,
    output wire [23:0] rgb_out,
    output wire hs_out, vs_out, hb_out, vb_out
);
    wire [8:0] first_y = vis_mode == 0 ? 9'd31 : vis_mode == 1 ? 9'd32 : 9'd24;
    wire [8:0] end_y = vis_mode == 3 ? 9'd256 : first_y + 9'd224;
    wire [8:0] total_y = rate_60 ? 9'd257 : 9'd262;
    wire [8:0] previous_y = y == 0 ? total_y - 9'd1 : y - 9'd1;
    logic enabled = 0;
    logic [8:0] left = 46, width = 320;
    logic [4:0] step = 16;
    logic signed [4:0] vertical = 0;
    integer wanted_width, wanted_step, wanted_left, wanted_vertical;
    always_comb begin
        case (size_option)
            1: begin wanted_width=342; wanted_step=15; end
            2: begin wanted_width=366; wanted_step=14; end
            3: begin wanted_width=285; wanted_step=18; end
            4: begin wanted_width=302; wanted_step=17; end
            default: begin wanted_width=320; wanted_step=16; end
        endcase
        wanted_left=206-(wanted_width/2)+int'($signed(hposition));
        // Keep the whole image clear of HSync (x388..419), including extremes.
        if (wanted_left<2) wanted_left=2;
        if (wanted_left>386-wanted_width) wanted_left=386-wanted_width;
        wanted_vertical=int'($signed(vposition));
        // Both rasters and every F3 visible window have at least this margin.
        if (wanted_vertical < -2) wanted_vertical=-2;
        if (wanted_vertical > 15) wanted_vertical=15;
    end
    always_ff @(posedge clk) begin
        if (reset) enabled<=0;
        else if (ce_in && x==0 && y==0) begin
            enabled<=enable;
            left<=9'(wanted_left); width<=9'(wanted_width);
            step<=5'(wanted_step); vertical<=5'(wanted_vertical);
        end
    end

    // Each bank contains only 320 active samples. No DDR client or new CDC.
    (* ramstyle="M10K" *) logic [23:0] lines [0:1023];
    wire [8:0] write_x=x-9'd46;
    always_ff @(posedge clk) begin
        if (ce_in && !hb_in && !vb_in)
            lines[{y[0],write_x}]<=rgb_in;
    end
    logic [12:0] source_phase=0;
    wire in_window=x>=left && x<left+width;
    wire line_blank=previous_y<first_y || previous_y>=end_y;
    // The modulo is a single conditional subtract/add, not a hardware divider.
    integer sync_start, sync_end;
    always_comb begin
        sync_start=(rate_60 ? 1 : 258)+int'($signed(vertical));
        if (sync_start<0) sync_start=sync_start+int'(total_y);
        if (sync_start>=int'(total_y)) sync_start=sync_start-int'(total_y);
        sync_end=sync_start+3;
    end
    wire shifted_vs=sync_end<=int'(total_y) ?
        (int'(previous_y)>=sync_start && int'(previous_y)<sync_end) :
        (int'(previous_y)>=sync_start || int'(previous_y)<sync_end-int'(total_y));
    logic ce_q=0, hs_q=0, vs_q=0, hb_q=1, vb_q=1;
    logic [23:0] rgb_q;
    logic [23:0] native_rgb=0;
    logic rgb_valid=0;
    // A pure synchronous read allows M10K inference. Qualification is
    // registered alongside the read and applied after the memory output.
    always_ff @(posedge clk) begin
        if (ce_in) rgb_q<=lines[{previous_y[0],source_phase[12:4]}];
    end
    logic [3:0] native_sync=4'b0011;
    always_ff @(posedge clk) begin
        ce_q<=ce_in;
        if (ce_in) begin
            native_rgb<=rgb_in;
            native_sync<={hs_in,vs_in,hb_in,vb_in};
            if (x==0) source_phase<=0;
            else if (in_window) source_phase<=source_phase+{8'd0,step};
            rgb_valid<=in_window && !line_blank;
            hs_q<=hs_in; vs_q<=shifted_vs;
            hb_q<=!in_window; vb_q<=line_blank;
        end
    end
    assign active=enabled;
    // Both paths use the same one-clock pipeline: mode switches cannot make
    // a seven/nine-clock CE gap at the boundary between bypass and adjustment.
    assign ce_out=ce_q;
    assign rgb_out=enabled ? (rgb_valid ? rgb_q : 24'd0) : native_rgb;
    assign {hs_out,vs_out,hb_out,vb_out}=enabled ?
        {hs_q,vs_q,hb_q,vb_q} : native_sync;
endmodule
