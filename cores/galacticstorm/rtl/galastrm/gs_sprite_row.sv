// SPDX-License-Identifier: BSD-3-Clause
// Two-stage sprite row decoder followed by the pinned MAME per-chunk zoom sampler.
// The fetch stage reads both eight-pixel ROM halves in one transaction and decodes
// them in parallel (the JTFRAME planar layout: pixel i of a word is bits {24+i,16+i,8+i,i});
// the emit stage outputs one sampled pixel per accepted clock. A new row is
// fetched while the previous one is emitted. Pixels leave strictly in command
// order and carry their own line and priority tags.
// ROM address is {tile_code,half,source_y}; plane bytes have pixel 0 in bit 0.
module gs_sprite_row #(parameter SKIP_EMPTY=0,parameter PAIRED=0)(
    input wire clk, reset, command,
    output wire command_ready,
    input wire [14:0] code,
    input wire [7:0] color,
    input wire flipx, flipy,
    input wire signed [11:0] x, y,
    input wire [6:0] width, height,
    input wire [8:0] scanline,
    input wire [1:0] priority_in,
    output wire [19:0] rom_addr,
    output wire rom_req,
    input wire rom_ack,     // request accepted
    input wire rom_rvalid,  // reply, in request order
    input wire [63:0] rom_rdata,   // {half 1, half 0}, JTFRAME planar words
    output wire pixel_valid,
    input wire pixel_ready,
    output wire signed [11:0] pixel_x,
    output wire [11:0] pixel_index,
    output wire pixel_opaque,
    output wire pixel_valid2,
    output wire signed [11:0] pixel_x2,
    output wire [11:0] pixel_index2,
    output wire pixel_opaque2,
    output wire [2:0] pixel_line,
    output wire [1:0] pixel_priority,
    output wire idle,
    output reg done
);
    function [20:0] zoom_step;
        input [6:0] size;
        begin
            case (size)
            7'd1: zoom_step = 21'd1048576;
            7'd2: zoom_step = 21'd524288;
            7'd3: zoom_step = 21'd349525;
            7'd4: zoom_step = 21'd262144;
            7'd5: zoom_step = 21'd209715;
            7'd6: zoom_step = 21'd174762;
            7'd7: zoom_step = 21'd149796;
            7'd8: zoom_step = 21'd131072;
            7'd9: zoom_step = 21'd116508;
            7'd10: zoom_step = 21'd104857;
            7'd11: zoom_step = 21'd95325;
            7'd12: zoom_step = 21'd87381;
            7'd13: zoom_step = 21'd80659;
            7'd14: zoom_step = 21'd74898;
            7'd15: zoom_step = 21'd69905;
            7'd16: zoom_step = 21'd65536;
            7'd17: zoom_step = 21'd61680;
            7'd18: zoom_step = 21'd58254;
            7'd19: zoom_step = 21'd55188;
            7'd20: zoom_step = 21'd52428;
            7'd21: zoom_step = 21'd49932;
            7'd22: zoom_step = 21'd47662;
            7'd23: zoom_step = 21'd45590;
            7'd24: zoom_step = 21'd43690;
            7'd25: zoom_step = 21'd41943;
            7'd26: zoom_step = 21'd40329;
            7'd27: zoom_step = 21'd38836;
            7'd28: zoom_step = 21'd37449;
            7'd29: zoom_step = 21'd36157;
            7'd30: zoom_step = 21'd34952;
            7'd31: zoom_step = 21'd33825;
            7'd32: zoom_step = 21'd32768;
            7'd33: zoom_step = 21'd31775;
            7'd34: zoom_step = 21'd30840;
            7'd35: zoom_step = 21'd29959;
            7'd36: zoom_step = 21'd29127;
            7'd37: zoom_step = 21'd28339;
            7'd38: zoom_step = 21'd27594;
            7'd39: zoom_step = 21'd26886;
            7'd40: zoom_step = 21'd26214;
            7'd41: zoom_step = 21'd25575;
            7'd42: zoom_step = 21'd24966;
            7'd43: zoom_step = 21'd24385;
            7'd44: zoom_step = 21'd23831;
            7'd45: zoom_step = 21'd23301;
            7'd46: zoom_step = 21'd22795;
            7'd47: zoom_step = 21'd22310;
            7'd48: zoom_step = 21'd21845;
            7'd49: zoom_step = 21'd21399;
            7'd50: zoom_step = 21'd20971;
            7'd51: zoom_step = 21'd20560;
            7'd52: zoom_step = 21'd20164;
            7'd53: zoom_step = 21'd19784;
            7'd54: zoom_step = 21'd19418;
            7'd55: zoom_step = 21'd19065;
            7'd56: zoom_step = 21'd18724;
            7'd57: zoom_step = 21'd18396;
            7'd58: zoom_step = 21'd18078;
            7'd59: zoom_step = 21'd17772;
            7'd60: zoom_step = 21'd17476;
            7'd61: zoom_step = 21'd17189;
            7'd62: zoom_step = 21'd16912;
            7'd63: zoom_step = 21'd16644;
            7'd64: zoom_step = 21'd16384;
            default: zoom_step=0;
            endcase
        end
    endfunction
    function [31:0] half_pens;  // eight 4-bit pens, pen i in bits 4i+:4
        input [31:0] d;
        integer i;
        begin
            for (i=0;i<8;i=i+1) half_pens[4*i +: 4] = {d[24+i],d[16+i],d[8+i],d[i]};
        end
    endfunction

    // ---- fetch queue: two rows, ROM reads in flight in order ----
    reg [1:0] q_valid,q_req,q_full;
    reg q_tail,q_req_ptr,q_resp_ptr,q_head;
    reg [14:0] q_code[0:1];
    reg [3:0] q_source_y[0:1];
    reg [63:0] q_pens[0:1];
    reg [7:0] q_palette[0:1];
    reg signed [11:0] q_x[0:1];
    reg [6:0] q_width[0:1];
    reg [1:0] q_flip;
    reg [2:0] q_line[0:1];
    reg [1:0] q_priority[0:1];
    wire signed [12:0] relative_y = $signed({4'b0,scanline})-$signed({y[11],y});
    wire [6:0] sampled_y = flipy ? height-7'd1-relative_y[6:0] : relative_y[6:0];
    wire [27:0] source_y_fixed = sampled_y * zoom_step(height);
    wire row_invalid = width==0 || height==0 || width>64 || height>64 ||
                       relative_y<0 || relative_y>=$signed({6'b0,height});
    assign command_ready = !q_valid[q_tail];
    assign rom_req = q_valid[q_req_ptr] && !q_req[q_req_ptr];
    assign rom_addr = {q_code[q_req_ptr], 1'b0, q_source_y[q_req_ptr]};

    // ---- emit stage ----
    reg e_busy;
    reg [63:0] e_pens;
    reg [7:0] e_palette;
    reg signed [11:0] e_x;
    reg [6:0] e_width, e_column;
    reg e_flip;
    reg [20:0] e_step;
    reg [27:0] e_source_x;
    reg [2:0] e_line;
    reg [1:0] e_priority;
    wire [3:0] current_pen=e_pens[4*e_source_x[19:16] +: 4];
    wire [27:0] next_source=e_flip ? e_source_x-{7'b0,e_step} : e_source_x+{7'b0,e_step};
    wire [27:0] after_two_source=e_flip ? next_source-{7'b0,e_step} : next_source+{7'b0,e_step};
    wire signed [11:0] sample_x=e_x+$signed({5'b0,e_column});
    // Packed owner RAM stores adjacent screen pixels together. An odd row
    // origin is emitted as a scalar lead-in before aligned even/odd pairs.
    wire pair_available=PAIRED && e_busy && e_column+7'd1<e_width && !sample_x[0];
    // Ownership ignores transparent pixels. Skip a transparent position and
    // emit its successor on the same clock, retaining exact zoom coordinates.
    // Paired issue carries both destinations, including a transparent lane.
    wire skip_pixel=SKIP_EMPTY && !PAIRED && current_pen==0 && e_column+7'd1<e_width;
    wire [27:0] emit_source=skip_pixel ? next_source : e_source_x;
    wire [3:0] e_pen=e_pens[4*emit_source[19:16] +: 4];
    wire [3:0] next_pen=e_pens[4*next_source[19:16] +: 4];
    wire advance_two=pair_available || skip_pixel;
    wire [6:0] advance=advance_two ? 7'd2 : 7'd1;
    wire e_last = e_busy && pixel_ready && e_column+advance==e_width;
    wire e_free = !e_busy || e_last;
    assign pixel_valid = e_busy;
    assign pixel_valid2=pair_available;
    assign pixel_x = sample_x+$signed({11'b0,skip_pixel});
    assign pixel_x2 = sample_x+12'sd1;
    assign pixel_index = {e_palette,e_pen};
    assign pixel_opaque = e_pen != 0;
    assign pixel_index2 = {e_palette,next_pen};
    assign pixel_opaque2 = next_pen != 0;
    assign pixel_line = e_line;
    assign pixel_priority = e_priority;
    assign idle = q_valid==0 && !e_busy;

    always @(posedge clk) begin
        if (reset) begin
            q_valid<=0; q_req<=0; q_full<=0; q_tail<=0; q_req_ptr<=0; q_resp_ptr<=0; q_head<=0;
            e_busy<=0; e_pens<=0; e_palette<=0; e_x<=0; e_width<=0; e_column<=0;
            e_flip<=0; e_step<=0; e_source_x<=0; e_line<=0; e_priority<=0; done<=0;
        end else begin
            done<=0;
            // emit stage
            if (e_busy && pixel_ready) begin
                e_column<=e_column+advance;
                e_source_x<=advance_two ? after_two_source : next_source;
                if (e_last) begin e_busy<=0; done<=1; end
            end
            // accept a row
            if (command && command_ready) begin
                if (row_invalid) done<=1;
                else begin
                    q_code[q_tail]<=code; q_source_y[q_tail]<=source_y_fixed[19:16]; q_palette[q_tail]<=color;
                    q_x[q_tail]<=x; q_width[q_tail]<=width; q_flip[q_tail]<=flipx;
                    q_line[q_tail]<=scanline[2:0]; q_priority[q_tail]<=priority_in;
                    q_valid[q_tail]<=1; q_tail<=!q_tail;
                end
            end
            // request accepted, then reply returned, both in queue order
            if (rom_req && rom_ack) begin q_req[q_req_ptr]<=1; q_req_ptr<=!q_req_ptr; end
            if (rom_rvalid) begin
                q_pens[q_resp_ptr]<={half_pens(rom_rdata[63:32]),half_pens(rom_rdata[31:0])};
                q_full[q_resp_ptr]<=1; q_resp_ptr<=!q_resp_ptr;
            end
            // hand the oldest complete row to the emitter
            if (q_full[q_head] && e_free) begin
                // Ownership stores ignore pen zero. An entirely transparent
                // decoded row can retire without emitting its zoomed pixels.
                e_busy<=!(SKIP_EMPTY && q_pens[q_head]==0);
                if(SKIP_EMPTY && q_pens[q_head]==0) done<=1;
                e_pens<=q_pens[q_head]; e_palette<=q_palette[q_head]; e_x<=q_x[q_head];
                e_width<=q_width[q_head]; e_column<=0; e_flip<=q_flip[q_head]; e_step<=zoom_step(q_width[q_head]);
                e_source_x<=q_flip[q_head] ? (q_width[q_head]-7'd1)*zoom_step(q_width[q_head]) : 28'd0;
                e_line<=q_line[q_head]; e_priority<=q_priority[q_head];
                q_valid[q_head]<=0; q_req[q_head]<=0; q_full[q_head]<=0; q_head<=!q_head;
            end
        end
    end
endmodule
