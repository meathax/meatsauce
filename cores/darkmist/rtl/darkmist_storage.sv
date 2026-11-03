// SPDX-License-Identifier: GPL-3.0-or-later
// Shared synthesis/simulation storage. The loader accepts the raw MAME part
// bytes in MRA stream order (scripts/prepare_storage_mra.py) and applies the
// audited init_darkmist transforms in hardware, so the stored contents equal the
// packed image byte for byte:
//   maincpu 0x0000-0x7fff  datum -> program_rom, opcode -> opcode_rom
//   maincpu 0x8000-0xffff  raw banked bytes -> program_rom[0x8000-0xffff]
//   t5182 external         bitswap8(7,1,2,3,4,5,6,0) -> sound_ext
//   t5182.rom              raw -> sound_int
//   bg/fg maps             inverse address permutation; interleaved parts
//                          (offset 0 = low byte, offset 1 = high byte)
//   CLUT                   raw -> video CLUT bytes
//   tx/bg/fg/sprite GFX    raw bytes staged in SDRAM as byte pairs (word
//                          STAGE+g = {second-half byte, first-half byte}); the
//                          pair data swap and packed-word address permutation
//                          run in a post-load pass (darkmist_gfx_sdram).
module darkmist_storage (
    input wire clk,clk_capture,reset,download,prog_we,
    input wire [19:0] prog_addr,
    input wire [7:0] prog_data,
    output wire prog_wait,ready,
    output reg loaded,load_error,
    input wire main_req,main_opcode,
    input wire [16:0] main_addr,
    output reg main_valid,
    output reg [7:0] main_data,
    input wire sound_req,sound_external,
    input wire [14:0] sound_addr,
    output reg sound_valid,
    output reg [7:0] sound_data,
    input wire map_req,map_fg,
    input wire [14:0] map_addr,
    output reg map_valid,
    output reg [15:0] map_data,
    input wire gfx_req,
    input wire [1:0] gfx_region,
    input wire [16:0] gfx_addr,
    input wire [2:0] gfx_words,
    output wire gfx_ack,gfx_valid,gfx_last,gfx_error,
    output wire [15:0] gfx_data,
    output reg clut_we,
    output reg [1:0] clut_owner,
    output reg [7:0] clut_addr,clut_data,
    inout wire [15:0] SDRAM_DQ,
    output wire [12:0] SDRAM_A,
    output wire [1:0] SDRAM_BA,
    output wire SDRAM_DQML,SDRAM_DQMH,SDRAM_nWE,SDRAM_nCAS,SDRAM_nRAS,SDRAM_nCS,SDRAM_CKE
);
    localparam [19:0] STREAM_END=20'ha6600;
    (* ramstyle="M10K" *) reg [7:0] program_rom[0:65535];
    (* ramstyle="M10K" *) reg [7:0] opcode_rom[0:32767];
    (* ramstyle="M10K" *) reg [7:0] sound_int[0:8191];
    (* ramstyle="M10K" *) reg [7:0] sound_ext[0:32767];
    (* ramstyle="M10K" *) reg [7:0] bg_map_lo[0:32767];
    (* ramstyle="M10K" *) reg [7:0] bg_map_hi[0:32767];
    (* ramstyle="M10K" *) reg [7:0] fg_map_lo[0:16383];
    (* ramstyle="M10K" *) reg [7:0] fg_map_hi[0:16383];
    reg download_q,download_seen,pending,accepted;
    reg [19:0] next_addr;
    reg [21:0] pending_addr;
    reg [7:0] pending_data;
    wire sd_ack,sd_done,sd_busy,fix_req,fix_done,fix_busy;
    wire take_byte=download && prog_we && !prog_wait;
    assign prog_wait=!ready || pending || fix_busy;
    // The post-load GFX pass starts only after the whole stream has been accepted
    // and every staged SDRAM write has completed.
    assign fix_req=download_seen && !download && !pending && !sd_busy && next_addr==STREAM_END && !load_error;

    // ---- raw stream decode (MRA order) ----
    function automatic [15:0] main_xform(input [14:0] i, input [7:0] d); // {datum, opcode}
        reg [7:0] op,dt;
        begin
            op=d; dt=d;
            if(!i[5] && i[3]) op=op^8'h20;
            if(!i[5] && (i[3]|i[1])) dt=dt^8'h20;
            if(i[9] && (i[10]|i[3])) op=op^8'h10;
            if(!(i[9] && !i[5])) begin
                op={op[7],op[6],op[5],op[2],op[3],op[4],op[1],op[0]};
                dt={dt[7],dt[6],dt[5],dt[2],dt[3],dt[4],dt[1],dt[0]};
            end
            main_xform={dt,op};
        end
    endfunction
    function automatic [7:0] bs_ext(input [7:0] x);
        bs_ext={x[7],x[1],x[2],x[3],x[4],x[5],x[6],x[0]};
    endfunction
    // Inverse of bitswap(i, BG_MAP_ADDR) and bitswap(i, FG_MAP_ADDR), generated from prepare_roms.py.
    function automatic [15:0] pinv_bg(input [15:0] p); begin
        pinv_bg = 0;
        pinv_bg[0] = p[0];
        pinv_bg[10] = p[1];
        pinv_bg[11] = p[2];
        pinv_bg[1] = p[3];
        pinv_bg[2] = p[4];
        pinv_bg[8] = p[5];
        pinv_bg[9] = p[6];
        pinv_bg[12] = p[7];
        pinv_bg[13] = p[8];
        pinv_bg[14] = p[9];
        pinv_bg[15] = p[10];
        pinv_bg[3] = p[11];
        pinv_bg[4] = p[12];
        pinv_bg[5] = p[13];
        pinv_bg[6] = p[14];
        pinv_bg[7] = p[15];
    end endfunction
    function automatic [14:0] pinv_fg(input [14:0] p); begin
        pinv_fg = 0;
        pinv_fg[0] = p[0];
        pinv_fg[7] = p[1];
        pinv_fg[8] = p[2];
        pinv_fg[1] = p[3];
        pinv_fg[2] = p[4];
        pinv_fg[13] = p[5];
        pinv_fg[14] = p[6];
        pinv_fg[9] = p[7];
        pinv_fg[10] = p[8];
        pinv_fg[11] = p[9];
        pinv_fg[12] = p[10];
        pinv_fg[3] = p[11];
        pinv_fg[4] = p[12];
        pinv_fg[5] = p[13];
        pinv_fg[6] = p[14];
    end endfunction

    wire [19:0] s=prog_addr;
    wire main_lo=s<20'h08000;                          // maincpu bank 0 (dm_15)
    wire main_hi=s>=20'h08000 && s<20'h10000;          // maincpu bank 1 (dm_16)
    wire ext_in=s>=20'h10000 && s<20'h18000;           // t5182 external (dm_17)
    wire int_in=s>=20'h18000 && s<20'h1a000;           // t5182 CPU ROM (t5182.rom)
    wire gfx_in=s>=20'h1a000 && s<20'h8e000;           // tx/bg/fg/sprite pairs
    wire bgmap_in=s>=20'h8e000 && s<20'h9e000;         // dm_03/dm_04 interleaved
    wire fgmap_in=s>=20'h9e000 && s<20'ha6000;         // dm_07/dm_08 interleaved
    wire clut_in=s>=20'ha6000 && s<20'ha6400;          // four 256-byte CLUTs
    wire [15:0] main_xf=main_xform(s[14:0],prog_data);
    wire [19:0] bgm=s-20'h8e000, fgm=s-20'h9e000;
    wire [15:0] bg_slot=pinv_bg({bgm[14:0],bgm[15]});  // part offset bit = high/low byte
    wire [14:0] fg_slot=pinv_fg({fgm[13:0],fgm[14]});
    // GFX staging: pair index g = region pair base + m; lane 0 = first-half byte.
    wire [19:0] t_off=s-20'h1a000, b_off=s-20'h1e000, f_off=s-20'h3e000, p_off=s-20'h5e000;
    wire spr_b=p_off>=20'h18000;
    wire [19:0] p_m=spr_b ? p_off-20'h18000 : p_off;
    wire [17:0] stage_g = s<20'h1e000 ? {5'd0,t_off[12:0]} :
                          s<20'h3e000 ? 18'h12000+{2'd0,b_off[15:0]} :
                          s<20'h5e000 ? 18'h02000+{2'd0,f_off[15:0]} :
                                        18'h22000+{1'd0,p_m[16:0]};
    wire stage_lane = s<20'h1e000 ? t_off[13] : s<20'h3e000 ? b_off[16] : s<20'h5e000 ? f_off[16] : spr_b;
    wire [21:0] stage_addr=22'h100000+{3'd0,stage_g,stage_lane};

    // ---- RAM read ports (B2): every read is unconditional into its own register;
    // the lane select is registered alongside and applied after the registers.
    reg [7:0] main_prog_q,main_op_q,sound_int_q,sound_ext_q;
    reg [15:0] bg_map_q,fg_map_q;
    reg main_op_sel,sound_ext_sel,map_fg_sel;
    always @(posedge clk) begin
        main_prog_q<=program_rom[{main_addr[16],main_addr[14:0]}];
        main_op_q<=opcode_rom[main_addr[14:0]];
        main_op_sel<=main_opcode && !main_addr[16];
        sound_int_q<=sound_int[sound_addr[12:0]];
        sound_ext_q<=sound_ext[sound_addr];
        sound_ext_sel<=sound_external;
        bg_map_q<={bg_map_hi[map_addr],bg_map_lo[map_addr]};
        fg_map_q<={fg_map_hi[map_addr[13:0]],fg_map_lo[map_addr[13:0]]};
        map_fg_sel<=map_fg;
    end
    always @(*) begin
        main_data=main_op_sel ? main_op_q : main_prog_q;
        sound_data=sound_ext_sel ? sound_ext_q : sound_int_q;
        map_data=map_fg_sel ? fg_map_q : bg_map_q;
    end
    always @(posedge clk) begin
        main_valid<=main_req && loaded && !reset;
        sound_valid<=sound_req && loaded && !reset;
        map_valid<=map_req && loaded && !reset;
    end

    // ---- RAM write ports: transformed on write, one byte per accepted stream byte ----
    // Quartus 17 infers M10K only with ONE write address per array and full-word
    // writes: program_rom gets a single muxed write port, and the 16-bit maps are
    // stored as separate low/high byte arrays (no part-select writes).
    wire wr_ok=take_byte && !reset;
    wire [15:0] prog_wa=main_hi ? s[15:0] : {1'b0,s[14:0]};
    wire [7:0]  prog_wd=main_hi ? prog_data : main_xf[15:8];
    always @(posedge clk) if(wr_ok && (main_lo || main_hi)) program_rom[prog_wa]<=prog_wd;
    always @(posedge clk) if(wr_ok && main_lo) opcode_rom[s[14:0]]<=main_xf[7:0];
    always @(posedge clk) if(wr_ok && ext_in) sound_ext[s[14:0]]<=bs_ext(prog_data);
    always @(posedge clk) if(wr_ok && int_in) sound_int[s[12:0]]<=prog_data;
    always @(posedge clk) if(wr_ok && bgmap_in &&  bg_slot[0]) bg_map_hi[bg_slot[15:1]]<=prog_data;
    always @(posedge clk) if(wr_ok && bgmap_in && !bg_slot[0]) bg_map_lo[bg_slot[15:1]]<=prog_data;
    always @(posedge clk) if(wr_ok && fgmap_in &&  fg_slot[0]) fg_map_hi[fg_slot[14:1]]<=prog_data;
    always @(posedge clk) if(wr_ok && fgmap_in && !fg_slot[0]) fg_map_lo[fg_slot[14:1]]<=prog_data;

    always @(posedge clk) begin
        clut_we<=0;
        download_q<=download;
        if(reset) begin
            download_q<=0;download_seen<=0;pending<=0;accepted<=0;
            next_addr<=0;pending_addr<=0;pending_data<=0;loaded<=0;load_error<=0;
            clut_owner<=0;clut_addr<=0;clut_data<=0;
        end else begin
            if(download && !download_q) begin
                loaded<=0;load_error<=0;next_addr<=0;download_seen<=1;
            end
            if(pending && sd_ack) accepted<=1;
            // Keep byte address/data stable through the physical WRITE command,
            // not just acceptance. This also drains the final byte on download end.
            if(pending && sd_done) begin pending<=0;accepted<=0;end
            if(download_seen && !download && !pending && !sd_busy)
                loaded<=fix_done && next_addr==STREAM_END && !load_error;
            if(take_byte) begin
                if(prog_addr!=next_addr) load_error<=1;
                next_addr<=next_addr+20'd1;
                if(gfx_in) begin
                    pending<=1;accepted<=0;pending_addr<=stage_addr;pending_data<=prog_data;
                end
                if(clut_in) begin
                    clut_we<=1;clut_owner<=prog_addr[9:8];clut_addr<=prog_addr[7:0];clut_data<=prog_data;
                end
                // The audited unused program gap, PROM bytes and the t5182 padding are
                // accepted in sequence but not assigned hardware roles.
            end
        end
    end
    darkmist_gfx_sdram graphics (
        .clk(clk),.clk_capture(clk_capture),.reset(reset),.gfx_req(gfx_req),.gfx_region(gfx_region),
        .gfx_word_addr(gfx_addr),.gfx_words(gfx_words),.gfx_ack(gfx_ack),
        .gfx_valid(gfx_valid),.gfx_last(gfx_last),.gfx_data(gfx_data),.protocol_error(gfx_error),
        .loading(download || pending),.prog_we(pending && !accepted),
        .prog_byte_addr(pending_addr),.prog_data(pending_data),.prog_ack(sd_ack),.prog_done(sd_done),
        .fix_req(fix_req),.fix_done(fix_done),.fix_busy(fix_busy),
        .ready(ready),.download_busy(sd_busy),.SDRAM_DQ(SDRAM_DQ),.SDRAM_A(SDRAM_A),
        .SDRAM_BA(SDRAM_BA),.SDRAM_DQML(SDRAM_DQML),.SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_nWE(SDRAM_nWE),.SDRAM_nCAS(SDRAM_nCAS),.SDRAM_nRAS(SDRAM_nRAS),
        .SDRAM_nCS(SDRAM_nCS),.SDRAM_CKE(SDRAM_CKE)
    );
endmodule
