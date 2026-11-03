/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 12-3-2021 */

module jts16_obj_scan(
    input              rst,
    input              clk,

    input              alt_bank,

    // Obj table
    output     [10:1]  tbl_addr,
    input      [15:0]  tbl_dout,
    output     [15:0]  tbl_din,
    output reg         tbl_we,

    // Draw commands
    output reg         dr_start,
    input              dr_busy,
    output reg [ 8:0]  dr_xpos,
    output reg [15:0]  dr_offset,  // MSB is also used as the flip bit
    output reg [ 3:0]  dr_bank,
    output reg [ 1:0]  dr_prio,
    output reg [ 5:0]  dr_pal,
    output reg [ 4:0]  dr_hzoom,
    output reg         dr_hflipb,

    // Video signal
    input              flip,
    input              hstart,
    input      [ 8:0]  vrender
);

parameter [8:0] PXL_DLY=8;
parameter       MODEL=0;  // 0 = S16A, 1 = S16B

localparam LAST_IDX = MODEL ? 5 : 4;
localparam STW = MODEL ? 4 : 3;
localparam ST_SCRATCH = MODEL ? 7 : 6,
           ST_PREZOOM = MODEL ? 6 /*Ok for S16B*/: 9 /* Unreachable for S16A*/,
           ST_ZOOM    = 8, // Unreachable for S16A
           ST_DRAW    = MODEL ? 9 : 7;

reg  [6:0] cur_obj;  // current object
reg  [2:0] idx;
reg  [STW-1:0] st;
reg [15:0] zoom;
reg        first, stop, visible, hstart_l;

// Object data
//reg        [7:0] bottom, top;
reg        [ 8:0] xpos;
reg signed [15:0] pitch;
reg        [15:0] offset; // MSB is also used as the flip bit
reg        [ 3:0] bank;
reg        [ 1:0] prio;
reg        [ 5:0] pal;
reg               zoom_sel, hflipb; // H flip bit for S16B
`ifdef DFJAIL
// Presentation180 reverses source rows too; the PCB global-flip path only
// repositions objects. Keep the normal incremental/scratch path unchanged.
reg [15:0] flip_base_offset,flip_draw_offset;
reg [8:0] flip_reverse_count;
reg [12:0] flip_zoom_product;
reg [9:0] flip_source_lines;
reg signed [25:0] flip_pitch_product;
`endif
wire       [15:0] next_offset;
wire       [15:0] next_zoom;
wire       [ 5:0] vzoom;

assign tbl_addr    = { cur_obj, idx };
assign next_offset = (first ? offset : tbl_dout) + ( pitch << (MODEL[0] & zoom[15]) );
assign vzoom       = { 1'b0, first ? 5'd0 : tbl_dout[14:10] } + { 1'b0, tbl_dout[9:5] };
assign next_zoom   = { vzoom, tbl_dout[9:0] };
assign tbl_din     = zoom_sel ? {1'b0, zoom[14:0] } : offset;

`ifdef DFJAIL
reg signed [9:0] top,bottom;
wire inzone=$signed({2'b0,vrender[7:0]})>=top && bottom>$signed({2'b0,vrender[7:0]});
`else
reg [7:0] top,bottom;
wire inzone=vrender[7:0]>=top && bottom>vrender[7:0];
`endif
wire       badobj = top >= bottom;

generate
     if( MODEL==0 )
        initial zoom = 0;
endgenerate

`ifdef SIMULATION
    wire hide = MODEL && st==3 && tbl_dout[14];
`endif

always @* begin
    if (!flip) begin
        top    = tbl_dout[ 7:0];
        bottom = tbl_dout[15:8];
    end else begin
        `ifdef DFJAIL
        bottom = 10'sd224-$signed({2'b0,tbl_dout[7:0]});
        top = 10'sd224-$signed({2'b0,tbl_dout[15:8]});
`else
        bottom = 8'd223-tbl_dout[ 7:0];
        top    = 8'd223-tbl_dout[15:8];
`endif
    end
end


always @(posedge clk, posedge rst) begin
    if( rst ) begin
        cur_obj   <= 0;
        st        <= 0;
        tbl_we    <= 0;
        stop      <= 0;

        dr_start  <= 0;
        dr_xpos   <= 0;
        dr_offset <= 0;
        dr_bank   <= 0;
        dr_prio   <= 0;
        dr_pal    <= 0;
        hstart_l  <= 0;
    end else begin
        idx <= idx>=LAST_IDX ? 3'd7 : (idx + 3'd1); // 7 is the scratch location
        if( !stop ) begin
            st <= st+1'd1;
        end
        hstart_l <= hstart;
        stop     <= 0;
        dr_start <= 0;
        tbl_we   <= 0;
