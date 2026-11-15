// SPDX-License-Identifier: GPL-3.0-or-later
// Gaiapolis K053936 ROM-map renderer. Coordinate rules are derived from
// Jose Tejada's jt053936 (jtcores/rungun) and MAME 0.289 k053936.cpp.
// Four tagged scanline buffers decouple fixed pixel timing from ROM latency.
module gaiapolis_roz #(
    parameter integer HSTART = 40,
    parameter integer HEND = 416,
    parameter integer VSTART = 16,
    parameter integer VEND = 240,
    parameter integer XOFFSET = -10,
    parameter integer YOFFSET = 0
)(
    input wire monster,
    output wire [7:0] pen8,
    input  logic        clk, rst, pxl_cen,
    input  logic [8:0]  hpos, vpos,
    input  logic        active_video,
    input  logic        enabled, clip_enabled,
    input  logic [15:0] clip_rect,
    output logic [3:0]  ctrl_addr,
    input  logic [15:0] ctrl_data,
    output logic [10:0] line_addr,
    input  logic [15:0] line_data,
    output logic [19:0] map_addr,
    output logic        map_cs,
    input  logic [7:0]  map_data,
    input  logic        map_ok,
    output logic [20:0] char_addr,
    output logic        char_cs,
    // Canonical byte order: char_addr+0 in [31:24], +3 in [7:0].
    // char_addr is an aligned byte address (low two bits always zero).
    input  logic [31:0] char_data,
    input  logic        char_ok,
    output logic [4:0]  palette,
    output logic [3:0]  pen,
    output logic        pixel_valid,
    output logic        underflow
);
    wire [8:0] H_FIRST = monster ? 9'd24 : 9'(HSTART);
    wire [8:0] H_LAST = monster ? 9'd311 : 9'(HEND-1);
    wire [8:0] V_FIRST = monster ? 9'd17 : 9'(VSTART);
    wire [8:0] V_LIMIT = monster ? 9'd241 : 9'(VEND);

    // ROMs are immutable. Tags/data use synchronous reads; only validity resets.
    wire map_cache_ready,char_cache_ready;
    logic [12:0] display_pixel;
    assign {palette,pen8}=display_available ? display_pixel : 13'd0;
    assign pen=pen8[3:0];
    logic [3:0] line_ready;
    logic [8:0] line_tag [0:3];
    logic [3:0] line_frame;
    logic [15:0] line_epoch [0:3];

    logic [15:0] control [0:15];
    logic [15:0] control_seen;
    logic [3:0] scan_index, reply_index;
    logic reply_valid;
    logic [4:0] quiet;
    logic previous_clip_enable;
    logic [15:0] previous_clip_rect;
    logic [15:0] epoch;
    logic config_changed;
    logic frame_id;
    logic [8:0] previous_vpos;
    logic display_available;

    typedef enum logic [3:0] {
        IDLE, LINE_WAIT, LINE_CAPTURE, SETUP, COORD, MAP_LOOKUP,
        MAP_ATTR, MAP_CODE_REQUEST, MAP_CODE, MAP_PAL_REQUEST, MAP_PAL,
        CHAR_LOOKUP, CHAR_FETCH
    } state_t;
    state_t state;

    logic schedule_found, schedule_frame;
    logic [8:0] schedule_line;
    // vpos+n+1 is at most 515. Preserve signed comparisons and fall back
    // to the original width for parameter values outside the bounded range.
    localparam integer SCHEDULE_CANDIDATE_BITS =
        (VSTART>=-1024 && VSTART<=1020) ? 11 : 32;
    logic signed [SCHEDULE_CANDIDATE_BITS-1:0] candidate;
    logic [8:0] job_line, output_x;
    logic job_frame, job_abort;
    logic [15:0] job_epoch, job_clip_rect;
    logic job_clip_enabled;
    logic [15:0] job_control [0:7];
    logic [15:0] job_line_control [0:3];
    logic [1:0] line_word;
    logic signed [31:0] source_x, source_y, step_x, step_y;
    logic signed [31:0] normal_hx, normal_hy, normal_vx, normal_vy;
    logic signed [31:0] super_hx, super_hy;
    logic [15:0] super_origin_x, super_origin_y;
    logic [12:0] wrapped_x, wrapped_y;
    logic source_clipped;
    logic [13:0] clip_min_x, clip_max_x, clip_min_y, clip_max_y;
    logic [2:0] clip_width, clip_height;

    logic [17:0] tile_index, pending_tile, map_read_tag;
    logic [10:0] map_index, pending_map_index;
    logic [18:0] map_read_value;
    logic map_read_valid;
    logic [3:0] pixel_x, pixel_y;
    logic [6:0] attribute_bits;
    logic [7:0] code_byte;
    logic [18:0] decoded_tile;
    logic [4:0] pending_palette;
    logic [20:0] wanted_char, char_from_hit, char_from_fill;
    logic [18:0] char_read_tag;
    logic [10:0] wanted_char_index;
    logic [31:0] char_read_value;
    logic [7:0] hit_byte, fetched_byte;
    logic char_read_valid;
    logic [7:0] hit_pen, fetched_pen;
    logic commit;
    logic [12:0] commit_value;

    function automatic logic signed [31:0] increment(
        input logic [15:0] value, input logic multiply
    );
        increment = multiply ? {{8{value[15]}},value,8'b0}
                             : {{16{value[15]}},value};
    endfunction
    function automatic logic signed [31:0] origin(input logic [15:0] value);
        origin = {{8{value[15]}},value,8'b0};
    endfunction
    function automatic logic [10:0] map_hash(input logic [17:0] value);
        // Fold Y into low bits: a 90-degree transform must not alias every row.
        map_hash = value[10:0] ^ value[17:7];
    endfunction
    function automatic logic [10:0] char_hash(input logic [18:0] value);
        char_hash = value[10:0] ^ value[18:8];
    endfunction
    function automatic logic [7:0] character_byte(
        input logic [31:0] value, input logic [1:0] lane
    );
        case(lane)
            2'd0: character_byte = value[31:24];
            2'd1: character_byte = value[23:16];
            2'd2: character_byte = value[15:8];
            2'd3: character_byte = value[7:0];
        endcase
    endfunction
    function automatic logic [2:0] clip_size(input logic [1:0] encoded);
        case(encoded)
            2'b11: clip_size = 3'd1;
            2'b10: clip_size = 3'd2;
            default: clip_size = 3'd4;
        endcase
    endfunction

    // Gaiapolis uses the normal/super coordinate fields below. MAME's
    // register8..11 clipping hack belongs to Golfing Greats; output/source
    // clipping for this board arrives on the separate clip inputs.
    function automatic logic [15:0] coordinate_control(
        input logic [3:0] index, input logic [15:0] value
    );
        case(index)
            4'd0,4'd1,4'd2,4'd3,4'd4,4'd5: coordinate_control = value;
            4'd6: coordinate_control = value & 16'hc0c0;
            4'd7: coordinate_control = value & 16'h0040;
            default: coordinate_control = 0;
        endcase
    endfunction

    assign ctrl_addr = scan_index;
    assign config_changed = (reply_valid &&
        coordinate_control(reply_index,ctrl_data) != coordinate_control(reply_index,control[reply_index]))
                           || clip_enabled != previous_clip_enable
                           || clip_rect != previous_clip_rect;
    assign pixel_valid = display_available && (monster ? pen8 != 0 : pen != 0);
    assign normal_hx = increment(job_control[4],job_control[6][6]);
    assign normal_hy = increment(job_control[5],job_control[6][6]);
    assign normal_vx = increment(job_control[2],job_control[6][14]);
    assign normal_vy = increment(job_control[3],job_control[6][14]);
    assign super_hx = increment(job_line_control[2],job_control[6][15]);
    assign super_hy = increment(job_line_control[3],job_control[6][7]);
    assign super_origin_x = job_line_control[0] + job_control[0];
    assign super_origin_y = job_line_control[1] + job_control[1];
    assign wrapped_x = source_x[23:11];
    assign wrapped_y = source_y[23:11];
    assign tile_index = {wrapped_y[12:4],wrapped_x[12:4]};
    assign map_index = map_hash(tile_index);
    assign clip_width = clip_size(job_clip_rect[13:12]);
    assign clip_height = clip_size(job_clip_rect[15:14]);
    assign clip_min_x = {1'b0,job_clip_rect[5:0],7'b0};
    assign clip_min_y = {1'b0,job_clip_rect[11:6],7'b0};
    assign clip_max_x = clip_min_x + {4'b0,clip_width,7'b0} - 14'd1;
    assign clip_max_y = clip_min_y + {4'b0,clip_height,7'b0} - 14'd1;
    assign source_clipped = job_clip_enabled &&
        ({1'b0,wrapped_x}<clip_min_x || {1'b0,wrapped_x}>clip_max_x ||
         {1'b0,wrapped_y}<clip_min_y || {1'b0,wrapped_y}>clip_max_y);
    assign decoded_tile = monster ?
        {5'd0,attribute_bits[6],attribute_bits[4:0],code_byte} : {
        // PCB footage: even columns use the low nibble, odd the high nibble.
        // MAME 0.289 reverses this and paints stage-map land with stale palettes.
        attribute_bits[6], pending_tile[0] ? map_data[7:4] : map_data[3:0],
        attribute_bits[5:0],code_byte
    };
    assign char_from_hit = monster ? {map_read_value[12:0],pixel_y,(pixel_x ^ {4{map_read_value[13]}})} : {map_read_value[13:0],pixel_y,pixel_x[3:1]};
    assign char_from_fill = monster ? {decoded_tile[12:0],pixel_y,(pixel_x ^ {4{decoded_tile[13]}})} : {decoded_tile[13:0],pixel_y,pixel_x[3:1]};
    assign hit_byte = character_byte(char_read_value,wanted_char[1:0]);
    assign fetched_byte = character_byte(char_data,wanted_char[1:0]);
    assign hit_pen = monster ? hit_byte : {4'd0,pixel_x[0] ? hit_byte[3:0] : hit_byte[7:4]};
    assign fetched_pen = monster ? fetched_byte : {4'd0,pixel_x[0] ? fetched_byte[3:0] : fetched_byte[7:4]};
    assign commit = (state==COORD && source_clipped) ||
        (state==CHAR_LOOKUP && char_read_valid && char_read_tag==wanted_char[20:2]) ||
        (state==CHAR_FETCH && char_ok);
    assign commit_value = state==COORD ? 13'b0 :
        {pending_palette, state==CHAR_FETCH ? fetched_pen : hit_pen};

    // Prepare at most three future active lines, never overwrite the displayed
    // bank. During vertical blank prepare the first four lines of the next frame.
    always_comb begin
        schedule_found = 0;
        schedule_line = 0;
        schedule_frame = vpos>=V_LIMIT ? ~frame_id : frame_id;
        candidate = 0;
        for(integer n=0;n<4;n=n+1) begin
            candidate = (vpos<V_FIRST || vpos>=V_LIMIT) ? SCHEDULE_CANDIDATE_BITS'({23'd0,V_FIRST}+32'(n)) :
                SCHEDULE_CANDIDATE_BITS'({1'b0,vpos})+SCHEDULE_CANDIDATE_BITS'(n+1);
            if(candidate<$signed({2'd0,V_LIMIT}) && (vpos<V_FIRST || vpos>=V_LIMIT || n<3) &&
               !schedule_found && !(line_ready[candidate[1:0]] &&
                line_tag[candidate[1:0]]==9'(candidate) &&
                line_frame[candidate[1:0]]==schedule_frame &&
                line_epoch[candidate[1:0]]==epoch)) begin
                schedule_found = 1;
                schedule_line = 9'(candidate);
            end
        end
    end

    wire memory_run=map_cache_ready && char_cache_ready && !rst && !((config_changed || job_abort) && !map_cs && !char_cs);
    wire map_read_en=memory_run && state==COORD && !source_clipped;
    wire map_write_en=memory_run && state==MAP_PAL && (monster || map_ok);
    wire char_hit_read=state==MAP_LOOKUP && map_read_valid && map_read_tag==pending_tile;
    wire char_fill_read=state==MAP_PAL && (monster || map_ok);
    wire char_read_en=memory_run && (char_hit_read || char_fill_read);
    wire [10:0] char_read_addr=char_fill_read ? char_hash(char_from_fill[20:2]) :
                                            char_hash(char_from_hit[20:2]);
    gaiapolis_cache_epoch_ram #(.AW(11)) u_map_valid(
        .clk(clk),.rst(rst),.we(map_write_en),.re(map_read_en),
        .write_addr(pending_map_index),.read_addr(map_index),
        .valid(map_read_valid),.ready(map_cache_ready));
    gaiapolis_cache_epoch_ram #(.AW(11)) u_char_valid(
        .clk(clk),.rst(rst),.we(memory_run && state==CHAR_FETCH && char_ok),.re(char_read_en),
        .write_addr(wanted_char_index),.read_addr(char_read_addr),
        .valid(char_read_valid),.ready(char_cache_ready));
    gaiapolis_bram #(.DW(37),.AW(11)) u_map_cache(
        .clk(clk),.we(map_write_en),.re(map_read_en),
        .write_addr(pending_map_index),.write_data({pending_tile,decoded_tile}),
        .read_addr(map_index),.read_data({map_read_tag,map_read_value}));
    gaiapolis_bram #(.DW(51),.AW(11)) u_char_cache(
        .clk(clk),.we(memory_run && state==CHAR_FETCH && char_ok),.re(char_read_en),
        .write_addr(wanted_char_index),.write_data({wanted_char[20:2],char_data}),
        .read_addr(char_read_addr),.read_data({char_read_tag,char_read_value}));
    gaiapolis_bram #(.DW(13),.AW(11)) u_pixels(
        .clk(clk),.we(memory_run && commit),.re(pxl_cen),
        .write_addr({job_line[1:0],output_x}),.write_data(commit_value),
        .read_addr({vpos[1:0],hpos}),.read_data(display_pixel));
    always_ff @(posedge clk) begin
        if(rst) begin
            scan_index <= 0;
            reply_index <= 0;
            reply_valid <= 0;
            control_seen <= 0;
            quiet <= 0;
            previous_clip_enable <= 0;
            previous_clip_rect <= 0;
            epoch <= 0;
            frame_id <= 0;
            previous_vpos <= 0;
            line_ready <= 0;
            line_frame <= 0;
            state <= IDLE;
            job_abort <= 0;
            map_cs <= 0;
            char_cs <= 0;
            map_addr <= 0;
            char_addr <= 0;
            line_addr <= 0;
            display_available <= 0;
            underflow <= 0;
            for(integer n=0;n<16;n=n+1) control[n] <= 0;
        end else begin
            // Match the one-clock register RAM read at gaiapolis_roz_regs.
            scan_index <= scan_index+4'd1;
            reply_index <= scan_index;
            reply_valid <= 1;
            if(reply_valid) begin
                control[reply_index] <= ctrl_data;
                control_seen[reply_index] <= 1;
            end
            previous_clip_enable <= clip_enabled;
            previous_clip_rect <= clip_rect;
            if(config_changed) begin
                epoch <= epoch+16'd1;
                quiet <= 0;
                line_ready <= 0;
                job_abort <= 1;
            end else if(quiet!=5'd31) quiet <= quiet+5'd1;

            if(pxl_cen) begin
                previous_vpos <= vpos;
                if(vpos<previous_vpos) frame_id <= ~frame_id;
                display_available <= 0;
                if(enabled && active_video && hpos>=H_FIRST && hpos<=H_LAST &&
                   vpos>=V_FIRST && vpos<V_LIMIT) begin
                    if(line_ready[vpos[1:0]] && line_tag[vpos[1:0]]==vpos &&
                       line_frame[vpos[1:0]]==frame_id &&
                       line_epoch[vpos[1:0]]==epoch && !config_changed) begin
                        display_available <= 1;
                    end else underflow <= 1;
                end
            end

            // Never revoke an outstanding ROM request. A changed transform
            // poisons the job, drains the transaction, then retries a future line.
            if((config_changed || job_abort) && !map_cs && !char_cs) begin
                state <= IDLE;
                job_abort <= 0;
            end else case(state)
                // Board/layer enable gates display, not the running ROZ chip.
                // Prepare lines before a first enable can arrive mid-raster.
                IDLE: if(map_cache_ready && char_cache_ready && (&control_seen) && quiet>=5'd16 &&
                         schedule_found) begin
                    job_line <= schedule_line;
                    job_frame <= schedule_frame;
                    job_epoch <= epoch;
                    job_clip_rect <= clip_rect;
                    job_clip_enabled <= clip_enabled;
                    output_x <= H_FIRST;
                    for(integer n=0;n<8;n=n+1) job_control[n] <= control[n];
                    if(control[7][6]) begin
                        line_word <= 0;
                        line_addr <= {schedule_line,2'b0};
                        state <= LINE_WAIT;
                    end else state <= SETUP;
                end
                LINE_WAIT: state <= LINE_CAPTURE;
                LINE_CAPTURE: begin
                    job_line_control[line_word] <= line_data;
                    if(line_word==2'd3) state <= SETUP;
                    else begin
                        line_word <= line_word+2'd1;
                        line_addr <= {job_line,line_word+2'd1};
                        state <= LINE_WAIT;
                    end
                end
                SETUP: begin
                    if(job_control[7][6]) begin
                        step_x <= super_hx;
                        step_y <= super_hy;
                        source_x <= origin(super_origin_x)+(32'({23'd0,H_FIRST})-(monster ? -8 : XOFFSET))*super_hx;
                        source_y <= origin(super_origin_y)+(32'({23'd0,H_FIRST})-(monster ? -8 : XOFFSET))*super_hy;
                    end else begin
                        step_x <= normal_hx;
                        step_y <= normal_hy;
                        source_x <= origin(job_control[0])+
                            (int'({1'b0,job_line})-YOFFSET)*normal_vx+
                            (32'({23'd0,H_FIRST})-(monster ? -8 : XOFFSET))*normal_hx;
                        source_y <= origin(job_control[1])+
                            (int'({1'b0,job_line})-YOFFSET)*normal_vy+
                            (32'({23'd0,H_FIRST})-(monster ? -8 : XOFFSET))*normal_hy;
                    end
                    state <= COORD;
                end
                COORD: begin
                    if(!source_clipped) begin
                        pixel_x <= wrapped_x[3:0];
                        pixel_y <= wrapped_y[3:0];
                        pending_tile <= tile_index;
                        pending_map_index <= map_index;
                        state <= MAP_LOOKUP;
                    end
                end
                MAP_LOOKUP: begin
                    if(map_read_valid && map_read_tag==pending_tile) begin
                        pending_palette <= map_read_value[18:14];
                        wanted_char <= char_from_hit;
                        wanted_char_index <= char_hash(char_from_hit[20:2]);
                        state <= CHAR_LOOKUP;
                    end else begin
                        map_addr <= (monster ? 20'h00000 : 20'h20000)+{2'b0,pending_tile};
                        map_cs <= 1;
                        state <= MAP_ATTR;
                    end
                end
                MAP_ATTR: if(map_ok) begin
                    // Gaiapolis: bit7 is a palette bit. Monster Maulers
                    // (MAME get_ult_936_tile_info): flip-X is bit 6 (0x40).
                    attribute_bits <= {monster ? map_data[6] : map_data[7],map_data[5:0]};
                    map_cs <= 0;
                    state <= MAP_CODE_REQUEST;
                end
                MAP_CODE_REQUEST: begin
                    map_addr <= (monster ? 20'h40000 : 20'h60000)+{2'b0,pending_tile};
                    map_cs <= 1;
                    state <= MAP_CODE;
                end
                MAP_CODE: if(map_ok) begin
                    code_byte <= map_data;
                    map_cs <= 0;
                    state <= MAP_PAL_REQUEST;
                end
                MAP_PAL_REQUEST: begin
                    map_addr <= {3'b0,pending_tile[17:1]};
                    map_cs <= !monster;
                    state <= MAP_PAL;
                end
                MAP_PAL: if(monster || map_ok) begin
                    pending_palette <= decoded_tile[18:14];
                    wanted_char <= char_from_fill;
                    wanted_char_index <= char_hash(char_from_fill[20:2]);
                    map_cs <= 0;
                    state <= CHAR_LOOKUP;
                end
                CHAR_LOOKUP: begin
                    if(!(char_read_valid && char_read_tag==wanted_char[20:2])) begin
                        char_addr <= {wanted_char[20:2],2'b0};
                        char_cs <= 1;
                        state <= CHAR_FETCH;
                    end
                end
                CHAR_FETCH: if(char_ok) begin
                    char_cs <= 0;
                end
                default: state <= IDLE;
            endcase
            if(commit && !((config_changed || job_abort) && !map_cs && !char_cs)) begin
                if(output_x==H_LAST) begin
                    line_ready[job_line[1:0]] <= job_epoch==epoch &&
                                               !config_changed && !job_abort;
                    line_tag[job_line[1:0]] <= job_line;
                    line_frame[job_line[1:0]] <= job_frame;
                    line_epoch[job_line[1:0]] <= job_epoch;
                    state <= IDLE;
                end else begin
                    output_x <= output_x+9'd1;
                    source_x <= source_x+step_x;
                    source_y <= source_y+step_y;
                    state <= COORD;
                end
            end
        end
    end
endmodule
