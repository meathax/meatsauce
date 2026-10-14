//============================================================================
//  System 32 object/sprite engine — 315-5386A
//  (DESIGN.md §6.3/§6.4, Appendix C.6/C.7)
//  Walks the sprite command list in sprite RAM, renders scaled sprites into
//  the off-chip framebuffer via s32_fb_if. CPU-visible A/B control is paired
//  with completed-frame physical rotation; swap/erase registers latch exactly
//  like m_sprite_control_latched.
//
//  Sprite list entry (8 words) — DESIGN.md §6.3.
//  Framebuffer pixel = 0x8000 | color | pen ; shadow clears bit15.
//============================================================================

module s32_sprite #(
    // update_sprites() runs 50 us after VBLANK ends. At 96.634615 MHz this
    // is round(50 us * clk_ram) = 4,832 clocks.
    parameter integer POST_VBLANK_CYCLES = 4832,
    // Dedicated Golden Axe hardware profile: verify FPGA SDRAM sprite bursts.
    parameter bit VERIFY_SROM = 1'b0,
    // Exact common-path accelerator.  Set false only in differential benches
    // to retain the fully general R_PIXEL/R_EMIT cadence as a fallback model.
    parameter bit FAST_1X = 1'b1
) (
    input             clk,          // clk_ram
    input             rst,
    input             is_multi32,
    // Selected output screen (MiSTer status[6]). Both Multi 32 fetch lanes
    // share the physical A/B pair; this bit is retained in scan_buf[1] for
    // the final display selection while scan_buf[0] is the published pair.
    input             screen_sel,
    input       [1:0] srom_bank_mask,

    // frame control
    input             present,      // start-of-vblank: publish completed physical frame
    input             verify_srom,     // GA2: confirm repeated SDRAM bursts agree
    input             vblank,       // end-of-vblank pulse (1 clk_sys wide =
                                    // 2 clk_ram samples; edge-detected below)

    // sprite control registers (0x500000, byte regs 0..7)
    input             ctl_we,
    input       [2:0] ctl_addr,
    input       [7:0] ctl_wdata,
    output reg  [7:0] ctl_rdata,
    input       [2:0] ctl_raddr,

    // sprite RAM read port (word)
    output reg [15:0] slist_addr,
    input      [15:0] slist_data,

    // sprite ROM via SDRAM p2 port (128-bit bursts)
    output reg        srom_req,
    output reg [23:4] srom_addr,
    input     [127:0] srom_data,
    input             srom_ack,

    // framebuffer interface
    output reg        fb_wr_start,
    output reg  [1:0] fb_wr_buf,
    output reg  [8:0] fb_wr_x,
    output reg  [7:0] fb_wr_y,
    output reg        fb_wr_valid,
    output reg [15:0] fb_wr_pix,
    output reg        fb_wr_end,
    output reg        fb_wr_shadow,  // this run RMWs dest &= 0x7fff (V-10)
    input             fb_busy,       // any run still queued/flushing (drain)
    input             fb_can_start,  // a capture context is free for a new row
    output reg        fb_er_req,
    output reg  [1:0] fb_er_buf,
    output reg  [7:0] fb_er_y,
    input             fb_er_ack,

    output reg  [1:0] disp_buf,     // CPU-visible logical A/B selector
    output reg  [1:0] scan_buf      // completed physical buffer used by scanout

);

// control registers
reg [7:0] ctl [0:7];
reg [7:0] ctl_latched [0:7];
reg       render_count;             // MAME m_sprite_render_count (0/1)
reg       render_after_erase;       // combined command: render after hidden erase
reg       erase_after_swap;         // combined command: swap before destructive clear
reg [1:0] erase_buf_sel;            // physical buffer selected for erase
reg       erase_mon;                // Multi32 erase visits both monitors
reg [1:0] work_buf;                 // hidden System 32 erase/render target
reg [1:0] ready_buf;                // completed frame awaiting vblank publication
reg       ready_valid;
reg       publish_on_done;          // current command produces a publishable frame
reg [15:0] post_vblank_count;
reg        vblank_pending;          // audit R20 SP-3: vblank seen mid-render
reg        vblank_d;                // edge-detect the end-of-vblank pulse
reg        present_d;               // edge-detect the start-of-vblank pulse
// The video pulse is one clk_sys wide; on the 2x clk_ram domain it is
// sampled high on two consecutive edges.  Treat only its rising edge as a new
// frame event, or the SP-3 pending latch re-catches the same pulse and fires a
// second full erase/swap/render pass mid-frame (the sprite-buffer tear).
wire       vblank_rise = vblank & ~vblank_d;
wire       present_rise = present & ~present_d;

// The serialized FPGA renderer can overrun a field in sprite-heavy scenes.
// System 32 leaves framebuffer slots 2/3 unused by the original A/B mapping,
// so use slot 2 as a third physical buffer.  Never select the scanned buffer
// or a completed buffer waiting to be published as the next work target.
function automatic [1:0] choose_work_buf(
    input [1:0] scan,
    input [1:0] ready,
    input       valid
);
    begin
        if (scan != 2'd0 && (!valid || ready != 2'd0))
            choose_work_buf = 2'd0;
        else if (scan != 2'd1 && (!valid || ready != 2'd1))
            choose_work_buf = 2'd1;
        else
            choose_work_buf = 2'd2;
    end
endfunction

