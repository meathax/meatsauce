/* X-Men 6P character (seat) selection
 *
 * The 6-player board ties each character to one control panel position:
 * slot 0 Cyclops, 1 Colossus, 2 Wolverine, 3 Storm, 4 Nightcrawler,
 * 5 Dazzler (MAME xmen6p, verified by joining each slot). This module routes
 * any MiSTer controller to any slot. The game itself is not modified: it
 * still reads slot s from its usual port, the router only decides which
 * controller drives that port. Coin and start follow the controller.
 *
 * cmap holds a permutation: cmap[3*s+:3] = controller driving slot s.
 *
 * OSD: one 3-bit field per controller: 0 Default, 1..6 Cyclops..Dazzler.
 * Starting from the cabinet map, each non-default field (in controller
 * order) swaps its controller onto the chosen slot. This always gives a
 * valid permutation; with conflicting choices the later controller wins and
 * the displaced one takes the freed slot. A new OSD value reloads the map.
 *
 * In-game picker: a controller whose slot is not in play (game RAM 11355C,
 * one bit per slot, set on join and cleared after the continue countdown)
 * can press Left/Right. The first press shows its tag over the HUD; the next
 * ones move it to the next slot that is not in play and whose controller is
 * not choosing too. The fire button then joins the game as usual. Controllers
 * that are in play never move.
 *
 * The overlay draws "< Pn >" and the character name below the HUD box of
 * every slot whose controller is choosing. Output latency is 3 clocks from
 * ox/oy; jtxmen6p_dual keeps ox stable for 4 clocks.
 */
module jtxmen6p_seats #(parameter TICKW=25)(
    input             rst,
    input             clk,
    // controllers, JTFRAME game_joy format: {B3,B2,B1,D,U,R,L} active low
    input      [ 6:0] joy1, joy2, joy3, joy4,
    input      [15:0] joy5raw, joy6raw,   // raw MiSTer words, active high
    input      [ 3:0] start_n, coin_n,    // controllers 1-4, active low
    // configuration
    input      [17:0] osd_sel,            // 3 bits per controller
    input             picker_en,
    input      [ 5:0] inplay,             // game slot in-play mask
    // to the game, per slot
    output reg [41:0] sjoy,               // 7 bits per slot, active low
    output reg [ 5:0] sstart_n,
    output reg [ 5:0] scoin_n,
    // overlay
    input      [ 9:0] ox,
    input      [ 7:0] oy,
    output reg [ 1:0] ovl                 // 0 none, 1 dim, 2 white, 3 yellow
);