/* verilator lint_off WIDTH */
        case( st )
/* verilator lint_on WIDTH */
            0: begin
                cur_obj  <= 0;
                stop     <= 0;
                dr_start <= 0;
                if( !(hstart && !hstart_l) || vrender>223 ) begin // holds it still
                    st  <= 0;
                    idx <= 0;
                end
            end
            1: begin
                if( !stop ) begin
                    visible <= inzone;
`ifdef DFJAIL
                    flip_reverse_count <= bottom-$signed({2'b0,vrender[7:0]});
`endif
                    if( MODEL==0 && bottom>=8'hf0 ) begin
                        st <= 0; // Done
                    end else if( MODEL==0 && (!inzone || badobj) ) begin
                        // For S16A there is no end-of-table (EOT) bit, so we
                        // can loop around here. For S16B, we need to check
                        // tbl_dout at state 3 for the EOT bit
                        // Next object
                        cur_obj <= cur_obj + 1'd1;
                        idx     <= 0;
                        st      <= 1;
                        stop    <= 1;
                        if( &cur_obj )
                            st <= 0; // we're done
                    end else begin // draw this one
                        first <= top == vrender[7:0]; // first line
                    end
                end
            end
            2: xpos <= tbl_dout[8:0];
            3: begin
                pitch <= MODEL ? { {8{tbl_dout[7]}}, tbl_dout[7:0]} : tbl_dout;
                hflipb<= tbl_dout[8];
                if( (MODEL && tbl_dout[14]) || !visible ) begin // skip this sprite
                    cur_obj <= cur_obj + 1'd1;
                    idx     <= 0;
                    st      <= 1;
                    stop    <= 1;
                    if( &cur_obj )
                        st <= 0; // we're done
                end
                if( MODEL && tbl_dout[15] ) begin
                    st <= 0; // end of sprite list
                end
            end
            4: begin
                offset  <= tbl_dout; // flip/offset
`ifdef DFJAIL
                flip_base_offset <= tbl_dout;
`endif
            end
            5: begin
                if (MODEL) begin
                    pal  <= tbl_dout[5:0];
                    bank <= tbl_dout[11:8];
                    prio <= tbl_dout[7:6];
                end else begin
                    pal  <= tbl_dout[13:8];
                    bank <= {1'b0, tbl_dout[6:4] };
                    prio <= tbl_dout[1:0];
                end
            end
            ST_PREZOOM: begin
                zoom <= next_zoom;
`ifdef DFJAIL
                flip_zoom_product <= flip_reverse_count * tbl_dout[9:5];
`endif
            end
            ST_SCRATCH: begin
                offset   <= next_offset;
                tbl_we   <= 1;
                zoom_sel <= 0;
            end
            ST_ZOOM: begin
`ifdef DFJAIL
                flip_source_lines <= flip_reverse_count + (flip_zoom_product >> 5);
                if(MODEL && flip) st<=10;
`endif
                tbl_we  <= 1;
                zoom_sel<= 1;
                idx     <= 5;
            end
`ifdef DFJAIL
            10: begin
                flip_pitch_product <= pitch * $signed({1'b0,flip_source_lines});
            end
            11: begin
                flip_draw_offset <= flip_base_offset + flip_pitch_product[15:0];
                st<=ST_DRAW;
            end
`endif
            ST_DRAW: begin
                if( !dr_busy ) begin
                    dr_xpos   <= xpos; //+PXL_DLY;
                    `ifdef DFJAIL
                    dr_offset <= (MODEL && flip) ? flip_draw_offset : offset;
`else
                    dr_offset <= offset;
`endif
                    dr_pal    <= pal;
                    dr_prio   <= prio;
                    dr_start  <= 1;
                    dr_hflipb <= hflipb;
                    dr_hzoom  <= zoom[4:0];
                    if( alt_bank ) begin
                        case( bank )
                            0:  dr_bank <= 0;
                            7:  dr_bank <= 3;
                            11: dr_bank <= 2;
                            13: dr_bank <= 1;
                            14: dr_bank <= 0;
                            default: dr_bank <= 15;
                        endcase
                    end else
                        dr_bank <= bank;
                    // next
                    if( &cur_obj )
                        st <= 0; // Done
                    else begin
                        cur_obj <= cur_obj + 1'd1;
                        idx     <= 0;
                        st      <= 1;
                        stop    <= 1;
                    end
                end else begin
                    if(!hstart) st <= ST_DRAW[STW-1:0];
                end
            end
        endcase
    end
end

endmodule