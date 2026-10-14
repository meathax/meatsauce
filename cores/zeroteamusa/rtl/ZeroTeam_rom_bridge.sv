// SPDX-License-Identifier: GPL-3.0-or-later
// Native LE words. Bank 0: main/chars/tiles/OKI; bank 1: encrypted sprites.
// Logical addresses follow the pinned Sorgelig controller's [bank,row,column].
// 32 MiB SDRAM suffices; no DDR3 ROM dependency or four-bank aliasing.
module ZeroTeam_rom_bridge (
    input wire clk,reset,ready,download,word_wr,
    input wire [26:0] word_address,
    input wire [15:0] word_data,
    output wire download_wait,
    output wire download_busy,
    input wire gfx_req,
    input wire [23:0] gfx_address,
    input wire [2:0] gfx_kind,
    output reg [31:0] gfx_data,
    output reg gfx_valid,
    // Dedicated sprite row port: one request = one 16-pixel 4bpp row (8 bytes,
    // spr_address 8-byte aligned, encrypted LE). Delivered as two native LE32
    // halves (bytes 0-3 then 4-7) with spr_valid/spr_half. Hold spr_req high
    // until the second half; dropping it cancels delivery of a stale row.
    input wire spr_req,
    input wire [23:0] spr_address,
    output reg [31:0] spr_data,
    output reg spr_valid,
    output reg spr_half,
    input wire main_req,cop_req,
    input wire [23:0] main_address,cop_address,
    output reg [15:0] main_data,cop_data,
    output reg main_valid,cop_valid,
    input wire [17:0] oki_address,
    output reg [7:0] oki_data,
    output reg oki_valid,
    output reg [23:0] addr0,addr1,addr2,addr3,
    output reg [15:0] din0,
    output reg we0,req0,req1,req2,req3,
    output reg [1:0] len0,
    input wire ack0,ack1,ack2,ack3,
    input wire beat0,
    input wire [15:0] dout0,dout1,dout2,dout3
);
    // Graphics reads are single SDRAM transactions: tiles 2 words, sprite rows
    // 4 words (one ACTIVE, back-to-back column reads). The former design read
    // every 16-bit word as its own 8-clock row cycle and returned to IDLE
    // between them, so a 16-pixel sprite row cost four row cycles plus two
    // arbiter round trips (~95 clocks under load). Busy lines overran the
    // 6144-clock line and the renderer dropped its front-most sprites.
    localparam IDLE=0,WRITE_WAIT=1,GFX_READ=2,SPR_READ=3;
    reg [1:0] state;
    reg [15:0] first_word;
    reg [1:0] beat;
    reg sprite_word;
    reg spr_seen,spr_live,spr_turn;
    // tile_rom_arbiter's request is a one-clock pulse; it holds the address
    // and kind until the response. Latch it so it survives a sprite grant.
    reg gfx_pending;
    reg [23:0] gfx_fetch_address;
    reg gfx_fetch_sprite;
    reg gfx_seen,main_pending,cop_pending;
    reg main_seen,cop_seen;
    reg oki_pending,oki_started,oki_odd;
    reg [17:0] oki_previous;
    // Include word_wr: HPS cannot send another pair before the FSM latches it.
    assign download_wait = !ready || word_wr || state!=IDLE;
    assign download_busy = word_wr || state==WRITE_WAIT;
    wire store_common = word_address<27'h560000;
    wire store_sprite = word_address>=27'h600000 && word_address<27'he00000;
    wire [23:0] download_address = store_sprite
        ? {2'b01,(word_address[22:1]-22'h300000)}
        : {2'b00,word_address[22:1]};
    wire [21:0] gfx_base = gfx_kind==4 ? 22'h080000 : 22'h090000;
    wire [23:0] fetch_address = gfx_kind==3
        ? {2'b01,gfx_address[22:1]}
        : {2'b00,(gfx_base+gfx_address[22:1])};
    always @(posedge clk) begin
        if(reset) begin
            state<=IDLE; req0<=0; we0<=0; gfx_valid<=0; gfx_seen<=0;
            addr0<=0; din0<=0; gfx_data<=0; first_word<=0; sprite_word<=0;
            len0<=0; beat<=0; spr_seen<=0; spr_live<=0; spr_turn<=0;
            gfx_pending<=0; gfx_fetch_address<=0; gfx_fetch_sprite<=0;
            spr_valid<=0; spr_half<=0; spr_data<=0;
            req1<=0; req2<=0; req3<=0; main_pending<=0; cop_pending<=0;
            main_valid<=0; cop_valid<=0; main_seen<=0; cop_seen<=0;
            main_data<=0; cop_data<=0; addr1<=0; addr2<=0; addr3<=0;
            oki_pending<=0; oki_started<=0; oki_valid<=0; oki_data<=0;
            oki_previous<=0; oki_odd<=0;
        end else begin
            gfx_valid<=0; cop_valid<=0; main_valid<=0; spr_valid<=0;
            if(!main_req) main_seen<=0;
            if(!gfx_req) gfx_seen<=0;
            if(gfx_req && !gfx_seen && !download) begin
                gfx_pending<=1; gfx_seen<=1;
                gfx_fetch_address<=fetch_address; gfx_fetch_sprite<=gfx_kind==3;
            end
            if(!spr_req) begin spr_seen<=0; spr_live<=0; end
            if(!cop_req) cop_seen<=0;
            case(state)
                IDLE: if(ready) begin
                    beat<=0;
                    if(word_wr && (store_common || store_sprite)) begin
                        addr0<=download_address; din0<=word_data; len0<=0;
                        we0<=1; req0<=~req0; state<=WRITE_WAIT;
                    end else if(!download && spr_req && !spr_seen &&
                                (spr_turn || !gfx_pending)) begin
                        // Alternate with tiles when both wait: both have line deadlines.
                        addr0<={2'b01,spr_address[22:3],2'b00}; len0<=2'd3;
                        we0<=0; req0<=~req0; state<=SPR_READ;
                        spr_seen<=1; spr_live<=1; spr_turn<=0;
                    end else if(!download && gfx_pending) begin
                        addr0<=gfx_fetch_address; sprite_word<=gfx_fetch_sprite; len0<=2'd1;
                        we0<=0; req0<=~req0; state<=GFX_READ; gfx_pending<=0; spr_turn<=1;
                    end
                end
                WRITE_WAIT: if(ack0==req0) begin we0<=0; state<=IDLE; end
                GFX_READ: if(beat0) begin
                    beat<=beat+2'd1;
                    if(beat==0) first_word<=dout0;
                    else begin
                        // The target renderer expects different packing for sprite ROM.
                        gfx_data<=sprite_word ? {dout0,first_word} : {first_word,dout0};
                        gfx_valid<=1; state<=IDLE;
                    end
                end
                SPR_READ: if(beat0) begin
                    beat<=beat+2'd1;
                    if(!beat[0]) first_word<=dout0;
                    else begin
                        spr_data<={dout0,first_word};
                        spr_half<=beat[1];
                        spr_valid<=spr_live && spr_req;
                        if(beat[1]) state<=IDLE;
                    end
                end
            endcase
            if(ready && !download) begin
                // The V30 adapter (Raiden2_main_top) holds main_req high until a
                // one-clock main_valid pulse, like the COP port. A toggle/level
                // acknowledge here re-issued a phantom read after every fetch and
                // returned stale data whenever SDRAM latency exceeded a few clocks.
                if(main_req && !main_seen && !main_pending) begin
                    addr1<={2'b00,main_address[22:1]}; req1<=~req1;
                    main_pending<=1; main_seen<=1;
                end
                if(cop_req && !cop_seen && !cop_pending) begin
                    addr2<={2'b00,cop_address[22:1]}; req2<=~req2;
                    cop_pending<=1; cop_seen<=1;
                end
                if(!oki_pending && (!oki_started || oki_address!=oki_previous)) begin
                    addr3<={2'b00,(22'h290000+{5'd0,oki_address[17:1]})};
                    oki_previous<=oki_address; oki_odd<=oki_address[0];
                    req3<=~req3; oki_pending<=1; oki_started<=1; oki_valid<=0;
                end
            end else begin
                // Audio address zero must be refetched after a new ROM image.
                oki_started<=0; oki_valid<=0;
            end
            if(main_pending && ack1==req1) begin
                main_data<=dout1; main_valid<=1; main_pending<=0;
            end
            if(cop_pending && ack2==req2) begin
                cop_data<=dout2; cop_valid<=1; cop_pending<=0;
            end
            if(oki_pending && ack3==req3) begin
                oki_data<=oki_odd ? dout3[15:8] : dout3[7:0];
                oki_pending<=0; oki_valid<=!download && oki_address==oki_previous;
            end
        end
    end
endmodule
