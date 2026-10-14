// SPDX-License-Identifier: BSD-3-Clause
// Bus-fed RGB565 scanout: two prefetched lines, no host framebuffer substitute.
// Addressing follows pinned MAME get_fb_addr/screen_update. CRT Display Start
// interpretation remains separate; display_address is the GPU-selected base.
// LINE_BURST=1 fetches 32-byte-aligned lines as 32-byte bursts on a dedicated line-burst
// port (which the board serves ahead of the GPU) instead of 32-bit words through the shared
// word arbiter. Word-by-word fetches lost one GPU burst plus a CPU turn per word under load,
// so a 320-pixel line (160 words) approached the 5460-clock line period and missed it on
// hardware (black and left-black lines). Unaligned bases keep the word path.
module vr0_scanout #(parameter bit LINE_BURST=0) (
    input logic clk, reset, restart,
    input logic flip, // 180-degree picture (OSD Orientation Flipped), sampled at the frame start
    input logic pixel_tick, display_enable, screen_blank,
    input logic hsync, vsync, hblank, vblank,
    input logic [11:0] pixel_x, pixel_y, visible_width, visible_height,
    input logic [22:0] display_address,
    output logic video_tick, video_de, video_hsync, video_vsync, video_hblank, video_vblank,
    output logic [11:0] video_x, video_y,
    output logic [7:0] video_r, video_g, video_b,
    output logic armed, underrun, memory_fault, unsupported_geometry,
    output logic [31:0] fault_address, words_fetched,
    output logic [1:0] line_valid,
    output logic req_valid,
    input logic req_ready,
    output logic [31:0] req_address, req_data,
    output logic [3:0] req_strobe,
    output logic req_write,
    input logic rsp_valid,
    input logic [31:0] rsp_data,
    input logic rsp_error,
    // Frame RAM line-burst read port (region 1), used when LINE_BURST=1.
    output logic burst_valid,
    output logic [17:0] burst_line,
    input logic burst_ready, burst_done,
    input logic [7:0][31:0] burst_rdata
);
    // One write port and one synchronous read port; intentionally no RAM reset.
    logic [31:0] line_ram [0:1023];
    logic [11:0] tag_y [0:1], tag_width [0:1];
    logic [22:0] tag_base [0:1];
    typedef enum logic [2:0] {IDLE, REQUEST, RESPONSE, BURST_REQUEST, BURST_WAIT, BURST_FINISH} state_t;
    // Burst fill: a returned 32-byte burst is written into the line RAM (one word per clock) while the next
    // burst is already requested, so a line costs ~one burst latency per 16 pixels (640-pixel 31-kHz modes,
    // urachamu, fetch 40 bursts per 2730-clock line).
    logic [7:0][31:0] burst_buffer;
    logic [2:0] drain_index;
    logic drain_active;
    logic [9:0] drain_base, write_word;
    state_t state;
    logic [11:0] desired_y, next_y, fetch_y, fetch_width;
    logic [22:0] fetch_base, fetch_offset;
    logic [9:0] fetch_words;
    logic [8:0] word_index;
    logic desired_ready, next_ready, current_ready, fetch_slot;
    logic fetch_cancelled;
    // Native flip: line y is frame-RAM row H-1-y, stored mirrored into the line buffer (fetched word j goes to
    // word fetch_words-1-j) and shown with the two pixels of each word swapped, so the read address stays the
    // plain raster position (line_ram stays an M10K). flip_q is sampled at the first blanking pixel of the last
    // visible line: that line was fetched and is shown with the old value, line 0 of the next frame (fetched
    // in vertical blanking) with the new one.
    logic flip_q;
    logic [11:0] mem_y;
    logic [9:0] store_index;
    // Registered line-launch decision: the ready-line predicate chain from the
    // raster position is too long for one clk_sys cycle. idle_q makes a launch
    // use a decision computed from tags that were already current (a fetch
    // completing updates them on the edge that enters IDLE).
    logic launch_q, idle_q;
    logic [11:0] launch_y_q;
    logic pixel_pending, pending_de, pending_visible, pending_ready, pending_armed;
    logic pending_hsync, pending_vsync, pending_hblank, pending_vblank, pending_half;
    logic [11:0] pending_x, pending_y;
    logic [31:0] pixel_word;
    logic [15:0] color;
    function automatic logic ready_line(input logic [11:0] y);
        return line_valid[y[0]] && tag_y[y[0]]==y &&
            tag_width[y[0]]==visible_width && tag_base[y[0]]==display_address;
    endfunction
    always_comb begin
        unsupported_geometry=visible_width==0 || visible_width>1024 ||
            visible_height==0 || visible_height>1024 || display_address[1:0]!=0;
        desired_y=pixel_y<visible_height ? pixel_y : 12'd0;
        if(pixel_y<visible_height && pixel_x>=visible_width)
            desired_y=pixel_y+1'b1<visible_height ? pixel_y+1'b1 : 12'd0;
        next_y=desired_y+1'b1;
        desired_ready=ready_line(desired_y);
        next_ready=next_y<visible_height && ready_line(next_y);
        current_ready=ready_line(pixel_y);
        fetch_offset=fetch_base+{3'b0,mem_y[8:0],word_index,2'b00};
        write_word=drain_active ? drain_base+{7'b0,drain_index} : {1'b0,word_index};
        store_index=flip_q ? fetch_words-10'd1-write_word : write_word;
        req_valid=state==REQUEST;
        // Never let a new burst complete into burst_buffer before the previous one is half drained (a burst
        // takes well over four clocks from acceptance to done).
        burst_valid=LINE_BURST && state==BURST_REQUEST && !(drain_active && drain_index<3'd4);
        burst_line=fetch_offset[22:5];
        req_address=32'h04000000+{9'b0,fetch_offset};
        req_data=0;req_strobe=15;req_write=0;
        color=pending_half?pixel_word[31:16]:pixel_word[15:0];
    end
    wire ram_we = !reset && (drain_active ? write_word<fetch_words : (state==RESPONSE && rsp_valid && !rsp_error));
    always_ff @(posedge clk) if(ram_we) line_ram[{fetch_slot,store_index[8:0]}] <= drain_active ? burst_buffer[drain_index] : rsp_data;
    always_ff @(posedge clk) begin
        if(reset) begin
            state<=IDLE;line_valid<=0;armed<=0;underrun<=0;memory_fault<=0;
            fault_address<=0;words_fetched<=0;word_index<=0;fetch_slot<=0;
            fetch_y<=0;fetch_width<=0;fetch_words<=0;fetch_base<=0;fetch_cancelled<=0;
            launch_q<=0;idle_q<=0;launch_y_q<=0;flip_q<=0;mem_y<=0;drain_index<=0;burst_buffer<=0;drain_active<=0;drain_base<=0;
            pixel_pending<=0;pending_de<=0;pending_visible<=0;pending_ready<=0;pending_armed<=0;
            pending_x<=0;pending_y<=0;pending_half<=0;pixel_word<=0;
            pending_hsync<=1;pending_vsync<=1;pending_hblank<=1;pending_vblank<=1;
            video_tick<=0;video_de<=0;video_hsync<=1;video_vsync<=1;
            video_hblank<=1;video_vblank<=1;video_x<=0;video_y<=0;
            video_r<=0;video_g<=0;video_b<=0;
            for(integer i=0;i<2;i=i+1) begin tag_y[i]<=0;tag_width[i]<=0;tag_base[i]<=0;end
        end else begin
            // Keep launch parameters current while idle. The actual launch
            // still captures the same edge, without the long ready-line
            // predicate gating the width/base/word-count registers.
            if(state==IDLE) begin
                fetch_base<=display_address;fetch_width<=visible_width;
                fetch_words<=10'(({1'b0,visible_width}+13'd1)>>1);
            end
            launch_q<=!desired_ready || (!next_ready && next_y<visible_height);
            launch_y_q<=desired_ready?next_y:desired_y;
            idle_q<=state==IDLE;
            video_tick<=pixel_pending;
            pixel_pending<=pixel_tick;
            if(screen_blank || unsupported_geometry || restart) begin armed<=0;line_valid<=0;end
            if(state!=IDLE && (screen_blank || unsupported_geometry || restart ||
                fetch_base!=display_address || fetch_width!=visible_width)) fetch_cancelled<=1;
            if(pixel_tick) begin
                pixel_word<=line_ram[{pixel_y[0],pixel_x[9:1]}];
                pending_half<=pixel_x[0]^flip_q;pending_x<=pixel_x;pending_y<=pixel_y;
                pending_de<=display_enable;pending_visible<=display_enable&&!screen_blank&&!restart;
                pending_ready<=current_ready;
                pending_armed<=!restart && (armed || (pixel_x==0 && pixel_y==0 && current_ready));
                pending_hsync<=hsync;pending_vsync<=vsync;
                pending_hblank<=hblank;pending_vblank<=vblank;
                if(pixel_x==visible_width && pixel_y==visible_height-12'd1) flip_q<=flip;
                if(pixel_x==0 && pixel_y==0 && !screen_blank && !unsupported_geometry && !restart) begin
                    armed<=current_ready;
                    if(armed && !current_ready) underrun<=1;
                end
                if(display_enable && armed && !current_ready && !restart) underrun<=1;
            end
            if(pixel_pending) begin
                video_x<=pending_x;video_y<=pending_y;video_de<=pending_de;
                video_hsync<=pending_hsync;video_vsync<=pending_vsync;
                video_hblank<=pending_hblank;video_vblank<=pending_vblank;
                if(pending_visible && pending_ready && pending_armed) begin
                    video_r<={color[15:11],color[15:13]};
                    video_g<={color[10:5],color[10:9]};
                    video_b<={color[4:0],color[4:2]};
                end else begin video_r<=0;video_g<=0;video_b<=0;end
            end
            // Burst drain into the line RAM, overlapped with the next burst request.
            if(drain_active) begin
                if(write_word<fetch_words) words_fetched<=words_fetched+1'b1;
                drain_index<=drain_index+3'd1;
                if(drain_index==3'd7) drain_active<=0;
            end
            case(state)
                IDLE: if(!screen_blank && !unsupported_geometry && !restart && idle_q && launch_q) begin
                    fetch_y<=launch_y_q;
                    mem_y<=flip_q ? visible_height-12'd1-launch_y_q : launch_y_q;
                    fetch_slot<=launch_y_q[0];
                    line_valid[launch_y_q[0]]<=0;
                    word_index<=0;fetch_cancelled<=0;
                    state<=(LINE_BURST && fetch_base[4:0]==0) ? BURST_REQUEST : REQUEST;
                end
                BURST_REQUEST: if(burst_ready && burst_valid) state<=BURST_WAIT;
                BURST_WAIT: if(burst_done) begin
                    if(fetch_cancelled || restart || screen_blank || unsupported_geometry || fetch_base!=display_address || fetch_width!=visible_width) begin
                        drain_active<=0;state<=IDLE;
                    end else begin
                        burst_buffer<=burst_rdata;drain_active<=1;drain_index<=0;drain_base<={1'b0,word_index};
                        if({1'b0,word_index}+10'd8>=fetch_words) state<=BURST_FINISH;
                        else begin word_index<=word_index+9'd8;state<=BURST_REQUEST;end
                    end
                end
                BURST_FINISH: begin
                    if(fetch_cancelled || restart || screen_blank || unsupported_geometry || fetch_base!=display_address || fetch_width!=visible_width) begin
                        drain_active<=0;state<=IDLE;
                    end else if(!drain_active) begin
                        tag_y[fetch_slot]<=fetch_y;tag_width[fetch_slot]<=fetch_width;tag_base[fetch_slot]<=fetch_base;
                        line_valid[fetch_slot]<=1;state<=IDLE;
                    end
                end
                REQUEST: if(req_ready) state<=RESPONSE;
                RESPONSE: if(rsp_valid) begin
                    if(rsp_error) begin memory_fault<=1;fault_address<=req_address;state<=IDLE;end
                    else begin
                        words_fetched<=words_fetched+1'b1;
                        if(fetch_cancelled || restart || screen_blank || unsupported_geometry || fetch_base!=display_address || fetch_width!=visible_width)
                            state<=IDLE;
                        else if({1'b0,word_index}+10'd1==fetch_words) begin
                            tag_y[fetch_slot]<=fetch_y;tag_width[fetch_slot]<=fetch_width;tag_base[fetch_slot]<=fetch_base;
                            line_valid[fetch_slot]<=1;state<=IDLE;
                        end else begin word_index<=word_index+1'b1;state<=REQUEST;end
                    end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
