// K055550 protection / memory-operation device used by Violent Storm.
//
// The command register map and the supported operations are deliberately
// limited to behavior documented by the pinned MAME source.  The device is
// a sequential bus master: a command write holds DTACK until each requested
// memory transfer has been acknowledged by the surrounding arbiter.
module jtviostorm_k055550 #(
    parameter int ADDR_W = 24
) (
    input  logic              clk,
    input  logic              rst,
    input  logic              cen,
    input  logic              cs,
    input  logic              rnw,
    input  logic [5:1]        addr,
    input  logic [15:0]       din,
    input  logic [1:0]        dsn,
    output logic [15:0]       dout,
    output logic              dtack,
    output logic              busy,
    output logic              bus_req,
    output logic [ADDR_W-1:0] bus_addr,
    output logic              bus_rnw,
    output logic [15:0]       bus_dout,
    output logic [1:0]        bus_dsn,
    input  logic              bus_ack,
    input  logic [15:0]       bus_din
);

    // MAME exposes 32 word locations even though the documented command
    // fields use 0..15 and the vector result is returned at word 0x10.
    logic [15:0] regs [0:31];

    localparam logic [5:0] ST_IDLE       = 6'd0;
    localparam logic [5:0] ST_FILL       = 6'd1;
    localparam logic [5:0] ST_COPY_R0    = 6'd2;
    localparam logic [5:0] ST_COPY_R1    = 6'd3;
    localparam logic [5:0] ST_COPY_W0    = 6'd4;
    localparam logic [5:0] ST_COPY_W1    = 6'd5;
    localparam logic [5:0] ST_A0_SRC_READ= 6'd6;
    localparam logic [5:0] ST_A0_CLEAR   = 6'd7;
    localparam logic [5:0] ST_A0_TGT_READ= 6'd8;
    localparam logic [5:0] ST_A0_HIT_WRITE=6'd9;

    logic [5:0] state;
    logic [31:0] op_addr;
    logic [31:0] src_addr;
    logic [31:0] dst_addr;
    logic [31:0] remaining;
    logic [15:0] copy_word0;
    logic [15:0] copy_word1;
    logic [7:0]  a0_count;
    logic [7:0]  a0_src_idx;
    logic [7:0]  a0_tgt_idx;
    logic [3:0]  a0_word_idx;
    logic [31:0] a0_bsize;
    logic [31:0] a0_src_addr;
    logic [31:0] a0_tgt_addr;
    logic [31:0] a0_clear_addr;
    logic [31:0] a0_clear_end;
    logic [31:0] a0_hit_addr;
    // JTFRAME's writable SDRAM requester edge-qualifies CS.  Release the
    // request for one CEN after every completion so the next address creates
    // a fresh slot transaction instead of reusing the previous data_ok.
    logic        bus_gap;
    logic signed [15:0] a0_c1, a0_sx1, a0_wx1;
    logic signed [15:0] a0_cy1, a0_sy1, a0_wy1;
    logic signed [15:0] a0_cz1, a0_sz1, a0_wz1;
    logic signed [15:0] a0_c2, a0_sx2, a0_wx2;
    logic signed [15:0] a0_cy2, a0_sy2, a0_wy2;
    logic signed [15:0] a0_cz2, a0_sz2;
    integer idx;

    wire [7:0] command_byte = din[15:8];
    wire [7:0] command_count = !dsn[0] ? din[7:0] : regs[0][7:0];
    wire [31:0] fill_size = {regs[10],regs[11]};
    wire [31:0] source_addr = {regs[2],regs[3]};
    wire [31:0] target_addr = {regs[7],regs[8]};
    wire [31:0] copy_size = {regs[10],regs[11]};
    wire [31:0] a0_entry_size = {regs[5],regs[6]};
    wire [31:0] a0_skip_bytes = ({16'd0,regs[1]} >> 7);
    // Widen before shifting: a0_word_idx=8 must address the ninth word at
    // byte offset 16 rather than wrapping in a four-bit expression.
    wire [ADDR_W-1:0] a0_word_offset = ADDR_W'(a0_word_idx) << 1;

    // MAME's A0 command treats each object as three signed-axis boxes. The
    // operation is a strict overlap test: equality at an edge is rejected.
    function automatic logic a0_overlap(
        input logic signed [15:0] c1,
        input logic signed [15:0] s1,
        input logic signed [15:0] w1,
        input logic signed [15:0] c2,
        input logic signed [15:0] s2,
        input logic signed [15:0] w2
    );
        integer delta;
        integer extent;
        begin
            delta = ($signed({{16{c1[15]}},c1}) +
                     $signed({{16{s1[15]}},s1})) -
                    ($signed({{16{c2[15]}},c2}) +
                     $signed({{16{s2[15]}},s2}));
            if (delta < 0) delta = -delta;
            extent = $signed({{16{w1[15]}},w1}) +
                     $signed({{16{w2[15]}},w2});
            a0_overlap = delta < extent;
        end
    endfunction

    function automatic logic a0_boxes_overlap;
        input logic signed [15:0] c1, sx1, wx1, cy1, sy1, wy1,
                                  cz1, sz1, wz1, c2, sx2, wx2,
                                  cy2, sy2, wy2, cz2, sz2, wz2;
        begin
            a0_boxes_overlap = a0_overlap(c1,sx1,wx1,c2,sx2,wx2) &&
                               a0_overlap(cy1,sy1,wy1,cy2,sy2,wy2) &&
                               a0_overlap(cz1,sz1,wz1,cz2,sz2,wz2);
        end
    endfunction

    // Tangent thresholds for k*pi/128, scaled by 2^14 and rounded upward.
    // They let the C0 path reproduce MAME's integer truncation without
    // real-number synthesis. The largest product is 32768*16384, which fits
    // the signed 32-bit integer temporaries used by the function.
    function automatic integer tangent_threshold(input integer k);
        begin
            case (k)
                1:  tangent_threshold = 403;
                2:  tangent_threshold = 805;
                3:  tangent_threshold = 1209;
                4:  tangent_threshold = 1614;
                5:  tangent_threshold = 2021;
                6:  tangent_threshold = 2431;
                7:  tangent_threshold = 2843;
                8:  tangent_threshold = 3259;
                9:  tangent_threshold = 3680;
                10: tangent_threshold = 4104;
                11: tangent_threshold = 4535;
                12: tangent_threshold = 4971;
                13: tangent_threshold = 5413;
                14: tangent_threshold = 5863;
                15: tangent_threshold = 6321;
                16: tangent_threshold = 6787;
                17: tangent_threshold = 7263;
                18: tangent_threshold = 7750;
                19: tangent_threshold = 8248;
                20: tangent_threshold = 8758;
                21: tangent_threshold = 9282;
                22: tangent_threshold = 9821;
                23: tangent_threshold = 10376;
                24: tangent_threshold = 10948;
                25: tangent_threshold = 11539;
                26: tangent_threshold = 12152;
                27: tangent_threshold = 12787;
                28: tangent_threshold = 13447;
                29: tangent_threshold = 14133;
                30: tangent_threshold = 14850;
                31: tangent_threshold = 15599;
                32: tangent_threshold = 16384;
                default: tangent_threshold = 0;
            endcase
        end
    endfunction

    // Integer octant/ratio implementation of atan(dy/dx), in the same
    // 256-step angular convention used by the MAME HLE. The threshold scan
    // is deliberately bounded to 32 entries because the first octant is
    // only 0..45 degrees. Cardinal directions remain exact; (0,0) is kept
    // deterministic until stronger hardware evidence defines its indeterminate
    // result.
    function automatic [7:0] homing_angle(
        input logic signed [15:0] dx,
        input logic signed [15:0] dy
    );
        integer ax, ay, oct, theta, k;
        begin
            ax = $signed({{16{dx[15]}},dx});
            ay = $signed({{16{dy[15]}},dy});
            if (ax < 0) ax = -ax;
            if (ay < 0) ay = -ay;
            if (dx == 0)
                homing_angle = (dy > 0) ? 8'h00 :
                               (dy < 0) ? 8'h80 : 8'h00;
            else if (dy == 0)
                homing_angle = (dx > 0) ? 8'hc0 : 8'h40;
            else begin
                if (ay <= ax) begin
                    theta = 0;
                    for (k = 1; k <= 32; k = k + 1)
                        if ((ay * 16384) >=
                            (ax * tangent_threshold(k)))
                            theta = k;
                end else begin
                    // atan(r) is subtracted from 90 degrees in this branch.
                    // Truncation of (64 - atan(r)) therefore uses the first
                    // upward threshold, i.e. a ceil rather than a floor.
                    theta = 64;
                    for (k = 1; k <= 32; k = k + 1)
                        if ((theta == 64) &&
                            ((ax * 16384) <=
                             (ay * tangent_threshold(k))))
                            theta = 64 - k;
                end
                if (dx > 0 && dy > 0)
                    oct = theta - 64;
                else if (dx > 0 && dy < 0)
                    oct = 192 - theta;
                else if (dx < 0 && dy > 0)
                    oct = 64 - theta;
                else
                    oct = 64 + theta;
                homing_angle = oct[7:0];
            end
        end
    endfunction

    always_comb begin
        bus_req  = 1'b0;
        bus_addr = op_addr[ADDR_W-1:0];
        bus_rnw  = 1'b0;
        bus_dout = 16'h0000;
        bus_dsn  = 2'b00;       // word transfers; both lanes active
        case (state)
            ST_FILL: begin
                bus_req  = !bus_gap;
                bus_addr = op_addr[ADDR_W-1:0];
                bus_dout = regs[13];
            end
            ST_COPY_R0: begin
                bus_req  = !bus_gap;
                bus_rnw  = 1'b1;
                bus_addr = src_addr[ADDR_W-1:0];
            end
            ST_COPY_R1: begin
                bus_req  = !bus_gap;
                bus_rnw  = 1'b1;
                bus_addr = src_addr[ADDR_W-1:0] + ADDR_W'(2);
            end
            ST_COPY_W0: begin
                bus_req  = !bus_gap;
                bus_addr = dst_addr[ADDR_W-1:0];
                bus_dout = copy_word0;
            end
            ST_COPY_W1: begin
                bus_req  = !bus_gap;
                bus_addr = dst_addr[ADDR_W-1:0] + ADDR_W'(2);
                bus_dout = copy_word1;
            end
            ST_A0_SRC_READ: begin
                bus_req  = !bus_gap;
                bus_rnw  = 1'b1;
                bus_addr = a0_src_addr[ADDR_W-1:0] + a0_word_offset;
            end
            ST_A0_TGT_READ: begin
                bus_req  = !bus_gap;
                bus_rnw  = 1'b1;
                bus_addr = a0_tgt_addr[ADDR_W-1:0] + a0_word_offset;
            end
            ST_A0_CLEAR: begin
                bus_req = !bus_gap;
                bus_addr = a0_clear_addr[ADDR_W-1:0];
                bus_addr[0] = 1'b0;
                if (a0_clear_addr[0]) begin
                    bus_dsn  = 2'b10;
                    bus_dout = 16'h0000;
                end else begin
                    bus_dsn  = 2'b01;
                    bus_dout = 16'h0000;
                end
            end
            ST_A0_HIT_WRITE: begin
                bus_req = !bus_gap;
                bus_addr = a0_hit_addr[ADDR_W-1:0];
                bus_addr[0] = 1'b0;
                if (a0_hit_addr[0]) begin
                    bus_dsn  = 2'b10;
                    bus_dout = 16'h0080;
                end else begin
                    bus_dsn  = 2'b01;
                    bus_dout = 16'h8000;
                end
            end
            default:;
        endcase
    end

    always_comb begin
        busy = state != ST_IDLE;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            dout       <= 16'hffff;
            dtack      <= 1'b0;
            state      <= ST_IDLE;
            op_addr    <= 32'd0;
            src_addr   <= 32'd0;
            dst_addr   <= 32'd0;
            remaining  <= 32'd0;
            copy_word0 <= 16'd0;
            copy_word1 <= 16'd0;
            a0_count   <= 8'd0;
            a0_src_idx <= 8'd0;
            a0_tgt_idx <= 8'd0;
            a0_word_idx<= 4'd0;
            a0_bsize   <= 32'd0;
            a0_src_addr<= 32'd0;
            a0_tgt_addr<= 32'd0;
            a0_clear_addr <= 32'd0;
            a0_clear_end  <= 32'd0;
            a0_hit_addr   <= 32'd0;
            bus_gap       <= 1'b0;
            a0_c1  <= '0; a0_sx1 <= '0; a0_wx1 <= '0;
            a0_cy1 <= '0; a0_sy1 <= '0; a0_wy1 <= '0;
            a0_cz1 <= '0; a0_sz1 <= '0; a0_wz1 <= '0;
            a0_c2  <= '0; a0_sx2 <= '0; a0_wx2 <= '0;
            a0_cy2 <= '0; a0_sy2 <= '0; a0_wy2 <= '0;
            a0_cz2 <= '0; a0_sz2 <= '0;
            for (idx = 0; idx < 32; idx = idx + 1)
                regs[idx] <= 16'd0;
        end else begin
            dtack <= 1'b0;

            // CPU register access is accepted only while the command engine
            // is idle. This prevents a held 68000 cycle from retriggering a
            // command while the bus master owns the memory interface.
            if (cen && cs && state == ST_IDLE) begin
                if (rnw) begin
                    dout  <= regs[addr];
                    dtack <= 1'b1;
                end else begin
                    if (!dsn[1]) regs[addr][15:8] <= din[15:8];
                    if (!dsn[0]) regs[addr][7:0]  <= din[7:0];

                    if (addr == 5'd0 && !dsn[1]) begin
                        // Count is the low byte of register zero; a full-word
                        // command write may update it in the same cycle.
                        op_addr  <= target_addr;
                        src_addr <= source_addr;
                        dst_addr <= target_addr;
                        case (command_byte)
                            8'h97, 8'h9f: begin
                                // MAME loops `for(i=adr;i<lim;i+=2)` where
                                // lim=adr+bsize*count: the iteration count is
                                // ceil((bsize*count)/2), not a floor divide,
                                // so an odd bsize*count performs one more
                                // word write (konamigx_m.cpp K055550_word_w,
                                // case 0x97/0x9f).
                                remaining <= ((fill_size *
                                    ({24'd0,command_count} + 32'd1)) + 32'd1) >> 1;
                                state <= (((fill_size *
                                    ({24'd0,command_count} + 32'd1)) + 32'd1) >> 1) == 0
                                    ? ST_IDLE : ST_FILL;
                                if ((((fill_size *
                                    ({24'd0,command_count} + 32'd1)) + 32'd1) >> 1) == 0)
                                    dtack <= 1'b1;
                            end
                            8'h98: begin
                                remaining <= copy_size >> 2;
                                state <= (copy_size >> 2) == 0
                                    ? ST_IDLE : ST_COPY_R0;
                                if ((copy_size >> 2) == 0)
                                    dtack <= 1'b1;
                            end
                            8'hc0: begin
                                // MAME uses words 0xc and 0xd as signed dx/dy
                                // and places the result in word 0x10.
                                regs[16] <= {8'h00,
                                    homing_angle($signed(regs[12]),
                                                 $signed(regs[13]))};
                                dtack <= 1'b1;
                            end
                            8'ha0: begin
                                // MAME's collision operation treats register
                                // zero as (object_count - 1). The final
                                // object is the target-only entry, so a
                                // count of N scans N source entries against
                                // later entries and clears each source hit
                                // list before testing it.
                                a0_count    <= command_count;
                                a0_src_idx  <= 8'd0;
                                a0_tgt_idx  <= 8'd1;
                                a0_word_idx <= 4'd0;
                                a0_bsize    <= a0_entry_size;
                                a0_src_addr <= {regs[2],regs[3]};
                                a0_tgt_addr <= {regs[2],regs[3]} + a0_entry_size;
                                a0_clear_addr <= {regs[2],regs[3]} + a0_skip_bytes;
                                a0_clear_end  <= {regs[2],regs[3]} + a0_entry_size;
                                a0_hit_addr   <= {regs[2],regs[3]} + a0_skip_bytes;
                                if ((command_count == 8'd0) ||
                                    (a0_entry_size == 32'd0)) begin
                                    state <= ST_IDLE;
                                    dtack <= 1'b1;
                                end else begin
                                    state <= ST_A0_SRC_READ;
                                end
                            end
                            8'h87: begin
                                // MAME labels this operation speculative. No
                                // externally visible operation is asserted.
                                dtack <= 1'b1;
                            end
                            default: dtack <= 1'b1;
                        endcase
                    end else begin
                        dtack <= 1'b1;
                    end
                end
            end

            if (cen) begin
                // bus_ack is a completion pulse at the JTFRAME slot
                // boundary.  A request gap prevents a stale held-high
                // data_ok from being consumed as a second completion.
                if (bus_gap)
                    bus_gap <= 1'b0;
                else if (state != ST_IDLE && bus_ack)
                    bus_gap <= 1'b1;
                case (state)
                    ST_FILL: if (bus_ack && !bus_gap) begin
                        if (remaining <= 32'd1) begin
                            remaining <= 32'd0;
                            state <= ST_IDLE;
                            dtack <= 1'b1;
                        end else begin
                            remaining <= remaining - 32'd1;
                            op_addr <= op_addr + 32'd2;
                        end
                    end
                    ST_COPY_R0: if (bus_ack && !bus_gap) begin
                        copy_word0 <= bus_din;
                        state <= ST_COPY_R1;
                    end
                    ST_COPY_R1: if (bus_ack && !bus_gap) begin
                        copy_word1 <= bus_din;
                        state <= ST_COPY_W0;
                    end
                    ST_COPY_W0: if (bus_ack && !bus_gap) begin
                        state <= ST_COPY_W1;
                    end
                    ST_COPY_W1: if (bus_ack && !bus_gap) begin
                        if (remaining <= 32'd1) begin
                            remaining <= 32'd0;
                            state <= ST_IDLE;
                            dtack <= 1'b1;
                        end else begin
                            remaining <= remaining - 32'd1;
                            src_addr <= src_addr + 32'd8;
                            dst_addr <= dst_addr + 32'd4;
                            state <= ST_COPY_R0;
                        end
                    end
                    ST_A0_SRC_READ: if (bus_ack && !bus_gap) begin
                        case (a0_word_idx)
                            4'd0: a0_c1  <= $signed(bus_din);
                            4'd1: a0_sx1 <= $signed(bus_din);
                            4'd2: a0_wx1 <= $signed(bus_din);
                            4'd3: a0_cy1 <= $signed(bus_din);
                            4'd4: a0_sy1 <= $signed(bus_din);
                            4'd5: a0_wy1 <= $signed(bus_din);
                            4'd6: a0_cz1 <= $signed(bus_din);
                            4'd7: a0_sz1 <= $signed(bus_din);
                            default: a0_wz1 <= $signed(bus_din);
                        endcase
                        if (a0_word_idx == 4'd8) begin
                            a0_clear_addr <= a0_src_addr + a0_skip_bytes;
                            a0_clear_end  <= a0_src_addr + a0_bsize;
                            a0_hit_addr   <= a0_src_addr + a0_skip_bytes;
                            // MAME's `for(count=src+skip; count<tgt;
                            // count++)` (konamigx_m.cpp K055550_word_w,
                            // case 0xa0) performs zero byte writes when
                            // skip>=bsize. Skip ST_A0_CLEAR entirely in that
                            // case instead of issuing one stray write before
                            // the bound check.
                            if (a0_skip_bytes >= a0_bsize) begin
                                a0_tgt_idx  <= a0_src_idx + 1'b1;
                                a0_tgt_addr <= a0_src_addr + a0_bsize;
                                a0_word_idx <= 4'd0;
                                state <= ST_A0_TGT_READ;
                            end else begin
                                state <= ST_A0_CLEAR;
                            end
                        end else begin
                            a0_word_idx <= a0_word_idx + 1'b1;
                        end
                    end
                    ST_A0_CLEAR: if (bus_ack && !bus_gap) begin
                        if ((a0_clear_addr + 32'd1) >= a0_clear_end) begin
                            a0_tgt_idx  <= a0_src_idx + 1'b1;
                            a0_tgt_addr <= a0_src_addr + a0_bsize;
                            a0_word_idx <= 4'd0;
                            state <= ST_A0_TGT_READ;
                        end else begin
                            a0_clear_addr <= a0_clear_addr + 32'd1;
                        end
                    end
                    ST_A0_TGT_READ: if (bus_ack && !bus_gap) begin
                        case (a0_word_idx)
                            4'd0: a0_c2  <= $signed(bus_din);
                            4'd1: a0_sx2 <= $signed(bus_din);
                            4'd2: a0_wx2 <= $signed(bus_din);
                            4'd3: a0_cy2 <= $signed(bus_din);
                            4'd4: a0_sy2 <= $signed(bus_din);
                            4'd5: a0_wy2 <= $signed(bus_din);
                            4'd6: a0_cz2 <= $signed(bus_din);
                            4'd7: a0_sz2 <= $signed(bus_din);
                            default:;
                        endcase
                        if (a0_word_idx == 4'd8) begin
                            if (a0_boxes_overlap(
                                    a0_c1,a0_sx1,a0_wx1,
                                    a0_cy1,a0_sy1,a0_wy1,
                                    a0_cz1,a0_sz1,a0_wz1,
                                    a0_c2,a0_sx2,a0_wx2,
                                    a0_cy2,a0_sy2,a0_wy2,
                                    a0_cz2,a0_sz2,$signed(bus_din)))
                                state <= ST_A0_HIT_WRITE;
                            else if (a0_tgt_idx < a0_count) begin
                                a0_tgt_idx  <= a0_tgt_idx + 1'b1;
                                a0_tgt_addr <= a0_tgt_addr + a0_bsize;
                                a0_hit_addr <= a0_hit_addr + 32'd1;
                                a0_word_idx <= 4'd0;
                            end else if ((a0_src_idx + 1'b1) < a0_count) begin
                                a0_src_idx  <= a0_src_idx + 1'b1;
                                a0_tgt_idx  <= a0_src_idx + 8'd2;
                                a0_src_addr <= a0_src_addr + a0_bsize;
                                a0_tgt_addr <= a0_src_addr + (a0_bsize << 1);
                                a0_hit_addr <= a0_src_addr + a0_bsize + a0_skip_bytes;
                                a0_word_idx <= 4'd0;
                                state <= ST_A0_SRC_READ;
                            end else begin
                                state <= ST_IDLE;
                                dtack <= 1'b1;
                            end
                        end else begin
                            a0_word_idx <= a0_word_idx + 1'b1;
                        end
                    end
                    ST_A0_HIT_WRITE: if (bus_ack && !bus_gap) begin
                        if (a0_tgt_idx < a0_count) begin
                            a0_tgt_idx  <= a0_tgt_idx + 1'b1;
                            a0_tgt_addr <= a0_tgt_addr + a0_bsize;
                            a0_hit_addr <= a0_hit_addr + 32'd1;
                            a0_word_idx <= 4'd0;
                            state <= ST_A0_TGT_READ;
                        end else if ((a0_src_idx + 1'b1) < a0_count) begin
                            a0_src_idx  <= a0_src_idx + 1'b1;
                            a0_tgt_idx  <= a0_src_idx + 8'd2;
                            a0_src_addr <= a0_src_addr + a0_bsize;
                            a0_tgt_addr <= a0_src_addr + (a0_bsize << 1);
                            a0_hit_addr <= a0_src_addr + a0_bsize + a0_skip_bytes;
                            a0_word_idx <= 4'd0;
                            state <= ST_A0_SRC_READ;
                        end else begin
                            state <= ST_IDLE;
                            dtack <= 1'b1;
                        end
                    end
                    default:;
                endcase
            end
        end
    end
endmodule
