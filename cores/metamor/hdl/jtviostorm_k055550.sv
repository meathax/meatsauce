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
    localparam logic [5:0] ST_HOME       = 6'd10;

    logic [5:0] state;
    // A 68000 cycle stays asserted for a few clocks after DTACK.  Accept each
    // CPU cycle once, otherwise a completed fill/copy command is re-executed
    // in the background and races the CPU for the work RAM port.
    logic       cyc_done;
    // C0 homing angle: the tangent scan visits one table entry at a time so
    // a single 17x20 multiplier is shared (32 parallel constant multipliers
    // per branch did not fit the device). Thresholds carry 40 fraction bits,
    // the least that keeps every signed 16-bit vector on MAME's side of each
    // boundary, so each entry takes four steps: low half, high half, sum,
    // compare.
    logic [16:0] h_ax, h_ay;
    logic [ 5:0] h_k;
    logic [ 7:0] h_theta;
    logic        h_second, h_xpos, h_ypos;
    logic [ 1:0] h_ph;
    logic [36:0] h_prod;
    logic [56:0] h_acc;
    wire  [39:0] h_thr  = tangent_threshold(h_k);
    wire  [16:0] h_mul  = h_second ? h_ay : h_ax;
    wire  [56:0] h_lhs  = {(h_second ? h_ax : h_ay), 40'd0};
    // tan(pi/4) is exactly one: no product is needed for the last entry.
    wire         h_hit  = h_k == 6'd32 ? (h_second || h_ax == h_ay) :
                          h_second     ? (h_lhs <  h_acc) : (h_lhs >= h_acc);
    wire         h_take = h_hit && (!h_second || h_theta == 8'd64);
    wire  [ 7:0] h_next = !h_take ? h_theta :
                          h_second ? (8'd64 - {2'd0,h_k}) : {2'd0,h_k};
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
    // Release the request for one clock after every completion so the next
    // address creates a fresh transaction (the arbiter gates every ack with
    // bus_req).  The request and ack registers make the dropped request take
    // two clocks to clear bus_ack_q, so the ack is also ignored on the clock
    // after the gap; otherwise the previous completion is consumed twice.
    logic        bus_gap;
    logic        bus_stale;
    wire         bus_ok = bus_ack_q && !bus_gap && !bus_stale;
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

    // Tangent thresholds for k*pi/128 (k=1..31), scaled by 2^40 and rounded
    // upward. No ratio of two 16-bit magnitudes lies between a tangent and
    // its rounded threshold, so the integer compare reproduces MAME's
    // truncated atan() exactly.
    function automatic [39:0] tangent_threshold(input [5:0] k);
        begin
            case (k)
                6'd1 : tangent_threshold = 40'd26991495455;
                6'd2 : tangent_threshold = 40'd54015542558;
                6'd3 : tangent_threshold = 40'd81104850176;
                6'd4 : tangent_threshold = 40'd108292443228;
                6'd5 : tangent_threshold = 40'd135611824782;
                6'd6 : tangent_threshold = 40'd163097143117;
                6'd7 : tangent_threshold = 40'd190783365533;
                6'd8 : tangent_threshold = 40'd218706460843;
                6'd9 : tangent_threshold = 40'd246903592599;
                6'd10: tangent_threshold = 40'd275413325337;
                6'd11: tangent_threshold = 40'd304275846359;
                6'd12: tangent_threshold = 40'd333533205874;
                6'd13: tangent_threshold = 40'd363229578689;
                6'd14: tangent_threshold = 40'd393411551071;
                6'd15: tangent_threshold = 40'd424128436944;
                6'd16: tangent_threshold = 40'd455432628212;
                6'd17: tangent_threshold = 40'd487379984762;
                6'd18: tangent_threshold = 40'd520030270621;
                6'd19: tangent_threshold = 40'd553447643860;
                6'd20: tangent_threshold = 40'd587701209154;
                6'd21: tangent_threshold = 40'd622865643556;
                6'd22: tangent_threshold = 40'd659021908004;
                6'd23: tangent_threshold = 40'd696258059496;
                6'd24: tangent_threshold = 40'd734670181824;
                6'd25: tangent_threshold = 40'd774363456425;
                6'd26: tangent_threshold = 40'd815453399373;
                6'd27: tangent_threshold = 40'd858067296195;
                6'd28: tangent_threshold = 40'd902345873186;
                6'd29: tangent_threshold = 40'd948445252705;
                6'd30: tangent_threshold = 40'd996539251139;
                6'd31: tangent_threshold = 40'd1046822092361;
                default: tangent_threshold = 40'd0;
            endcase
        end
    endfunction

    // Quadrant mapping of the 0..64 first-octant angle (MAME HLE convention).
    function automatic [7:0] homing_oct(input logic xpos, input logic ypos, input [7:0] theta);
        logic [7:0] o;
        begin
            if (xpos && ypos)       o = theta - 8'd64;
            else if (xpos && !ypos) o = 8'd192 - theta;
            else if (!xpos && ypos) o = 8'd64 - theta;
            else                    o = 8'd64 + theta;
            homing_oct = o;
        end
    endfunction

    // Timing: the bus request outputs and the ack/data inputs are registered
    // (one extra clock each way) to cut the clk48 <-> clk96 paths to the work
    // RAM and ROM slots.  The command engine steps on every clock; cen only
    // qualifies the CPU register cycle.
    logic              bus_req_c;
    logic [ADDR_W-1:0] bus_addr_c;
    logic              bus_rnw_c;
    logic [15:0]       bus_dout_c;
    logic [1:0]        bus_dsn_c;
    logic              bus_ack_q;
    logic [15:0]       bus_din_q;
    always_ff @(posedge clk) begin
        bus_req  <= bus_req_c;
        bus_addr <= bus_addr_c;
        bus_rnw  <= bus_rnw_c;
        bus_dout <= bus_dout_c;
        bus_dsn  <= bus_dsn_c;
        bus_ack_q <= bus_ack;
        bus_din_q <= bus_din;
    end

    always_comb begin
        bus_req_c  = 1'b0;
        bus_addr_c = op_addr[ADDR_W-1:0];
        bus_rnw_c  = 1'b0;
        bus_dout_c = 16'h0000;
        bus_dsn_c  = 2'b00;       // word transfers; both lanes active
        case (state)
            ST_FILL: begin
                bus_req_c  = !bus_gap;
                bus_addr_c = op_addr[ADDR_W-1:0];
                bus_dout_c = regs[13];
            end
            ST_COPY_R0: begin
                bus_req_c  = !bus_gap;
                bus_rnw_c  = 1'b1;
                bus_addr_c = src_addr[ADDR_W-1:0];
            end
            ST_COPY_R1: begin
                bus_req_c  = !bus_gap;
                bus_rnw_c  = 1'b1;
                bus_addr_c = src_addr[ADDR_W-1:0] + ADDR_W'(2);
            end
            ST_COPY_W0: begin
                bus_req_c  = !bus_gap;
                bus_addr_c = dst_addr[ADDR_W-1:0];
                bus_dout_c = copy_word0;
            end
            ST_COPY_W1: begin
                bus_req_c  = !bus_gap;
                bus_addr_c = dst_addr[ADDR_W-1:0] + ADDR_W'(2);
                bus_dout_c = copy_word1;
            end
            ST_A0_SRC_READ: begin
                bus_req_c  = !bus_gap;
                bus_rnw_c  = 1'b1;
                bus_addr_c = a0_src_addr[ADDR_W-1:0] + a0_word_offset;
            end
            ST_A0_TGT_READ: begin
                bus_req_c  = !bus_gap;
                bus_rnw_c  = 1'b1;
                bus_addr_c = a0_tgt_addr[ADDR_W-1:0] + a0_word_offset;
            end
            ST_A0_CLEAR: begin
                bus_req_c = !bus_gap;
                bus_addr_c = a0_clear_addr[ADDR_W-1:0];
                bus_addr_c[0] = 1'b0;
                if (a0_clear_addr[0]) begin
                    bus_dsn_c  = 2'b10;
                    bus_dout_c = 16'h0000;
                end else begin
                    bus_dsn_c  = 2'b01;
                    bus_dout_c = 16'h0000;
                end
            end
            ST_A0_HIT_WRITE: begin
                bus_req_c = !bus_gap;
                bus_addr_c = a0_hit_addr[ADDR_W-1:0];
                bus_addr_c[0] = 1'b0;
                if (a0_hit_addr[0]) begin
                    bus_dsn_c  = 2'b10;
                    bus_dout_c = 16'h0080;
                end else begin
                    bus_dsn_c  = 2'b01;
                    bus_dout_c = 16'h8000;
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
            cyc_done   <= 1'b0;
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
            bus_stale     <= 1'b0;
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
            if (!cs) cyc_done <= 1'b0;
            if (cen && cs && !cyc_done && state == ST_IDLE) begin
                cyc_done <= 1'b1;
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
                                if ($signed(regs[12]) == 0) begin
                                    regs[16] <= {8'h00, ($signed(regs[13]) < 0) ? 8'h80 : 8'h00};
                                    dtack <= 1'b1;
                                end else if ($signed(regs[13]) == 0) begin
                                    regs[16] <= {8'h00, ($signed(regs[12]) > 0) ? 8'hc0 : 8'h40};
                                    dtack <= 1'b1;
                                end else begin
                                    h_ax     <= regs[12][15] ? 17'd0 - {1'b1,regs[12]} + 17'd0 : {1'b0,regs[12]};
                                    h_ay     <= regs[13][15] ? 17'd0 - {1'b1,regs[13]} + 17'd0 : {1'b0,regs[13]};
                                    h_second <= (regs[13][15] ? 17'd0 - {1'b1,regs[13]} : {1'b0,regs[13]}) >
                                                (regs[12][15] ? 17'd0 - {1'b1,regs[12]} : {1'b0,regs[12]});
                                    h_theta  <= ((regs[13][15] ? 17'd0 - {1'b1,regs[13]} : {1'b0,regs[13]}) >
                                                 (regs[12][15] ? 17'd0 - {1'b1,regs[12]} : {1'b0,regs[12]})) ? 8'd64 : 8'd0;
                                    h_k      <= 6'd1;
                                    h_ph     <= 2'd0;
                                    h_xpos   <= !regs[12][15];
                                    h_ypos   <= !regs[13][15];
                                    state    <= ST_HOME;
                                end
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

            begin
                // bus_ack_q stays high while the request is held.  The gap
                // and the stale-ack clock after it prevent a held-high ack
                // from being consumed as a second completion.
                bus_gap   <= state != ST_IDLE && bus_ok;
                bus_stale <= bus_gap;
                case (state)
                    ST_FILL: if (bus_ok) begin
                        if (remaining <= 32'd1) begin
                            remaining <= 32'd0;
                            state <= ST_IDLE;
                            dtack <= 1'b1;
                        end else begin
                            remaining <= remaining - 32'd1;
                            op_addr <= op_addr + 32'd2;
                        end
                    end
                    ST_COPY_R0: if (bus_ok) begin
                        copy_word0 <= bus_din_q;
                        state <= ST_COPY_R1;
                    end
                    ST_COPY_R1: if (bus_ok) begin
                        copy_word1 <= bus_din_q;
                        state <= ST_COPY_W0;
                    end
                    ST_COPY_W0: if (bus_ok) begin
                        state <= ST_COPY_W1;
                    end
                    ST_COPY_W1: if (bus_ok) begin
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
                    ST_A0_SRC_READ: if (bus_ok) begin
                        case (a0_word_idx)
                            4'd0: a0_c1  <= $signed(bus_din_q);
                            4'd1: a0_sx1 <= $signed(bus_din_q);
                            4'd2: a0_wx1 <= $signed(bus_din_q);
                            4'd3: a0_cy1 <= $signed(bus_din_q);
                            4'd4: a0_sy1 <= $signed(bus_din_q);
                            4'd5: a0_wy1 <= $signed(bus_din_q);
                            4'd6: a0_cz1 <= $signed(bus_din_q);
                            4'd7: a0_sz1 <= $signed(bus_din_q);
                            default: a0_wz1 <= $signed(bus_din_q);
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
                    ST_A0_CLEAR: if (bus_ok) begin
                        if ((a0_clear_addr + 32'd1) >= a0_clear_end) begin
                            a0_tgt_idx  <= a0_src_idx + 1'b1;
                            a0_tgt_addr <= a0_src_addr + a0_bsize;
                            a0_word_idx <= 4'd0;
                            state <= ST_A0_TGT_READ;
                        end else begin
                            a0_clear_addr <= a0_clear_addr + 32'd1;
                        end
                    end
                    ST_A0_TGT_READ: if (bus_ok) begin
                        case (a0_word_idx)
                            4'd0: a0_c2  <= $signed(bus_din_q);
                            4'd1: a0_sx2 <= $signed(bus_din_q);
                            4'd2: a0_wx2 <= $signed(bus_din_q);
                            4'd3: a0_cy2 <= $signed(bus_din_q);
                            4'd4: a0_sy2 <= $signed(bus_din_q);
                            4'd5: a0_wy2 <= $signed(bus_din_q);
                            4'd6: a0_cz2 <= $signed(bus_din_q);
                            4'd7: a0_sz2 <= $signed(bus_din_q);
                            default:;
                        endcase
                        if (a0_word_idx == 4'd8) begin
                            if (a0_boxes_overlap(
                                    a0_c1,a0_sx1,a0_wx1,
                                    a0_cy1,a0_sy1,a0_wy1,
                                    a0_cz1,a0_sz1,a0_wz1,
                                    a0_c2,a0_sx2,a0_wx2,
                                    a0_cy2,a0_sy2,a0_wy2,
                                    a0_cz2,a0_sz2,$signed(bus_din_q)))
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
                    ST_A0_HIT_WRITE: if (bus_ok) begin
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
                    ST_HOME: begin
                        h_ph   <= h_ph + 2'd1;
                        h_prod <= h_mul * (h_ph[0] ? h_thr[39:20] : h_thr[19:0]);
                        case (h_ph)
                            2'd1: h_acc <= {20'd0, h_prod};
                            2'd2: h_acc <= h_acc + {h_prod, 20'd0};
                            2'd3: begin
                                h_theta <= h_next;
                                h_k     <= h_k + 6'd1;
                                if (h_k == 6'd32) begin
                                    state <= ST_IDLE;
                                    dtack <= 1'b1;
                                    regs[16] <= {8'h00, homing_oct(h_xpos, h_ypos, h_next)};
                                end
                            end
                            default:;
                        endcase
                    end
                    default:;
                endcase
            end
        end
    end
endmodule
