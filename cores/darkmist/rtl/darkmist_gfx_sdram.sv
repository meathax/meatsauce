// SPDX-License-Identifier: GPL-3.0-or-later
// Packed graphics service using the JTFRAME-derived burst-two controller, plus the
// post-load GFX pass. The loader stages each raw GFX byte pair as one SDRAM word
// (STAGE+g = {second-half byte, first-half byte}) at word 0x80000. After the stream
// ends, the pass reads each staged word and writes the four packed bytes it
// produces: pair data swap (prepare_roms.py DATA_SWAP), region address permutation,
// and the packed-word byte rotation (docs/packed-rom-layout.json word_order).
// All logic uses the nominal 49.152-MHz game clock. SDRAM CLK phase is supplied
// by the platform wrapper and must be qualified with its real I/O constraints.
module darkmist_gfx_sdram (
    input wire clk, clk_capture, reset,
    input wire gfx_req,
    input wire [1:0] gfx_region,
    input wire [16:0] gfx_word_addr,
    input wire [2:0] gfx_words,
    output reg gfx_ack, gfx_valid, gfx_last,
    output reg [15:0] gfx_data,
    output reg protocol_error,
    input wire loading, prog_we,
    input wire [21:0] prog_byte_addr,
    input wire [7:0] prog_data,
    input wire fix_req,
    output reg fix_done,
    output wire fix_busy,
    output wire prog_ack, prog_done, ready, download_busy,
    inout wire [15:0] SDRAM_DQ,
    output wire [12:0] SDRAM_A,
    output wire [1:0] SDRAM_BA,
    output wire SDRAM_DQML, SDRAM_DQMH,
    output wire SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS, SDRAM_CKE
);
    localparam [2:0] IDLE=0, ISSUE=1, WAIT_DATA=2, EMIT_LOW=3, EMIT_HIGH=4;
    // FX_CLR writes zero to an unused scratch word before each read and at the end.
    // It releases the shared data bus: the donor controller keeps the last write
    // byte on DQ in simulation, which would otherwise be ORed into the next read.
    localparam [2:0] FX_IDLE=0, FX_RD=1, FX_RDW=2, FX_WR=3, FX_CLR=4;
    localparam [21:0] STAGE_WORD=22'h80000, CLEAR_WORD=22'h7fffe;
    reg [2:0] state, remaining;
    reg [21:0] address;
    reg [31:0] pair_data;
    reg download_mode, prog_inflight;
    reg [12:0] powerup_hold;
    wire controller_reset=reset || powerup_hold!=0;
    wire loop_reset, sd_ack, sd_data_valid;
    wire [31:0] sd_data;
    reg [8:0] refresh_age;
    wire refresh_due=refresh_age>=9'd340;
    wire refresh_command=!SDRAM_nCS && !SDRAM_nRAS && !SDRAM_nCAS && SDRAM_nWE;
    // Post-load pass state: one read returns two staged pairs (g, g+1); each pair
    // yields two packed bytes, so four byte writes follow every read.
    reg [2:0] fx_state;
    reg [18:0] fx_g;      // staged pair index, 0 to 0x41ffe (needs 19 bits)
    reg [31:0] fx_pair;
    reg [1:0] fx_k;
    reg fx_acc,fx_fin;
    wire fx_prog=fx_state==FX_WR || fx_state==FX_CLR;
    wire fx_rd_go=fx_state==FX_RD && !refresh_due && ready;
    wire fx_wr_go=fx_prog && !fx_acc && !refresh_due && ready;
    wire read_request=(state==ISSUE && !download_mode && !refresh_due && ready) || fx_rd_go;
    wire program_request=(loading && download_mode && prog_we && !refresh_due && ready) || fx_wr_go;
    assign ready=!controller_reset && !loop_reset;
    assign download_busy=download_mode || prog_inflight;
    assign prog_ack=download_mode && sd_ack;
    assign prog_done=download_mode && sd_data_valid;
    assign fix_busy=fx_state!=FX_IDLE;

    function automatic [21:0] region_base(input [1:0] region);
        case(region)
            0: region_base=22'h10000; // TX: image byte offset 0x20000
            1: region_base=22'h22000; // BG: image byte offset 0x44000
            2: region_base=22'h12000; // FG: image byte offset 0x24000
            3: region_base=22'h32000; // sprites: image byte offset 0x64000
        endcase
    endfunction

    // Inverse address permutations (see rtl/darkmist_storage.sv for maps),
    // combined with the packed-word rotation: packed byte = rotl1(decoded index).
    function automatic [13:0] pk_tex(input [13:0] x); begin
        pk_tex = 0;
        pk_tex[5] = x[0];
        pk_tex[6] = x[1];
        pk_tex[7] = x[2];
        pk_tex[8] = x[3];
        pk_tex[1] = x[4];
        pk_tex[9] = x[5];
        pk_tex[10] = x[6];
        pk_tex[11] = x[7];
        pk_tex[12] = x[8];
        pk_tex[2] = x[9];
        pk_tex[3] = x[10];
        pk_tex[4] = x[11];
        pk_tex[13] = x[12];
        pk_tex[0] = x[13];
    end endfunction
    function automatic [16:0] pk_tile(input [16:0] x); begin
        pk_tile = 0;
        pk_tile[7] = x[0];
        pk_tile[8] = x[1];
        pk_tile[1] = x[2];
        pk_tile[2] = x[3];
        pk_tile[9] = x[4];
        pk_tile[10] = x[5];
        pk_tile[11] = x[6];
        pk_tile[12] = x[7];
        pk_tile[13] = x[8];
        pk_tile[3] = x[9];
        pk_tile[4] = x[10];
        pk_tile[5] = x[11];
        pk_tile[6] = x[12];
        pk_tile[14] = x[13];
        pk_tile[15] = x[14];
        pk_tile[16] = x[15];
        pk_tile[0] = x[16];
    end endfunction
    function automatic [17:0] pk_spr(input [17:0] x); begin
        pk_spr = 0;
        pk_spr[3] = x[0];
        pk_spr[1] = x[1];
        pk_spr[2] = x[2];
        pk_spr[7] = x[3];
        pk_spr[8] = x[4];
        pk_spr[14] = x[5];
        pk_spr[4] = x[6];
        pk_spr[5] = x[7];
        pk_spr[6] = x[8];
        pk_spr[9] = x[9];
        pk_spr[10] = x[10];
        pk_spr[11] = x[11];
        pk_spr[12] = x[12];
        pk_spr[13] = x[13];
        pk_spr[15] = x[14];
        pk_spr[16] = x[15];
        pk_spr[17] = x[16];
        pk_spr[0] = x[17];
    end endfunction
    // DATA_SWAP = (9,14,7,2,6,8,3,15,10,13,5,12,0,11,4,1): out[15-k] = in[DATA_SWAP[k]]
    function automatic [15:0] ds16(input [15:0] a); begin
        ds16[15]=a[9];  ds16[14]=a[14]; ds16[13]=a[7];  ds16[12]=a[2];
        ds16[11]=a[6];  ds16[10]=a[8];  ds16[9]=a[3];   ds16[8]=a[15];
        ds16[7]=a[10];  ds16[6]=a[13];  ds16[5]=a[5];   ds16[4]=a[12];
        ds16[3]=a[0];   ds16[2]=a[11];  ds16[1]=a[4];   ds16[0]=a[1];
    end endfunction

    // ---- post-load pass: addressing and data for the four writes of one read ----
    wire [1:0] fx_reg = fx_g<19'h02000 ? 2'd0 : fx_g<19'h12000 ? 2'd1 : fx_g<19'h22000 ? 2'd2 : 2'd3;
    wire [18:0] fx_pbase = fx_reg==2'd0 ? 19'h00000 : fx_reg==2'd1 ? 19'h02000 : fx_reg==2'd2 ? 19'h12000 : 19'h22000;
    wire [18:0] fx_m = fx_g-fx_pbase+{18'd0,fx_k[1]};  // pair index inside its region
    reg [17:0] fx_pb;                                   // packed byte index inside region
    reg [21:0] fx_fbw;                                  // packed region word base
    always @(*) begin
        case(fx_reg)
            2'd0: begin fx_pb={4'd0,pk_tex({fx_k[0],fx_m[12:0]})}; fx_fbw=22'h10000; end
            2'd1: begin fx_pb={1'd0,pk_tile({fx_k[0],fx_m[15:0]})}; fx_fbw=22'h12000; end
            2'd2: begin fx_pb={1'd0,pk_tile({fx_k[0],fx_m[15:0]})}; fx_fbw=22'h22000; end
            default: begin fx_pb={pk_spr({fx_k[0],fx_m[16:0]})}; fx_fbw=22'h32000; end
        endcase
    end
    wire [21:0] fx_wr_word=fx_fbw+{5'd0,fx_pb[17:1]};
    wire [1:0] fx_mask=fx_state==FX_CLR ? 2'b00 : fx_pb[0] ? 2'b01 : 2'b10;
    wire [15:0] fx_w=fx_k[1] ? fx_pair[31:16] : fx_pair[15:0];
    wire [15:0] fx_wd=ds16({fx_w[7:0],fx_w[15:8]});
    // Spr pairs m in [0x18000,0x20000) are the audited zero gap in both halves.
    wire fx_gap=fx_reg==2'd3 && fx_m[16] && fx_m[15];
    wire [7:0] fx_val=(fx_gap || fx_state==FX_CLR) ? 8'd0 : (fx_k[0] ? fx_wd[7:0] : fx_wd[15:8]);

    always @(posedge clk) begin
        if(reset) powerup_hold<=13'd5000;
        else if(powerup_hold!=0) powerup_hold<=powerup_hold-13'd1;
        // The donor waits a further 5000 clocks: total startup >200 us at
        // 49.152 MHz. No game-ROM requests are admitted during that interval.
        if(!ready) refresh_age<=0;
        else if(refresh_command) refresh_age<=0;
        else if(refresh_age!=9'h1ff) refresh_age<=refresh_age+9'd1;
    end

    always @(posedge clk) begin
        gfx_ack<=0;gfx_valid<=0;gfx_last<=0;
        if(controller_reset || loop_reset) begin
            state<=IDLE;remaining<=0;address<=0;pair_data<=0;gfx_data<=0;
            protocol_error<=0;download_mode<=0;prog_inflight<=0;
        end else begin
            // Drain a previously accepted row before handing the physical
            // controller to the loader. Ack always belongs to that owner.
            if(loading && state==IDLE && !sd_ack && !sd_data_valid)
                download_mode<=1;
            if(download_mode && sd_ack) prog_inflight<=1;
            if(download_mode && sd_data_valid) prog_inflight<=0;
            if(download_mode && !loading && !prog_inflight && !sd_ack && !sd_data_valid)
                download_mode<=0;
            case(state)
                IDLE: if(gfx_req && !loading && !download_mode && fx_state==FX_IDLE && (fix_done || !fix_req)) begin
                    gfx_ack<=1;
                    if((gfx_words!=2 && gfx_words!=4) || gfx_word_addr[0])
                        protocol_error<=1;
                    else begin
                        remaining<=gfx_words;
                        address<=region_base(gfx_region)+{5'd0,gfx_word_addr};
                        state<=ISSUE;
                    end
                end
                ISSUE: if(sd_ack) state<=WAIT_DATA;
                WAIT_DATA: if(sd_data_valid) begin pair_data<=sd_data;state<=EMIT_LOW;end
                EMIT_LOW: begin
                    gfx_data<=pair_data[15:0];gfx_valid<=1;
                    remaining<=remaining-3'd1;state<=EMIT_HIGH;
                end
                EMIT_HIGH: begin
                    gfx_data<=pair_data[31:16];gfx_valid<=1;
                    gfx_last<=remaining==1;
                    remaining<=remaining-3'd1;address<=address+22'd2;
                    state<=remaining==1 ? IDLE : ISSUE;
                end
                default: begin protocol_error<=1;state<=IDLE;end
            endcase
        end
    end

    // Post-load pass controller. It runs only while the game is held in reset
    // (the storage keeps loaded low), and it owns the SDRAM controller meanwhile.
    always @(posedge clk) begin
        if(controller_reset || loop_reset) begin
            fx_state<=FX_IDLE;fx_g<=0;fx_pair<=0;fx_k<=0;fx_acc<=0;fx_fin<=0;fix_done<=0;
        end else begin
            if(!fix_req && fx_state==FX_IDLE) fix_done<=0;
            case(fx_state)
                FX_IDLE: if(fix_req && !fix_done && state==IDLE && !loading && !download_busy) begin
                    fx_g<=0;fx_k<=0;fx_acc<=0;fx_fin<=0;fx_state<=FX_CLR;
                end
                FX_CLR: begin
                    if(sd_ack) fx_acc<=1;
                    if(fx_acc && sd_data_valid) begin
                        fx_acc<=0;
                        if(fx_fin) begin fx_state<=FX_IDLE;fix_done<=1;end
                        else fx_state<=FX_RD;
                    end
                end
                FX_RD: if(sd_ack) fx_state<=FX_RDW;
                FX_RDW: if(sd_data_valid) begin
                    fx_pair<=sd_data;fx_k<=0;fx_acc<=0;fx_state<=FX_WR;
                end
                FX_WR: begin
                    if(sd_ack) fx_acc<=1;
                    if(fx_acc && sd_data_valid) begin
                        fx_acc<=0;
                        if(fx_k==2'd3) begin
                            if(fx_g==19'h41ffe) fx_fin<=1;
                            else fx_g<=fx_g+19'd2;
                            fx_state<=FX_CLR;
                        end else fx_k<=fx_k+2'd1;
                    end
                end
                default: fx_state<=FX_IDLE;
            endcase
        end
    end

    darkmist_sdram_controller memory (
        .rst(controller_reset),.clk(clk),.clk_capture(clk_capture),.loop_rst(loop_reset),
        .read_req(read_request),.data_read(sd_data),
        .sdram_addr(fx_state==FX_RD ? STAGE_WORD+{3'd0,fx_g} : address),
        .sdram_bank(2'd0),
        .data_rdy(sd_data_valid),.sdram_ack(sd_ack),.refresh_en(refresh_due),
        .sdram_wrmask(2'b11),.sdram_rnw(1'b1),.data_write(16'd0),
        .downloading(download_mode || fx_prog),
        .prog_we(program_request),.prog_rd(1'b0),
        .prog_addr(fx_state==FX_WR ? fx_wr_word : fx_prog ? CLEAR_WORD : {1'b0,prog_byte_addr[21:1]}),
        .prog_data(fx_prog ? fx_val : prog_data),
        .prog_mask(fx_prog ? fx_mask : (prog_byte_addr[0] ? 2'b01 : 2'b10)),
        .prog_bank(2'd0),
        .SDRAM_DQ(SDRAM_DQ),.SDRAM_A(SDRAM_A),.SDRAM_BA(SDRAM_BA),
        .SDRAM_DQML(SDRAM_DQML),.SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_nWE(SDRAM_nWE),.SDRAM_nCAS(SDRAM_nCAS),.SDRAM_nRAS(SDRAM_nRAS),
        .SDRAM_nCS(SDRAM_nCS),.SDRAM_CKE(SDRAM_CKE)
    );
endmodule
