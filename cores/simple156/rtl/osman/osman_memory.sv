// SPDX-License-Identifier: GPL-3.0-or-later
// One-entry pulse queues and round-robin ownership over the real SDRAM port.
// Every physical read is one 64-bit burst (an aligned group of four words);
// the caches store whole groups, so a tile row pair / a sprite row / a CPU
// instruction pair costs one SDRAM transaction and the neighbours hit.
module osman_memory #(
    parameter integer CPU_CACHE_BITS=12,     // 64-bit groups (two 32-bit words)
    parameter integer GFX_CACHE_BITS=13,     // 64-bit tile ROM groups
    parameter integer SPRITE_CACHE_BITS=12   // 64-bit sprite ROM rows
)(
    input wire clk, reset, loader_exclusive,
    // osman_video render_urgent: withhold new CPU ROM fetches (cache hits and
    // an already-granted fetch still complete) until the line build finishes.
    input wire graphics_urgent,
    input wire [7:0] profile,
    input wire loader_valid,
    input wire [23:0] loader_addr,
    input wire [15:0] loader_data,
    input wire [1:0] loader_be,
    output wire loader_ready,
    input wire cpu_req,
    input wire [16:0] cpu_word_addr,
    output wire cpu_ready,
    output reg [31:0] cpu_data,
    input wire tiles_req,
    input wire [19:0] tiles_addr,
    output reg tiles_valid,
    output reg [15:0] tiles_data,
    output reg [63:0] tiles_data64,
    input wire sprites_req,
    input wire [21:0] sprites_addr,
    output reg sprites_valid,
    output reg [15:0] sprites_data,
    output reg [63:0] sprites_data64,
    input wire sfx_req,
    input wire [17:0] sfx_addr,
    output reg sfx_valid,
    output reg [7:0] sfx_data,
    input wire music_req,
    input wire [20:0] music_addr,
    output reg music_valid,
    output reg [7:0] music_data,
    output wire dram_req, dram_we,
    output wire [24:0] dram_addr,
    output wire [15:0] dram_wdata,
    output wire [1:0] dram_be,
    input wire dram_ready,
    input wire [63:0] dram_rdata64,
    output reg queue_overflow,
    output reg [31:0] cpu_cache_hits,cpu_cache_misses,
    output reg [31:0] tile_cache_hits,tile_cache_misses,
    output reg [31:0] sprite_cache_hits,sprite_cache_misses
);
    localparam [1:0] IDLE=0, ACCESS=1, WITHDRAW=2;
    localparam integer CPU_WORDS=1<<CPU_CACHE_BITS,GFX_WORDS=1<<GFX_CACHE_BITS,SPR_WORDS=1<<SPRITE_CACHE_BITS;
    // Group address widths: CPU 16 (of 32-bit word pairs), tiles 18, sprites 20.
    localparam integer CPU_TAG_BITS=16-CPU_CACHE_BITS,TILE_TAG_BITS=18-GFX_CACHE_BITS,SPRITE_TAG_BITS=20-SPRITE_CACHE_BITS;
    // Synchronous tagged ROM caches of 64-bit groups. Only a completed physical
    // transaction fills an entry. The valid flag is the top bit of each RAM
    // word. Reset and every download start run a one-entry-per-clock sweep
    // that clears the flags; until it ends every lookup misses and fills are
    // dropped, so a stale entry can never hit.
    localparam integer CPU_V=64+CPU_TAG_BITS,TILE_V=64+TILE_TAG_BITS,SPRITE_V=64+SPRITE_TAG_BITS;
    (* ramstyle="M10K" *) reg [CPU_V:0] cpu_cache [0:CPU_WORDS-1];
    (* ramstyle="M10K" *) reg [TILE_V:0] tile_cache [0:GFX_WORDS-1];
    (* ramstyle="M10K" *) reg [SPRITE_V:0] sprite_cache [0:SPR_WORDS-1];
    reg [CPU_V:0] cpu_lookup;
    reg [TILE_V:0] tile_lookup;
    reg [SPRITE_V:0] sprite_lookup;
    reg old_loader_exclusive;
    reg cache_clearing;
    localparam integer CLEAR_BITS = GFX_CACHE_BITS>SPRITE_CACHE_BITS ?
        (GFX_CACHE_BITS>CPU_CACHE_BITS ? GFX_CACHE_BITS : CPU_CACHE_BITS) :
        (SPRITE_CACHE_BITS>CPU_CACHE_BITS ? SPRITE_CACHE_BITS : CPU_CACHE_BITS);
    reg [CLEAR_BITS-1:0] cache_clear_index;
    reg cpu_lookup_pending,tile_lookup_pending,sprite_lookup_pending;
    reg [19:0] tile_lookup_word;
    reg [21:0] sprite_lookup_word;
    reg [1:0] state;
    reg [4:0] pending;
    reg [24:0] pending_addr [0:4];
    reg [2:0] owner, round_robin;
    reg [24:0] held_addr;
    reg [16:0] held_cpu_word;
    reg cpu_done;
    wire cpu_active = owner==0 && state!=IDLE;
    // Group addresses of the held physical transaction.
    wire [17:0] held_tile_group=18'((held_addr-25'h080000)>>3);
    wire [19:0] held_sprite_group=20'((held_addr-25'h280000)>>3);
    wire [15:0] held_cpu_group=held_cpu_word[16:1];
    // Dedicated unreset synchronous payload/tag ports; valid maps reset separately.
    // The admitted edge produces lookup data for the existing next-edge consumer.
    wire tile_cache_rd_en = !reset && !loader_exclusive && tiles_req &&
        !(tile_lookup_pending || pending[1] || (state==ACCESS && owner==3'd1));
    wire sprite_cache_rd_en = !reset && !loader_exclusive && sprites_req &&
        !(sprite_lookup_pending || pending[2] || (state==ACCESS && owner==3'd2));
    wire [GFX_CACHE_BITS-1:0] tile_cache_rd_addr = tiles_addr[GFX_CACHE_BITS+1:2];
    wire [SPRITE_CACHE_BITS-1:0] sprite_cache_rd_addr = sprites_addr[SPRITE_CACHE_BITS+1:2];
    wire tile_cache_wr_en = !reset && !loader_exclusive &&
        state==ACCESS && dram_ready && owner==3'd1;
    wire sprite_cache_wr_en = !reset && !loader_exclusive &&
        state==ACCESS && dram_ready && owner==3'd2;
    always @(posedge clk) begin
        if(tile_cache_rd_en) tile_lookup <= tile_cache[tile_cache_rd_addr];
        if(tile_cache_wr_en || cache_clearing)
            tile_cache[cache_clearing ? cache_clear_index[GFX_CACHE_BITS-1:0] : held_tile_group[GFX_CACHE_BITS-1:0]] <=
                cache_clearing ? {(TILE_V+1){1'b0}} : {1'b1,held_tile_group[17:GFX_CACHE_BITS],dram_rdata64};
    end
    always @(posedge clk) begin
        if(sprite_cache_rd_en) sprite_lookup <= sprite_cache[sprite_cache_rd_addr];
        if(sprite_cache_wr_en || cache_clearing)
            sprite_cache[cache_clearing ? cache_clear_index[SPRITE_CACHE_BITS-1:0] : held_sprite_group[SPRITE_CACHE_BITS-1:0]] <=
                cache_clearing ? {(SPRITE_V+1){1'b0}} : {1'b1,held_sprite_group[19:SPRITE_CACHE_BITS],dram_rdata64};
    end
    wire cpu_cache_rd_en = !reset && !loader_exclusive && cpu_req && !pending[0] &&
        !cpu_done && !cpu_active && !cpu_lookup_pending;
    wire cpu_cache_wr_en = !reset && !loader_exclusive && state==ACCESS && dram_ready && owner==3'd0;
    always @(posedge clk) begin
        if(cpu_cache_rd_en) cpu_lookup <= cpu_cache[cpu_word_addr[CPU_CACHE_BITS:1]];
        if(cpu_cache_wr_en || cache_clearing)
            cpu_cache[cache_clearing ? cache_clear_index[CPU_CACHE_BITS-1:0] : held_cpu_group[CPU_CACHE_BITS-1:0]] <=
                cache_clearing ? {(CPU_V+1){1'b0}} : {1'b1,held_cpu_group[15:CPU_CACHE_BITS],dram_rdata64};
    end
    always @(posedge clk) begin
        if(reset || (loader_exclusive && !old_loader_exclusive)) begin
            cache_clearing<=1;cache_clear_index<=0;
        end else if(cache_clearing) begin
            cache_clear_index<=cache_clear_index+1'b1;
            if(&cache_clear_index) cache_clearing<=0;
        end
    end
    wire [4:0] pulse = {music_req,sfx_req,sprites_req,tiles_req,1'b0};
    reg grant_valid;
    reg [2:0] grant;
    reg graphics_priority_debt;
    reg graphics_priority_override;
    integer n, index;
    // Audio channels are rate-limited and stay eligible during urgency.
    wire [4:0] eligible = pending & {4'b1111, !graphics_urgent};
    always @* begin
        grant_valid=0;grant=0;index=0;graphics_priority_override=0;
        for(n=0;n<5;n=n+1) begin
            index=integer'(round_robin)+n;
            if(index>=5)index=index-5;
            if(!grant_valid && eligible[index]) begin grant_valid=1;grant=3'(index);end
        end
        // One graphics grant may precede an ordinary CPU grant; natural RR serves both graphics clients. Audio RR grants remain intact.
        if (grant_valid && !graphics_priority_debt && grant==0 && (pending[1] || pending[2])) begin
            grant=pending[1] ? 3'd1 : 3'd2; graphics_priority_override=1;
        end else if (grant_valid && graphics_priority_debt && eligible[0] && (grant==1 || grant==2))
            grant=0;
    end
    always @(posedge clk) begin
        if (reset || loader_exclusive) graphics_priority_debt<=0;
        else if ((state==IDLE || state==WITHDRAW) && grant_valid) begin
            if (graphics_priority_override) graphics_priority_debt<=1;
            else if (grant==0) graphics_priority_debt<=0;
        end
    end
    assign dram_req = loader_exclusive ? loader_valid : state==ACCESS;
    assign dram_we = loader_exclusive;
    assign dram_addr = loader_exclusive ? {1'b0,loader_addr} : held_addr;
    assign dram_wdata = loader_exclusive ? loader_data : 16'd0;
    assign dram_be = loader_exclusive ? loader_be : 2'b11;
    assign loader_ready = loader_exclusive && dram_ready;
    assign cpu_ready = !loader_exclusive && cpu_done && cpu_req && cpu_word_addr==held_cpu_word;
    // Word / byte selection inside the returned group.
    wire [15:0] group_word = held_addr[2:1]==2'd0 ? dram_rdata64[15:0] : held_addr[2:1]==2'd1 ? dram_rdata64[31:16] :
                             held_addr[2:1]==2'd2 ? dram_rdata64[47:32] : dram_rdata64[63:48];
    wire [7:0] group_byte = held_addr[0] ? group_word[15:8] : group_word[7:0];
    wire [31:0] group_dword = held_cpu_word[0] ? dram_rdata64[63:32] : dram_rdata64[31:0];

    always @(posedge clk) begin
        tiles_valid<=0;sprites_valid<=0;sfx_valid<=0;music_valid<=0;
        old_loader_exclusive<=loader_exclusive;
        if(reset || loader_exclusive) begin
            state<=IDLE;pending<=0;owner<=0;round_robin<=0;
            held_addr<=0;held_cpu_word<=0;cpu_done<=0;
            cpu_data<=0;tiles_data<=0;sprites_data<=0;tiles_data64<=0;sprites_data64<=0;
            sfx_data<=0;music_data<=0;queue_overflow<=0;
            for(integer p=0;p<5;p=p+1)pending_addr[p]<=0;
            cpu_lookup_pending<=0;tile_lookup_pending<=0;sprite_lookup_pending<=0;
            tile_lookup_word<=0;sprite_lookup_word<=0;
            // Clear once on entering a new download, not once per streamed word.
            if(reset || !old_loader_exclusive) begin
                cpu_cache_hits<=0;cpu_cache_misses<=0;tile_cache_hits<=0;tile_cache_misses<=0;
                sprite_cache_hits<=0;sprite_cache_misses<=0;
            end
        end else begin
            if(cpu_done && (!cpu_req || cpu_word_addr!=held_cpu_word))cpu_done<=0;
            // Independent cache RAM ports return hits during unrelated misses.
            cpu_lookup_pending<=0;tile_lookup_pending<=0;sprite_lookup_pending<=0;
            if(cpu_req && !pending[0] && !cpu_done && !cpu_active && !cpu_lookup_pending) begin
                held_cpu_word<=cpu_word_addr;cpu_lookup_pending<=1;
            end
            if(tiles_req) begin
                if(tile_lookup_pending || pending[1] || (state==ACCESS && owner==1))queue_overflow<=1;
                else begin
                    tile_lookup_pending<=1;tile_lookup_word<=tiles_addr;
                end
            end
            if(sprites_req) begin
                if(sprite_lookup_pending || pending[2] || (state==ACCESS && owner==2))queue_overflow<=1;
                else begin
                    sprite_lookup_pending<=1;sprite_lookup_word<=sprites_addr;
                end
            end
            if(cpu_lookup_pending) begin
                if(!cache_clearing && cpu_lookup[CPU_V] && cpu_lookup[63+CPU_TAG_BITS:64]==held_cpu_word[16:CPU_CACHE_BITS+1]) begin
                    cpu_data<=held_cpu_word[0] ? cpu_lookup[63:32] : cpu_lookup[31:0];
                    cpu_done<=1;cpu_cache_hits<=cpu_cache_hits+1'b1;
                end else begin
                    pending[0]<=1;pending_addr[0]<={6'd0,held_cpu_word,2'b00};cpu_cache_misses<=cpu_cache_misses+1'b1;
                end
            end
            if(tile_lookup_pending) begin
                if(!cache_clearing && tile_lookup[TILE_V] && tile_lookup[63+TILE_TAG_BITS:64]==tile_lookup_word[19:GFX_CACHE_BITS+2]) begin
                    tiles_data64<=tile_lookup[63:0];
                    tiles_data<=tile_lookup_word[1:0]==2'd0 ? tile_lookup[15:0] : tile_lookup_word[1:0]==2'd1 ? tile_lookup[31:16] :
                                tile_lookup_word[1:0]==2'd2 ? tile_lookup[47:32] : tile_lookup[63:48];
                    tiles_valid<=1;tile_cache_hits<=tile_cache_hits+1'b1;
                end else begin
                    pending[1]<=1;pending_addr[1]<=25'h080000+{4'd0,tile_lookup_word,1'b0};tile_cache_misses<=tile_cache_misses+1'b1;
                end
            end
            if(sprite_lookup_pending) begin
                if(!cache_clearing && sprite_lookup[SPRITE_V] && sprite_lookup[63+SPRITE_TAG_BITS:64]==sprite_lookup_word[21:SPRITE_CACHE_BITS+2]) begin
                    sprites_data64<=sprite_lookup[63:0];
                    sprites_data<=sprite_lookup_word[1:0]==2'd0 ? sprite_lookup[15:0] : sprite_lookup_word[1:0]==2'd1 ? sprite_lookup[31:16] :
                                  sprite_lookup_word[1:0]==2'd2 ? sprite_lookup[47:32] : sprite_lookup[63:48];
                    sprites_valid<=1;sprite_cache_hits<=sprite_cache_hits+1'b1;
                end else begin
                    pending[2]<=1;pending_addr[2]<=25'h280000+{2'd0,sprite_lookup_word,1'b0};sprite_cache_misses<=sprite_cache_misses+1'b1;
                end
            end
            for(integer p=3;p<5;p=p+1) begin
                if(pulse[p]) begin
                    // Each pulse channel permits exactly one outstanding read.
                    if(pending[p] || (state==ACCESS && owner==3'(p)))queue_overflow<=1;
                    else pending[p]<=1;
                end
            end
            if(sfx_req && !pending[3] && !(state==ACCESS && owner==3))
                pending_addr[3]<=25'ha80000+{7'd0,sfx_addr};
            if(music_req && !pending[4] && !(state==ACCESS && owner==4))
                pending_addr[4]<=25'hac0000+{4'd0,music_addr};
            case(state)
                IDLE: if(grant_valid) begin
                    owner<=grant;held_addr<=pending_addr[grant];pending[grant]<=0;
                    state<=ACCESS;
                    round_robin<=grant==4 ? 3'd0 : grant+1'b1;
                end
                ACCESS: if(dram_ready) begin
                    state<=WITHDRAW;
                    case(owner)
                        0: begin cpu_data<=group_dword;cpu_done<=1;end
                        1: begin
                            tiles_data64<=dram_rdata64;tiles_data<=group_word;tiles_valid<=1;
                        end
                        2: begin
                            sprites_data64<=dram_rdata64;sprites_data<=group_word;sprites_valid<=1;
                        end
                        3: begin sfx_data<=group_byte;sfx_valid<=1;end
                        4: begin music_data<=group_byte;music_valid<=1;end
                        default: begin end
                    endcase
                end
                WITHDRAW: if(grant_valid) begin
                    // The SDRAM frontend observes the full withdrawn cycle.
                    // Select its next owner without another arbitration cycle.
                    owner<=grant;held_addr<=pending_addr[grant];pending[grant]<=0;
                    state<=ACCESS;
                    round_robin<=grant==4 ? 3'd0 : grant+1'b1;
                end else state<=IDLE;
                default: state<=IDLE;
            endcase
        end
    end
endmodule