always @(*) begin
    case (ctl_raddr)
        // MAME exposes only selected-buffer bit 0. Erase-busy appears only
        // in an old source-code comment, not in the implementation.
        // MAME reg 0 bit0 = (SPRITES.num < SPRITES_2.num): reads 1 at power-up
        // (6<8) and toggles to 0 after the first swap — the exact complement of
        // the internal displaying-buffer selector, which resets to 0 and reads
        // 1 after the first swap.  Invert only the CPU-visible bit; the internal
        // render/erase/display targeting is unchanged (audit R20 SP-1).
        3'd0: ctl_rdata = {6'h3f, 1'b0, ~disp_buf[0]};
        3'd1: ctl_rdata = {6'h3f, 2'd1};              // status: normal
        3'd2: ctl_rdata = {6'h3f, ctl_latched[2][1:0]};
        3'd3: ctl_rdata = {6'h3f, ctl_latched[3][1:0]};
        3'd4: ctl_rdata = {6'h3f, ctl_latched[4][1:0]};
        3'd5: ctl_rdata = {6'h3f, ctl_latched[5][1:0]};
        3'd6: ctl_rdata = {6'h3f, 1'b0, ctl_latched[6][0]};
        default: ctl_rdata = 8'hfc;
    endcase
end

// list walker / renderer FSM
typedef enum logic [4:0] {
    R_IDLE, R_SWAP, R_RENDER, R_ERASE, R_ERASEW,
    R_FETCH, R_FETCHP, R_FETCHW, R_DECODE, R_SCALE,
    R_INDTAB, R_INDTABP, R_INDTABW,
    R_ROW, R_ROWDATA, R_ROWDATAW,
    R_RAMDATA, R_RAMDATAP, R_RAMDATAW,
    R_PIXEL, R_EMIT, R_SCAN,
    R_DONE, R_DELAY,
    R_ROM_GAP, R_ROM_VERIFY, R_ROM_VERIFYW, R_ROM_RETRY
} rst_t;
`ifdef S32_PROFILE_STANDARD
// Dedicated builds have enough ALM headroom to trade a few state
// flops for much shallower renderer enables.  Binary rs[0] decoding was the
// remaining 96 MHz critical cone after the dedicated profile was pruned.
(* syn_encoding = "onehot" *) rst_t rs;
`else
rst_t rs;
`endif

// latched sprite entry
reg [15:0] sw [0:7];
reg [2:0]  swi;
reg [12:0] list_idx;                 // entry index (16-byte units)
// The hardware reports an overdraw condition when list processing runs past
// its budget.  MAME's controller model bounds a frame to the 0x20000-byte
// sprite RAM divided by one 16-byte command (8192 commands).  Without the
// same bound, a missing END or a self-referential JUMP traps this FSM forever
// and leaves the last displayed framebuffer frozen while the V60 keeps going.
reg [13:0] list_count;
reg [15:0] clip_l, clip_t, clip_r, clip_b;   // in-clip rect
reg        clip_en, clipout_en;
reg [15:0] cout_l, cout_t, cout_r, cout_b;
reg [31:0] jump_xoff, jump_yoff;

// decoded fields
wire        d_ind    = sw[0][13];
wire        d_indloc = sw[0][12];
wire        d_shad   = sw[0][11] & ctl_latched[5][0]; // reg 0x0a bit0
wire        d_fromram= sw[0][10];
wire        d_bpp8   = sw[0][9];
wire        d_opaque = sw[0][8];
wire        d_flipy  = sw[0][7];
wire        d_flipx  = sw[0][6];
wire [1:0]  d_ay     = sw[0][3:2];
wire [1:0]  d_ax     = sw[0][1:0];
wire [7:0]  d_srch   = sw[1][15:8];
wire [5:0]  d_srcw   = d_bpp8 ? sw[1][5:0] : sw[1][6:1];
wire [9:0]  d_dsth   = sw[2][9:0];
wire [9:0]  d_dstw   = sw[3][9:0];
wire [1:0]  d_bank   = is_multi32 ? {sw[3][15], sw[3][13]} : {sw[3][14], sw[3][11]};
wire [1:0]  d_bank_eff = d_bank & srom_bank_mask;
wire        d_mon    = is_multi32 & sw[3][11];
wire [11:0] d_ypos   = sw[4][11:0];
wire [11:0] d_xpos   = sw[5][11:0];
wire [19:0] d_addr   = {sw[2][15:12], sw[6]};
wire [15:0] d_color  = 16'h8000 | (sw[7] & (d_bpp8 ? 16'h7f00 : 16'h7ff0));

// scaling accumulators
reg [24:0] yacc, ystep;   // MAME controller model uses 16.16 zoom
reg [24:0] xacc, xstep;
reg [9:0]  dy, dx;        // dest iterators
reg signed [13:0] x0, y0; // wide MAME int-domain origin; no 12-bit wrap
reg [15:0] indtab [0:15];
reg [3:0]  indi;
reg [127:0] pixrow;
// The MiSTer SDRAM port is the only part of the Golden Axe sprite path that
// cannot be reproduced by the cycle-exact MAME/RTL replays. Qualify every
// 128-bit ROM cache line with a second identical read before publishing it to
// the pixel walker. A transient/contended SDRAM capture can otherwise turn a
// valid descriptor into persistent garbage in the off-chip sprite framebuffer.
reg [127:0] srom_verify_data;
reg [15:0]  srom_retry_count;
reg [23:4]  rowbase;
reg [23:0] row_byte_base; // sprite base + source-row pitch, once per row
reg [15:0] ram_fetch_base;
reg [2:0]  ram_fetch_i;
reg [15:0] ram_even;

// simple per-row source fetch cache tag
reg [23:4] rowtag;
reg        rowtag_v;

// V-8 exact pen semantics state
reg [15:0] transmask_r;    // indirect transparency mask (ctl regs 4/5)
reg        do_clipout_row; // clip-out rect covers this row's y
// Next sequential 32-bit source word whose final pen has not been checked.
// MAME visits every word even if strong downscale emits no pixel from it.
reg [9:0]  end_scan_word;


// Pixel address/position stage.  R_PIXEL verifies the source cache and
// registers these inexpensive coordinates; R_EMIT performs the wide dynamic
// pen select, transparency/clip tests, and framebuffer write one clock later.
// This removes the x-scale accumulator from the full decode/output path.
reg signed [13:0] pixel_scrx;
reg        [9:0]  pixel_sx_px;
reg        [2:0]  pixel_piw, pixel_piw_last;
reg        [9:0]  pixel_wordi;
reg        [7:0]  pixel_pen8;
reg        [3:0]  pixel_byteoff;
reg        [23:0] scan_byteaddr;

// Width is latched at buffer swap; a live write cannot alter this pass.
wire [8:0] hpix = ctl_latched[6][0] ? 9'd416 : 9'd320;
wire [9:0] d_dstw_center = (d_dstw - 10'd1) >> 1;
wire [9:0] d_dsth_center = (d_dsth - 10'd1) >> 1;

// A combinational 20-by-10 divide here makes Quartus expand two very large
// divider networks while elaborating the sprite engine.  Scaling setup is not
// on the pixel-rate path, so share one restoring divider across Y then X.
// The 25-bit numerators preserve MAME's unsigned 16.16 controller math.
wire [24:0] scale_ynum = {1'b0, d_srch, 16'b0};
wire [24:0] scale_xnum = d_bpp8 ? {1'b0, d_srcw, 18'b0}
                                     : {d_srcw, 19'b0};
wire        scale_start = (rs == R_DECODE) && (sw[0][15:14] == 2'b00) &&
                          (d_srcw != 0) && (d_srch != 0) &&
                          (d_dstw != 0) && (d_dsth != 0);
wire        scale_busy, scale_done;
wire [24:0] scale_yquot, scale_xquot;

s32_sprite_scale_div scale_div (
    .clk(clk), .rst(rst), .start(scale_start),
    .ynum(scale_ynum), .yden(d_dsth),
    .xnum(scale_xnum), .xden(d_dstw),
    .busy(scale_busy), .done(scale_done),
    .yquot(scale_yquot), .xquot(scale_xquot)
);

// MAME transparency_masks[ctl4 & 3][ctl5 & 3]
function automatic [15:0] transmask_of(input [1:0] row, input [1:0] col);
    logic [15:0] base;
    case (col)
        2'b00: base = 16'h7fff; 2'b01: base = 16'h3fff;
        2'b10: base = 16'h1fff; default: base = 16'h0fff;
    endcase
    case (row)
        2'b00:   transmask_of = base;
        2'b11:   transmask_of = base >> 2;
        default: transmask_of = base >> 1;
    endcase
endfunction

function automatic [11:0] sext12(input [11:0] v);
    sext12 = v;
endfunction

always @(posedge clk) begin
    if (rst) begin
        rs <= R_IDLE;
        disp_buf <= 2'b00;
        scan_buf <= 2'b00;
        srom_verify_data <= 128'd0;
        srom_retry_count <= 16'd0;
        list_count <= 0;
        srom_req <= 0; fb_er_req <= 0;
        fb_wr_valid <= 0; fb_wr_start <= 0; fb_wr_end <= 0;
        fb_wr_shadow <= 0;
        render_count <= 0; render_after_erase <= 0;
        erase_after_swap <= 0; erase_buf_sel <= 0;
        erase_mon <= 0; post_vblank_count <= 0;
        work_buf <= 2'd1;
        ready_buf <= 2'd0;
        ready_valid <= 1'b0;
        publish_on_done <= 1'b0;
        vblank_pending <= 1'b0;         // audit R20 SP-3
        vblank_d <= 1'b0;
        present_d <= 1'b0;
        jump_xoff <= 0; jump_yoff <= 0;
        // control regs power up cleared (auto swap mode) — leaving them
        // uninitialized stalls the walker in R_IDLE until the game writes them
        for (int i = 0; i < 8; i++) begin
            ctl[i] <= 8'h00; ctl_latched[i] <= 8'h00;
        end
    end
    else begin
        fb_wr_start <= 0;
        fb_wr_valid <= 0;
        fb_wr_end   <= 0;
        vblank_d    <= vblank;
        present_d   <= present;

        // CPU control writes
        if (ctl_we) begin
            ctl[ctl_addr] <= ctl_wdata;
        end

        // Keep logical controller timing separate from physical ownership.
        // Only a frame that reached R_DONE may become visible, and publication
        // occurs at the raster boundary before the line-0 framebuffer fetch.
        if (present_rise && ready_valid) begin
            scan_buf <= is_multi32 ? {screen_sel, ready_buf[0]} : ready_buf;
            ready_valid <= 1'b0;
        end

        // audit R20 SP-3: a vblank pulse arriving while the FSM is still
        // erasing/rendering (not R_IDLE) is otherwise dropped, delaying that
        // frame's swap. Latch it and consume it on the next return to R_IDLE.
        // MAME never misses because its render is instantaneous.  Qualify on the
        // rising edge so the same 2-clk_ram-wide pulse that already launched the
        // current sequence in R_IDLE is not re-latched as a second event.
        if (vblank_rise && rs != R_IDLE) vblank_pending <= 1'b1;

        case (rs)
        R_IDLE: if (vblank_rise || vblank_pending) begin
            vblank_pending <= 1'b0;     // audit R20 SP-3: consume latched vblank
            post_vblank_count <= POST_VBLANK_CYCLES;
            rs <= R_DELAY;
        end

        // system32_set_vblank() arms update_sprites() for 50 us later. This
        // lets the V60 finish the next object list before the controller reads.
        R_DELAY: if (post_vblank_count > 16'd1) begin
            post_vblank_count <= post_vblank_count - 1'd1;
        end
        else if (is_multi32 && ready_valid) begin
            // Multi 32 has only two physical A/B pairs. If a serialized
            // render completed after the last present edge, keep the old
            // field and wait for the next raster publication before reusing
            // the pair that is no longer scanned.
            vblank_pending <= 1'b1;
            rs <= R_IDLE;
        end
        else begin
            logic [1:0] command;
            // reg0 bit1 erases the displayed buffer; bit0 swaps/renders.
            // Automatic mode uses MAME's 0/1 down-counter exactly, including
            // mode changes between 60 Hz and 30 Hz.
            command = ctl[0][1:0];
            if (!ctl[3][1]) begin
                if (render_count == 1'b0) begin
                    command = 2'b11;
                    render_count <= ctl[3][0];
                end
                else begin
                    // audit R20 SP-2: on the 30Hz skip frame MAME leaves
                    // m_sprite_control[0] untouched (m_sprite_render_count--
                    // != 0), so a CPU-written manual command still executes.
                    command = ctl[0][1:0];
                    render_count <= render_count - 1'd1;
                end
            end
            ctl[0] <= 0;
            if (command == 2'b11) begin
                // Toggle the logical controller, then clear/render a hidden
                // physical buffer. Scanout changes only after R_DONE.
                erase_after_swap <= 1'b1;
                render_after_erase <= 1'b0;
                rs <= R_SWAP;
            end
            else if (command[1]) begin
                logic [1:0] erase_work;
                render_after_erase <= 1'b0;
                erase_after_swap <= 1'b0;
                fb_er_y <= 0;
                erase_mon <= 1'b0;
                if (is_multi32) begin
                    publish_on_done <= 1'b0;
                    erase_buf_sel <= {1'b0, ~scan_buf[0]};
                end
                else begin
                    erase_work = choose_work_buf(scan_buf, ready_buf,
                                                 ready_valid);
                    work_buf <= erase_work;
                    erase_buf_sel <= erase_work;
                    publish_on_done <= 1'b1;
                end
                rs <= R_ERASE;
            end
            else if (command[0]) begin
                render_after_erase <= 1'b0;
                erase_after_swap <= 1'b0;
                rs <= R_SWAP;
            end
            else rs <= R_IDLE;
        end

        R_SWAP: begin
            logic [1:0] next_work;
            if (is_multi32)
                next_work = {1'b0, ~scan_buf[0]};
            else
                next_work = choose_work_buf(scan_buf, ready_buf, ready_valid);
            disp_buf <= {1'b0, ~disp_buf[0]}; // bit0 is the sole A/B selector
            publish_on_done <= 1'b1;
            work_buf <= next_work;
            erase_buf_sel <= next_work;
            for (int i = 0; i < 8; i++) ctl_latched[i] <= ctl[i];
            ctl[0] <= 0;
            if (erase_after_swap) begin
                erase_after_swap <= 1'b0;
                render_after_erase <= 1'b1;
                fb_er_y <= 8'd0;
                erase_mon <= 1'b0;
                rs <= R_ERASE;
            end
            else begin
                render_after_erase <= 1'b0;
                rs <= R_RENDER;
            end
        end
        R_RENDER: begin
            list_idx <= 0;
            list_count <= 0;
            jump_xoff <= 0; jump_yoff <= 0;
            clip_en <= 0; clipout_en <= 0;
            clip_l <= 0; clip_t <= 0;
            clip_r <= {7'b0, 9'd511}; clip_b <= 16'd255;
            rs <= R_FETCH;
        end
        R_ERASE: begin
            fb_er_req <= 1'b1;
            fb_er_buf <= is_multi32 ? {erase_mon, erase_buf_sel[0]}
                                    : erase_buf_sel;
            rs <= R_ERASEW;
        end
        R_ERASEW: if (fb_er_ack) begin
            fb_er_req <= 0;
            if (fb_er_y == 8'd223) begin
                if (is_multi32 && !erase_mon) begin
                    // Multi32 clears the visible framebuffer on both monitors
                    // before the shared buffer-pair swap.
                    erase_mon <= 1'b1;
                    fb_er_y <= 8'd0;
                    rs <= R_ERASE;
                end
                else begin
                    render_after_erase <= 1'b0;
                    if (render_after_erase) rs <= R_RENDER;
                    else                    rs <= R_DONE;
                end
            end
            else begin
                fb_er_y <= fb_er_y + 1'd1;
                rs <= R_ERASE;
            end
        end

        // fetch 8 words of the current entry
        // (slist_data is a registered BRAM read: q lags addr by one clk,
        //  so prime the pipeline one cycle before sampling)
        R_FETCH: begin
            swi <= 0;
            slist_addr <= {list_idx, 3'b000};
            rs <= R_FETCHP;
        end
        R_FETCHP: begin
            slist_addr <= {list_idx, 3'b000} + 16'd1;
            rs <= R_FETCHW;
        end
        R_FETCHW: begin
            sw[swi] <= slist_data;   // = mem[base+swi]
            if (swi == 3'd7) rs <= R_DECODE;
            else begin
                swi <= swi + 1'd1;
                slist_addr <= {list_idx, 3'b000} + swi + 16'd2;
            end
        end

        R_DECODE: begin
            if (list_count == 14'd8192) begin
                // Bounded-list overdraw: abandon this frame and return to
                // R_IDLE so the next vblank can start a fresh sprite pass.
                publish_on_done <= 1'b0;
                rs <= R_DONE;
            end
            else begin
            list_count <= list_count + 1'd1;
            case (sw[0][15:14])
            2'b11: begin
                rs <= R_DONE;
            end                                                   // end of list
            2'b10: begin                                          // jump
                if (sw[0][13]) begin
                    jump_yoff <= {20'b0, sw[1][11:0]};
                    jump_xoff <= {20'b0, sw[2][11:0]};
                end
                list_idx <= sw[0][12:0];
                rs <= R_FETCH;
            end
            2'b01: begin                                          // set clip
                // MAME: bit12 of word0 gates clip-in (words 0-3: y0,y1,x0,x1
                // sext12); bit13 gates clip-out (words 4-7)
                if (sw[0][12]) begin
                    clip_en <= 1'b1;
                    clip_t <= {{4{sw[0][11]}}, sw[0][11:0]};
                    clip_b <= {{4{sw[1][11]}}, sw[1][11:0]};
                    clip_l <= {{4{sw[2][11]}}, sw[2][11:0]};
                    clip_r <= {{4{sw[3][11]}}, sw[3][11:0]};
                end
                // MAME changes clip-out only when bit 13 is set.  A later
                // clip-in-only command leaves the previous exclusion active.
                if (sw[0][13]) begin
                    clipout_en <= 1'b1;
                    cout_t <= {{4{sw[4][11]}}, sw[4][11:0]};
                    cout_b <= {{4{sw[5][11]}}, sw[5][11:0]};
                    cout_l <= {{4{sw[6][11]}}, sw[6][11:0]};
                    cout_r <= {{4{sw[7][11]}}, sw[7][11:0]};
                end
                list_idx <= list_idx + 1'd1;
                rs <= R_FETCH;
            end
            default: begin                                        // draw sprite
                if (d_srcw == 0 || d_srch == 0 || d_dstw == 0 || d_dsth == 0) begin
                    // Inline indirect tables occupy the following two list
                    // entries even when the draw itself has zero dimensions.
                    list_idx <= list_idx + 1'd1
                              + (d_ind && d_indloc ? 13'd2 : 13'd0);
                    rs <= R_FETCH;
                end
                else begin
                    // Hardware has two center encodings (00 and 11).  Center
                    // uses (size-1)/2, which matters for even-width sprites.
                    // 10=start, 01=end.
                    logic signed [13:0] xx, yy;
                    // MAME uses int arithmetic after sign-extending both
                    // 12-bit values.  Explicitly widen before addition so
                    // large negative offsets cannot wrap back onscreen.
                    xx = {{2{d_xpos[11]}}, d_xpos}
                       + (sw[0][4] ? {{2{jump_xoff[11]}}, jump_xoff[11:0]} : 14'sd0);
                    yy = {{2{d_ypos[11]}}, d_ypos}
                       + (sw[0][5] ? {{2{jump_yoff[11]}}, jump_yoff[11:0]} : 14'sd0);
                    case (d_ax)
                        2'b00, 2'b11:
                            xx = xx - $signed({4'b0000, d_dstw_center});
                        2'b01:
                            xx = xx - $signed({4'b0000, d_dstw}) + 14'sd1;
                        default: ;
                    endcase
                    case (d_ay)
                        2'b00, 2'b11:
                            yy = yy - $signed({4'b0000, d_dsth_center});
                        2'b01:
                            yy = yy - $signed({4'b0000, d_dsth}) + 14'sd1;
                        default: ;
                    endcase
                    x0 <= xx; y0 <= yy;
                    transmask_r <= transmask_of(ctl_latched[4][1:0],
                                                ctl_latched[5][1:0])
                                   & (d_bpp8 ? 16'hfff0 : 16'hffff);
                    yacc <= 0;
                    dy <= 0;
                    indi <= 0;
                    rs <= R_SCALE;
                end
            end
            endcase
            end
        end

        // The shared divider produces both unsigned 16.16 steps exactly 50
        // clocks after scale_start.  One following clock transfers the pair
        // atomically before any row or indirect-table work can consume them.
        R_SCALE: if (scale_done) begin
            ystep <= scale_yquot;
            xstep <= scale_xquot;
            if (d_ind) rs <= R_INDTAB;
            else       rs <= R_ROW;
        end

        // indirect palette table load (inline or spriteram)
        R_INDTAB: begin
            slist_addr <= d_indloc ? ({list_idx, 3'b000} + 4'd8 + indi)
                                   : ({sw[7][12:0], 3'b000} + indi);
            rs <= R_INDTABP;
        end
        R_INDTABP: rs <= R_INDTABW;   // BRAM q lag: dead cycle before sampling
        R_INDTABW: begin
            // MAME: entry & (bpp8 ? 0xfff0 : 0xffff), bit15 forced when the
            // shadow-enable bit (ctl reg5 bit0) is set
            indtab[indi] <= (slist_data & (d_bpp8 ? 16'hfff0 : 16'hffff))
                          | (ctl_latched[5][0] ? 16'h8000 : 16'h0000);
            if (indi == 4'hf) rs <= R_ROW;
            else begin indi <= indi + 1'd1; rs <= R_INDTAB; end
        end

        // per destination row. Flip reverses the DESTINATION sweep while the
        // source reads forward (hardware/MAME model) — end codes and word
        // transparency track source order regardless of flip.
        R_ROW: begin
            logic signed [13:0] scry;
            logic [12:0] sy_now;
            scry = d_flipy ? (y0 + $signed({4'b0000, d_dsth})
                              - 14'sd1 - $signed({4'b0000, dy}))
                           : (y0 + $signed({4'b0000, dy}));
            sy_now = {4'b0000, yacc[24:16]};
            // The row multiply is invariant across every destination pixel.
            // Register it here so R_PIXEL only performs a small offset add.
            row_byte_base <= ({4'b0, d_addr} << 2)
                           + (sy_now * {d_srcw, 2'b00});
            if (dy == d_dsth) begin
                list_idx <= list_idx + 1'd1 + (d_ind && d_indloc ? 13'd2 : 13'd0);
                rs <= R_FETCH;
            end
            else if (scry < 0 || scry > 14'sd223 ||
                     (clip_en && (scry < $signed(clip_t) ||
                                  scry > $signed(clip_b)))) begin
                dy <= dy + 1'd1;               // row not visible: skip
                yacc <= yacc + ystep;
                rs <= R_ROW;
            end
            else if (fb_can_start) begin // wait for a free capture context
                xacc <= 0;
                dx <= 0;
                rowtag_v <= 0;
                end_scan_word <= 0;
                do_clipout_row <= clipout_en && scry >= $signed(cout_t)
                                             && scry <= $signed(cout_b);
                fb_wr_start <= 1'b1;
                fb_wr_buf <= is_multi32 ? {d_mon, work_buf[0]} : work_buf;
                // MAME applies latched controller flip while scanning the
                // displayed sprite framebuffer.  Mirroring writes into the
                // back buffer is equivalent and keeps the framebuffer read
                // interface sequential.
                fb_wr_y <= ctl_latched[2][1] ? (8'd223 - scry[7:0])
                                              : scry[7:0];
                fb_wr_shadow <= d_shad;
                rs <= R_PIXEL;
            end
        end

        // fetch 128-bit chunk of source row when needed
        R_ROWDATA: begin
            srom_req <= 1'b1;
            srom_addr <= rowbase;
            rs <= R_ROWDATAW;
        end
        R_ROWDATAW: if (srom_ack) begin
            srom_req <= 0;
            if (VERIFY_SROM && verify_srom) begin
                srom_verify_data <= srom_data;
                // The SDRAM acknowledge is stretched for the clk_sys crossing.
                // Wait for it to fall before creating the second request edge.
                rs <= R_ROM_GAP;
            end
            else begin
                pixrow <= srom_data;
                rowtag <= rowbase;
                rowtag_v <= 1'b1;
                rs <= R_PIXEL;
            end
        end
        R_ROM_GAP: if (!srom_ack) begin
            rs <= R_ROM_VERIFY;
        end
        R_ROM_VERIFY: begin
            srom_req <= 1'b1;
            srom_addr <= rowbase;
            rs <= R_ROM_VERIFYW;
        end
        R_ROM_VERIFYW: if (srom_ack) begin
            srom_req <= 1'b0;
            if (srom_data == srom_verify_data) begin
                pixrow <= srom_data;
                rowtag <= rowbase;
                rowtag_v <= 1'b1;
                rs <= R_PIXEL;
            end
            else begin
                if (~&srom_retry_count)
                    srom_retry_count <= srom_retry_count + 1'd1;
                // Discard both samples. Start a fresh pair only after the
                // stretched acknowledge has returned low.
                rs <= R_ROM_RETRY;
            end
        end
        R_ROM_RETRY: if (!srom_ack) begin
            rs <= R_ROWDATA;
        end

        // Pixel-from-sprite-RAM mode shares the list RAM read port while the
        // draw command is active.  Four pairs of CPU-visible halfwords form a
        // 16-byte cache line.  Repack each pair to the same byte layout as a
        // sprite-ROM burst (matching the 315-5386/MAME controller model).
        R_RAMDATA: begin
            ram_fetch_i <= 0;
            slist_addr <= ram_fetch_base;
            rs <= R_RAMDATAP;
        end
        R_RAMDATAP: begin
            slist_addr <= ram_fetch_base + 16'd1;
            rs <= R_RAMDATAW;
        end
        R_RAMDATAW: begin
            if (!ram_fetch_i[0]) begin
                ram_even <= slist_data;
            end
            else begin
                // MAME consumes m_spriteram_32bit MSB-first. Store the
                // byte-addressed interface image so byte zero returns that
                // MSB (even=5678, odd=1234 renders 7,8,5,6,3,4,1,2).
                pixrow[{ram_fetch_i[2:1], 5'b00000} +: 32] <=
                    {slist_data[15:8], slist_data[7:0],
                     ram_even[15:8], ram_even[7:0]};
            end

            if (ram_fetch_i == 3'd7) begin
                rowtag <= rowbase;
                rowtag_v <= 1;
                rs <= R_PIXEL;
            end
            else begin
                ram_fetch_i <= ram_fetch_i + 1'd1;
                slist_addr <= ram_fetch_base + {13'b0, ram_fetch_i} + 16'd2;
            end
        end

        R_PIXEL: begin
            logic signed [13:0] scrx;
            logic [9:0]  sx_px;        // source pixel index within the row
            logic [2:0]  piw, piw_last;// position within the 32-bit word
            logic [9:0]  wordi;        // source 32-bit word index
            logic [23:0] byteaddr;
            logic [23:4] need;
            logic        scan_pending;
            logic signed [15:0] clip_x_min, clip_x_max;

            scrx = d_flipx ? (x0 + $signed({4'b0000, d_dstw})
                              - 14'sd1 - $signed({4'b0000, dx}))
                           : (x0 + $signed({4'b0000, dx}));
            clip_x_min = (clip_en && $signed(clip_l) > 0) ? $signed(clip_l) : 16'sd0;
            clip_x_max = (clip_en && $signed(clip_r) < $signed({7'b0, hpix}) - 1)
                       ? $signed(clip_r) : $signed({7'b0, hpix}) - 1;
            sx_px = {1'b0, xacc[24:16]};
            piw      = d_bpp8 ? {1'b0, sx_px[1:0]} : sx_px[2:0];
            piw_last = d_bpp8 ? 3'd3 : 3'd7;
            wordi    = d_bpp8 ? {2'b0, sx_px[9:2]} : {3'b0, sx_px[9:3]};
            byteaddr = row_byte_base
                     + (d_bpp8 ? {14'b0, sx_px} : {15'b0, sx_px[9:1]});
            need = d_fromram ? {7'b0, byteaddr[16:4]}
                             : {d_bank_eff, byteaddr[21:4]};
            scan_pending = end_scan_word < wordi;

            // MAME clips the trailing xtarget before its source loop. Keep
            // leading off-screen traversal (which advances zoom), but stop as
            // soon as the destination sweep passes the inclusive clip edge.
            if (dx == d_dstw ||
                (!d_flipx && scrx > clip_x_max) ||
                ( d_flipx && scrx < clip_x_min)) begin
                fb_wr_end <= 1'b1;
                dy <= dy + 1'd1;
                yacc <= yacc + ystep;
                rs <= R_ROW;
            end
            // Destination-oriented zoom can jump over complete source words.
            // Register the skipped-word address before the cache lookup and
            // dynamic pixrow select. This keeps end_scan_word out of the
            // 96.6 MHz cache/mux path while preserving MAME's sequential
            // end-code scan.
            else if (scan_pending) begin
                scan_byteaddr <= row_byte_base
                               + {12'b0, end_scan_word, 2'b00};
                rs <= R_SCAN;
            end
            else if (!rowtag_v || need != rowtag) begin
                rowbase <= need;
                if (d_fromram) begin
                    ram_fetch_base <= {byteaddr[16:4], 3'b000};
                    rs <= R_RAMDATA;
                end
                else rs <= R_ROWDATA;
            end
            else begin
                // Ordinary cached pixels use the original two-stage pipeline:
                // R_PIXEL selects/registers the source byte and R_EMIT applies
                // pen/clip/transparency semantics.  The added R_PIXEL_DATA
                // state made every destination pixel take three clocks and
                // pushed sprite-heavy games beyond their per-field budget.
                // Cache misses and skipped-word END scans retain their fully
                // general paths above and in R_SCAN.
                pixel_scrx     <= scrx;
                pixel_sx_px    <= sx_px;
                pixel_piw      <= piw;
                pixel_piw_last <= piw_last;
                pixel_wordi    <= wordi;
                pixel_pen8     <= pixrow[{byteaddr[3:0], 3'b000} +: 8];
                pixel_byteoff  <= byteaddr[3:0];
                rs <= R_EMIT;
            end
        end

        // Check the final pen of a source word skipped by destination zoom.
        // scan_byteaddr is registered in R_PIXEL so the cache tag comparison
        // and variable pixrow select do not feed back from end_scan_word in
        // the same fast-clock cycle.
        R_SCAN: begin
            logic [23:4] need;
            logic        scan_end;
            need = d_fromram ? {7'b0, scan_byteaddr[16:4]}
                             : {d_bank_eff, scan_byteaddr[21:4]};
            scan_end = d_bpp8
                     ? (pixrow[{scan_byteaddr[3:2], 5'b11000} +: 8] == 8'hff)
                     : (pixrow[{scan_byteaddr[3:2], 5'b11000} +: 4] == 4'hf);
            if (!rowtag_v || need != rowtag) begin
                rowbase <= need;
                if (d_fromram) begin
                    ram_fetch_base <= {scan_byteaddr[16:4], 3'b000};
                    rs <= R_RAMDATA;
                end
                else rs <= R_ROWDATA;
            end
            else if (!d_opaque && scan_end) begin
                fb_wr_end <= 1'b1;
                dy <= dy + 1'd1;
                yacc <= yacc + ystep;
                rs <= R_ROW;
            end
            else begin
                end_scan_word <= end_scan_word + 1'd1;
                rs <= R_PIXEL;
            end
        end

        R_EMIT: begin
            logic [3:0]  pen4;
            logic [7:0]  pen8, pix, trans_now;
            logic [15:0] outpix, indpix;
            logic        gate_clip, gate_draw;
            logic signed [13:0] next_scrx;
            logic signed [15:0] clip_x_min, clip_x_max;
            logic [9:0]  next_dx, next_sx_px, next_wordi;
            logic [2:0]  next_piw;
            logic [3:0]  next_byteoff;
            logic        same_cache;
            logic        fast_continue;
            logic [24:0] xacc_next;
            logic        src_adv;

            // Pen extract: bits 31:28 of the BE word = leftmost pixel;
            // even source px = high nibble of its byte.
            pen8 = pixel_pen8;
            pen4 = pixel_sx_px[0] ? pen8[3:0] : pen8[7:4];
            pix  = d_bpp8 ? pen8 : {4'b0, pen4};
            // MAME: first/last pixel of each 32-bit word uses transp
            // (0x0f/0xff, or 0 when opaque); middle pixels use 0.
            trans_now = (pixel_piw == 3'd0 || pixel_piw == pixel_piw_last)
                      ? (d_opaque ? 8'h00 : (d_bpp8 ? 8'hff : 8'h0f))
                      : 8'h00;
            gate_clip = (pixel_scrx >= 0) &&
                (pixel_scrx < $signed({4'b0, hpix})) &&
                (!clip_en || (pixel_scrx >= $signed(clip_l) &&
                              pixel_scrx <= $signed(clip_r))) &&
                (!do_clipout_row || !(pixel_scrx >= $signed(cout_l) &&
                                      pixel_scrx <= $signed(cout_r)));
            indpix = d_bpp8 ? (indtab[pen8[7:4]] | {8'b0, pen8[3:0]})
                            : indtab[pen4];
            if (d_ind) begin
                // Indirect: table entry decides transparency via transmask.
                gate_draw = (pix != trans_now) &&
                            ((indpix & transmask_r) != transmask_r);
                outpix = indpix;
            end
            else begin
                // Direct: pen 0 is never drawn (even opaque).
                gate_draw = (pix != trans_now) && (pix != 8'h00);
                outpix = d_color | {8'b0, pix};
            end
            fb_wr_valid <= gate_clip && gate_draw;
            fb_wr_pix   <= outpix;   // shadow runs RMW in fb_if
            fb_wr_x     <= ctl_latched[2][0]
                         ? (hpix - 9'd1 - pixel_scrx[8:0])
                         : pixel_scrx[8:0];
            // End code seen directly at the word's final source pixel.
            if (pixel_piw == pixel_piw_last && !d_opaque &&
                (d_bpp8 ? (pen8 == 8'hff) : (pen4 == 4'hf))) begin
                fb_wr_end <= 1'b1;
                dy <= dy + 1'd1;
                yacc <= yacc + ystep;
                rs <= R_ROW;
            end
            else begin
                if (pixel_piw == pixel_piw_last)
                    end_scan_word <= pixel_wordi + 1'd1;
                dx <= dx + 1'd1;
                xacc <= xacc + xstep;

                // Fast path covers every xstep <= 1.0 (1:1 and magnified):
                // the source index advances 0 or 1 pixel per destination
                // pixel, so the following byte can be preselected while this
                // pixel is emitted, sustaining one output per clock.  The
                // incremental piw/wordi/byteoff updates below reproduce
                // exactly what R_PIXEL would rederive from xacc_next.
                // Cache boundaries, trailing clipping, minification, and END
                // codes retain the fully general R_PIXEL fallback.
                next_dx = dx + 1'd1;
                xacc_next = xacc + xstep;
                src_adv = xacc_next[24:16] != xacc[24:16];
                next_sx_px = {1'b0, xacc_next[24:16]};
                next_scrx = d_flipx ? (pixel_scrx - 14'sd1)
                                        : (pixel_scrx + 14'sd1);
                next_piw = !src_adv ? pixel_piw
                         : (pixel_piw == pixel_piw_last)
                         ? 3'd0 : (pixel_piw + 1'd1);
                next_wordi = (src_adv && pixel_piw == pixel_piw_last)
                           ? (pixel_wordi + 1'd1) : pixel_wordi;
                if (!src_adv) begin
                    next_byteoff = pixel_byteoff;
                    same_cache = 1'b1;
                end
                else if (d_bpp8) begin
                    next_byteoff = pixel_byteoff + 1'd1;
                    same_cache = pixel_byteoff != 4'hf;
                end
                else if (!pixel_sx_px[0]) begin
                    // The second 4bpp pixel shares the current source byte.
                    next_byteoff = pixel_byteoff;
                    same_cache = 1'b1;
                end
                else begin
                    next_byteoff = pixel_byteoff + 1'd1;
                    same_cache = pixel_byteoff != 4'hf;
                end
                clip_x_min = (clip_en && $signed(clip_l) > 0)
                           ? $signed(clip_l) : 16'sd0;
                clip_x_max = (clip_en && $signed(clip_r) <
                               $signed({7'b0, hpix}) - 1)
                           ? $signed(clip_r)
                           : $signed({7'b0, hpix}) - 1;
                fast_continue = FAST_1X && (xstep <= 25'h1_0000) &&
                                (next_dx < d_dstw) && rowtag_v &&
                                same_cache &&
                                ((!d_flipx && next_scrx <= clip_x_max) ||
                                 ( d_flipx && next_scrx >= clip_x_min));
                if (fast_continue) begin
                    pixel_scrx     <= next_scrx;
                    pixel_sx_px    <= next_sx_px;
                    pixel_piw      <= next_piw;
                    pixel_wordi    <= next_wordi;
                    pixel_byteoff  <= next_byteoff;
                    pixel_pen8     <= pixrow[
                        {next_byteoff, 3'b000} +: 8];
                    rs <= R_EMIT;
                end
                else begin
                    rs <= R_PIXEL;
                end
            end
        end

        R_DONE: begin
            // The final run can still be draining through s32_fb_if after the
            // list END has been decoded.  Do not transfer buffer ownership
            // until that write is committed; otherwise the nominally ready
            // frame can still change underneath a following publication.
            if (!fb_busy) begin
                // A later completed frame may supersede an older unpresented
                // one, but an incomplete frame can never be scanned or written
                // in place.
                if (publish_on_done) begin
                    ready_buf <= is_multi32 ? {1'b0, work_buf[0]} : work_buf;
                    ready_valid <= 1'b1;
                end
                publish_on_done <= 1'b0;
                rs <= R_IDLE;
            end
        end
        default: rs <= R_IDLE;
        endcase
    end
end


endmodule


//============================================================================
// Shared unsigned sprite-scale divider.
//
// Computes ynum/yden followed by xnum/xden with one 25-bit restoring-divider
// datapath.  Each quotient takes 25 clocks and truncates toward zero, matching
// the unsigned SystemVerilog '/' previously used by s32_sprite.  Callers must
// supply non-zero divisors (zero-sized sprites are rejected before start).
//============================================================================
module s32_sprite_scale_div (
    input             clk,
    input             rst,
    input             start,
    input      [24:0] ynum,
    input       [9:0] yden,
    input      [24:0] xnum,
    input       [9:0] xden,
    output reg        busy,
    output reg        done,
    output reg [24:0] yquot,
    output reg [24:0] xquot
);

reg [24:0] shift_r;
reg [10:0] rem_r;
reg  [9:0] den_r;
reg [24:0] xnum_r;
reg  [9:0] xden_r;
reg  [4:0] bit_count;
reg        axis_x;

wire [10:0] trial_raw = {rem_r[9:0], shift_r[24]};
wire        trial_ge  = trial_raw >= {1'b0, den_r};
wire [10:0] trial_next = trial_ge ? trial_raw - {1'b0, den_r}
                                         : trial_raw;
wire [24:0] shift_next = {shift_r[23:0], trial_ge};

always @(posedge clk) begin
    if (rst) begin
        shift_r <= 0;
        rem_r <= 0;
        den_r <= 0;
        xnum_r <= 0;
        xden_r <= 0;
        bit_count <= 0;
        axis_x <= 0;
        busy <= 0;
        done <= 0;
        yquot <= 0;
        xquot <= 0;
    end
    else begin
        done <= 1'b0;
        if (start && !busy) begin
            shift_r <= ynum;
            rem_r <= 0;
            den_r <= yden;
            xnum_r <= xnum;
            xden_r <= xden;
            bit_count <= 0;
            axis_x <= 1'b0;
            busy <= 1'b1;
        end
        else if (busy) begin
            shift_r <= shift_next;
            rem_r <= trial_next;
            if (bit_count == 5'd24) begin
                if (!axis_x) begin
                    yquot <= shift_next;
                    shift_r <= xnum_r;
                    rem_r <= 0;
                    den_r <= xden_r;
                    bit_count <= 0;
                    axis_x <= 1'b1;
                end
                else begin
                    xquot <= shift_next;
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end
            else bit_count <= bit_count + 1'd1;
        end
    end
end

endmodule