`include "jtxmen6p_seats_font.vh"

localparam [7:0] Y0 = 8'd33;   // tag rows Y0..Y0+17, below the HUD
localparam       TMAX = 3'd7;  // tag lifetime in ticks (~0.7 s each)

// ---------------------------------------------------------------------------
// controller bundles
reg  [15:0] j5_s0, j5_s1, j6_s0, j6_s1;
always @(posedge clk) begin
    j5_s0 <= joy5raw; j5_s1 <= j5_s0;
    j6_s0 <= joy6raw; j6_s1 <= j6_s0;
end

// raw MiSTer word: 0 R, 1 L, 2 D, 3 U, 4..6 buttons, 7 start, 8 coin
function [6:0] fmt( input [15:0] j );
    fmt = ~{ j[6:4], j[2], j[3], j[0], j[1] };
endfunction

wire [41:0] cj = { fmt(j6_s1), fmt(j5_s1), joy4, joy3, joy2, joy1 };
wire [ 5:0] cs = { ~j6_s1[7], ~j5_s1[7], start_n };
wire [ 5:0] cc = { ~j6_s1[8], ~j5_s1[8], coin_n  };

// ---------------------------------------------------------------------------
// OSD map resolution. OSD bits come from another clock domain: a value is
// used once it has been stable for two clocks.
reg  [17:0] osd_s0, osd_s1, osd_s2, applied, resolved_r;
reg         init, apply;

function [17:0] resolve( input [17:0] sel );
    integer   rc, rs;
    reg [2:0] v, cur, h;
    reg [3:0] t;
    begin
        resolve = { 3'd5, 3'd4, 3'd3, 3'd2, 3'd1, 3'd0 };
        for( rc=0; rc<6; rc=rc+1 ) begin
            v = sel[3*rc+:3];
            if( v!=3'd0 && v!=3'd7 ) begin   // 0 Default, 1..6 character
                t   = {1'b0,v} - 4'd1;
                cur = 0;
                for( rs=0; rs<6; rs=rs+1 ) if( resolve[3*rs+:3]==rc[2:0] ) cur = rs[2:0];
                h = resolve[3*t[2:0]+:3];
                resolve[3*t[2:0]+:3] = rc[2:0];
                resolve[3*cur+:3]    = h;
            end
        end
    end
endfunction

wire [17:0] resolved = resolve( osd_s2 );

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        osd_s0     <= 0;
        osd_s1     <= 0;
        osd_s2     <= 0;
        applied    <= 0;
        resolved_r <= { 3'd5, 3'd4, 3'd3, 3'd2, 3'd1, 3'd0 };
        init       <= 1;
        apply      <= 0;
    end else begin
        osd_s0 <= osd_sel;
        osd_s1 <= osd_s0;
        osd_s2 <= osd_s1;
        apply  <= 0;
        if( osd_s1==osd_s2 && (init || osd_s2!=applied) ) begin
            resolved_r <= resolved;
            applied    <= osd_s2;
            apply      <= 1;
            init       <= 0;
        end
    end
end

// ---------------------------------------------------------------------------
// picker
reg  [17:0] cmap;
reg  [ 5:0] lft_l, rgt_l, req_l, req_r;
reg  [ 2:0] sc;                 // controller being serviced
reg  [17:0] tmr;                // 3 bits per controller
reg  [TICKW-1:0] tick_cnt;
reg         tick;
reg  [17:0] slot_of;
wire [ 5:0] lft, rgt, fire;
integer     ps, pk, pc;

genvar g;
generate
    for( g=0; g<6; g=g+1 ) begin : ctl
        assign lft[g]  = ~cj[7*g];
        assign rgt[g]  = ~cj[7*g+1];
        assign fire[g] = ~&cj[7*g+4+:3];
    end
endgenerate

always @* begin
    slot_of = 0;
    for( ps=0; ps<6; ps=ps+1 ) slot_of[ 3*cmap[3*ps+:3] +: 3 ] = ps[2:0];
end

wire [2:0] sc_slot  = slot_of[3*sc+:3];
wire       sc_free  = ~inplay[sc_slot];
wire       sc_shown = tmr[3*sc+:3] != 0;

// next eligible slot from sc_slot in the requested direction: not in play
// and its controller not choosing
reg  [2:0] nxt, cand, hold;
reg  [3:0] cand4;
reg        nxt_ok;
always @* begin
    nxt    = sc_slot;
    nxt_ok = 0;
    for( pk=5; pk>=1; pk=pk-1 ) begin   // last match wins: smallest step
        cand4 = req_r[sc] ? {1'b0,sc_slot} + pk[3:0] : {1'b0,sc_slot} + 4'd6 - pk[3:0];
        if( cand4 > 4'd5 ) cand4 = cand4 - 4'd6;
        cand  = cand4[2:0];
        hold = cmap[3*cand+:3];
        if( !inplay[cand] && tmr[3*hold+:3]==0 ) begin
            nxt    = cand;
            nxt_ok = 1;
        end
    end
end

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        cmap     <= { 3'd5, 3'd4, 3'd3, 3'd2, 3'd1, 3'd0 };
        lft_l    <= 0;
        rgt_l    <= 0;
        req_l    <= 0;
        req_r    <= 0;
        sc       <= 0;
        tmr      <= 0;
        tick_cnt <= 0;
        tick     <= 0;
    end else begin
        { tick, tick_cnt } <= { 1'b0, tick_cnt } + 1'd1;
        lft_l <= lft;
        rgt_l <= rgt;
        sc    <= sc==3'd5 ? 3'd0 : sc + 3'd1;
        for( pc=0; pc<6; pc=pc+1 ) begin
            if( tick && tmr[3*pc+:3]!=0 ) tmr[3*pc+:3] <= tmr[3*pc+:3] - 3'd1;
            if( inplay[slot_of[3*pc+:3]] ) tmr[3*pc+:3] <= 0; // joined
        end
        req_l <= req_l | ( lft & ~lft_l );
        req_r <= req_r | ( rgt & ~rgt_l );
        if( req_l[sc] || req_r[sc] ) begin
            req_l[sc] <= 0;
            req_r[sc] <= 0;
            if( picker_en && sc_free && !fire[sc] ) begin
                tmr[3*sc+:3] <= TMAX;   // first press only shows the tag
                if( sc_shown && nxt_ok ) begin
                    cmap[3*nxt+:3]     <= sc;
                    cmap[3*sc_slot+:3] <= cmap[3*nxt+:3];
                end
            end
        end
        if( !picker_en ) tmr <= 0;
        if( apply ) begin
            cmap  <= resolved_r;
            tmr   <= 0;
            req_l <= 0;
            req_r <= 0;
        end
    end
end

// ---------------------------------------------------------------------------
// routing, registered
integer rr;
always @(posedge clk) begin
    for( rr=0; rr<6; rr=rr+1 ) begin
        sjoy[7*rr+:7] <= cj[ 7*cmap[3*rr+:3] +: 7 ];
        sstart_n[rr]  <= cs[ cmap[3*rr+:3] ];
        scoin_n[rr]   <= cc[ cmap[3*rr+:3] ];
    end
end

// ---------------------------------------------------------------------------
// overlay
function [9:0] box_x( input [2:0] sl );
    case( sl )
        3'd0: box_x = 10'd51;
        3'd1: box_x = 10'd131;
        3'd2: box_x = 10'd211;
        3'd3: box_x = 10'd291;
        3'd4: box_x = 10'd371;
        default: box_x = 10'd451;
    endcase
endfunction

// per-slot tag state, refreshed every clock (changes slowly)
reg  [ 5:0] show;
reg  [17:0] ctlv;
integer os;
always @(posedge clk) begin
    for( os=0; os<6; os=os+1 ) begin
        show[os]        <= picker_en && !inplay[os] && tmr[3*cmap[3*os+:3]+:3]!=0;
        ctlv[3*os+:3]   <= cmap[3*os+:3];
    end
end

// stage A: tag box hit
reg        a_in;
reg  [2:0] a_slot;
reg  [6:0] a_bx;
reg  [4:0] a_by;
reg  [9:0] dx;
reg  [7:0] dy;
integer oa;
always @(posedge clk) begin
    a_in <= 0;
    dy    = oy - Y0;
    for( oa=0; oa<6; oa=oa+1 ) begin
        dx = ox - box_x(oa[2:0]);
        if( dx < 10'd72 && dy < 8'd18 ) begin
            a_in   <= 1;
            a_slot <= oa[2:0];
            a_bx   <= dx[6:0];
        end
    end
    a_by <= dy[4:0];
end

// stage B: character code
reg        b_in, b_line;
reg  [2:0] b_sub, b_row;
reg  [4:0] b_ch;
reg  [3:0] col;
reg  [2:0] sub;
reg  [4:0] gy;
reg  [2:0] b_ctl;
reg  [6:0] base, dif;
integer ob;
always @(posedge clk) begin
    col = 0; sub = 0; base = 0;
    for( ob=0; ob<12; ob=ob+1 ) begin   // col = a_bx/6, sub = a_bx%6
        if( a_bx >= base ) begin
            col  = ob[3:0];
            dif  = a_bx - base;
            sub  = dif[2:0];
        end
        base = base + 7'd6;
    end
    b_ctl   = ctlv[3*a_slot+:3];
    b_in   <= a_in & show[a_slot];
    b_sub  <= sub;
    b_line <= a_by >= 5'd9;
    gy      = a_by >= 5'd9 ? a_by - 5'd10 : a_by - 5'd1;
    b_row  <= gy[2:0];
    if( gy > 5'd6 )
        b_ch <= 5'd0;
    else if( a_by >= 5'd9 )
        b_ch <= name_ch( a_slot, col );
    else
        b_ch <= col==4'd3 ? CH_LT :
                col==4'd5 ? CH_P  :
                col==4'd6 ? CH_1 + {2'd0,b_ctl} :
                col==4'd8 ? CH_GT : 5'd0;
end

// stage C: pixel. Three clocks after ox/oy.
reg [4:0] gbits;
always @(posedge clk) begin
    gbits = glyph( b_ch, b_row );
    if( !b_in )
        ovl <= 0;
    else if( b_sub < 3'd5 && gbits[3'd4-b_sub] )
        ovl <= b_line ? 2'd2 : 2'd3;
    else
        ovl <= 2'd1;
end

endmodule
