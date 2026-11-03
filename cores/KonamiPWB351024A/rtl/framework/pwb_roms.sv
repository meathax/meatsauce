// SPDX-License-Identifier: GPL-3.0-or-later
// LF 48MHz JTFRAME SDRAM. SDRAM offsets are halfwords; graphics are 32-bit words.
module pwb_roms #(parameter CAPTURE_SHIFTED=0,parameter GFX_RESET_INPUT=1) (
    input wire clk,clk_sdram,reset,gfx_reset,input wire dl_wr,
    input wire [7:0] dl_data,input wire [26:0] dl_addr,
    output wire dl_wait,image_ready,load_error,
    input wire [15:0] main_addr,input wire main_req,output reg [7:0] main_data,output wire main_ok,
    input wire [16:0] f_addr,a_addr,b_addr,input wire [17:0] o_addr,
    input wire f_cs,a_cs,b_cs,o_cs,output wire [31:0] f_data,a_data,b_data,o_data,
    output wire f_ok,a_ok,b_ok,o_ok,
    input wire [14:0] sound_addr,input wire sound_req,output reg [7:0] sound_data,output reg sound_ok,
    input wire [18:0] pcm_addr,upd_addr,input wire pcm_req,upd_req,
    output wire [7:0] pcm_data,upd_data,output wire pcm_ok,upd_ok,
    inout wire [15:0] sdram_dq,output wire [12:0] sdram_a,output wire [1:0] sdram_ba,
    output wire sdram_dqml,sdram_dqmh,sdram_nwe,sdram_ncas,sdram_nras,sdram_ncs,sdram_cke
);
    wire init,prog_en,prog_wr,prog_ack,prog_rdy,accepted;
    wire [21:0] prog_addr;wire [1:0] prog_ba,prog_dsn;wire [15:0] prog_din;
    wire [24:0] accepted_bytes;
    pwb_download u_download(.clk(clk),.reset(reset),.init(init),.wr(dl_wr),.data(dl_data),.addr(dl_addr),
        .prog_ack(prog_ack),.prog_rdy(prog_rdy),.wait_hps(dl_wait),.prog_en(prog_en),
        .prog_wr(prog_wr),.prog_addr(prog_addr),.prog_ba(prog_ba),.prog_dsn(prog_dsn),
        .prog_din(prog_din),.image_ready(image_ready),.load_error(load_error),
        .accepted(accepted),.accepted_bytes(accepted_bytes));
    // One native 384-pixel line at 6MHz: 9 refresh cycles per 64us.
    reg [11:0] refresh_phase=0;
    always @(posedge clk) if(reset)refresh_phase<=0;else refresh_phase<=refresh_phase==3071?12'd0:refresh_phase+12'd1;
    wire rfsh=refresh_phase==0;
    // Exact MAME main region; fixed one-clock read fits the 6809 bus window.
    // READY is stable throughout execution, rather than extending CPU phases
    // for SDRAM cache misses. FPGA block packing still requires native fitting.
    (* ramstyle="M10K,no_rw_check" *) reg [7:0] main_rom[0:65535];
    (* ramstyle="M10K,no_rw_check" *) reg [7:0] sound_rom[0:32767];
    assign main_ok=image_ready;
    always @(posedge clk) begin
        main_data<=main_rom[main_addr];
        sound_data<=sound_rom[sound_addr];sound_ok<=sound_req&&image_ready;
        if(accepted&&dl_addr<27'h010000) main_rom[dl_addr[15:0]]<=dl_data;
        if(accepted&&dl_addr>=27'h010000&&dl_addr<27'h018000)
            sound_rom[dl_addr[14:0]]<=dl_data;
    end
    wire [21:0] bank0_addr,bank1_addr,bank2_addr,bank3_addr;
    wire [3:0] rd,ack,dst,dok,rdy;wire [15:0] read_data;
    wire cache_reset=reset||prog_en||init;

    // Game/watchdog reset cancels video clients, not the live SDRAM PHY.
    // Normal request timing remains transparent. Keep the previous client
    // tags while outstanding replies drain, then invalidate graphics only.
    wire gfx_cancel=GFX_RESET_INPUT ? gfx_reset : 1'b0;
    localparam GFX_RUN=2'd0,GFX_DRAIN=2'd1,GFX_FLUSH=2'd2,GFX_HOLD=2'd3;
    reg [1:0] gfx_state;
    reg [16:0] held_f,held_a,held_b;reg [17:0] held_o;
    reg [3:0] held_select,gfx_pending;
    wire [3:0] raw_gfx_ok;
    wire gfx_hold=gfx_cancel||(gfx_state!=GFX_RUN);
    wire gfx_clear=cache_reset||(gfx_state==GFX_FLUSH)||(gfx_state==GFX_HOLD);
    wire [16:0] cache_f=gfx_hold?held_f:f_addr;
    wire [16:0] cache_a=gfx_hold?held_a:a_addr;
    wire [16:0] cache_b=gfx_hold?held_b:b_addr;
    wire [17:0] cache_o=gfx_hold?held_o:o_addr;
    wire [3:0] cache_select=gfx_hold ?
        ((gfx_state==GFX_FLUSH||gfx_state==GFX_HOLD)?4'd0:held_select) :
        ({o_cs,b_cs,a_cs,f_cs}&{4{image_ready}});
    assign {o_ok,b_ok,a_ok,f_ok}=raw_gfx_ok&{4{!gfx_hold}};
    always @(posedge clk) begin
        if(cache_reset)begin
            gfx_state<=GFX_RUN;gfx_pending<=0;held_select<=0;
            held_f<=0;held_a<=0;held_b<=0;held_o<=0;
        end else case(gfx_state)
            GFX_RUN:begin
                if(gfx_cancel)begin gfx_state<=GFX_DRAIN;gfx_pending<=held_select;end
                else begin
                    held_f<=f_addr;held_a<=a_addr;held_b<=b_addr;held_o<=o_addr;
                    held_select<={o_cs,b_cs,a_cs,f_cs}&{4{image_ready}};
                end
            end
            GFX_DRAIN:begin
                gfx_pending<=gfx_pending&~raw_gfx_ok;
                if((gfx_pending&~raw_gfx_ok)==0)gfx_state<=GFX_FLUSH;
            end
            GFX_FLUSH:gfx_state<=GFX_HOLD;
            GFX_HOLD:if(!gfx_cancel)gfx_state<=GFX_RUN;
            default:gfx_state<=GFX_RUN;
        endcase
    end
    // Physical reads use the existing related90-degree PHY clock. The mature
    // controller consumes the sampled word on the following main48MHz edge;
    // SHIFTED0 aligns its data-start/ready bridge to this extra input stage.
    (* useioff=1 *) reg [15:0] sdram_sample;
    wire [15:0] sdram_write_data;wire sdram_write_enable;
    always @(posedge clk_sdram) sdram_sample<=sdram_dq;
    assign sdram_dq=sdram_write_enable?sdram_write_data:16'hzzzz;
    jtframe_rom_3slots #(.SDRAMW(22),.SLOT0_AW(18),.SLOT1_AW(18),.SLOT2_AW(18),
        .SLOT0_DW(32),.SLOT1_DW(32),.SLOT2_DW(32),
        .SLOT0_OFFSET(22'h010000),.SLOT1_OFFSET(22'h010000),.SLOT2_OFFSET(22'h010000),
        .SLOT0_OKLATCH(0),.SLOT1_OKLATCH(0),.SLOT2_OKLATCH(0))
    u_tiles(.clk(clk),.rst(gfx_clear),.slot0_addr({cache_a,1'b0}),.slot1_addr({cache_f,1'b0}),.slot2_addr({cache_b,1'b0}),
        .slot0_cs(cache_select[1]),.slot1_cs(cache_select[0]),.slot2_cs(1'b0),
        .slot0_dout(a_data),.slot1_dout(f_data),.slot2_dout(),.slot0_ok(raw_gfx_ok[1]),.slot1_ok(raw_gfx_ok[0]),.slot2_ok(),
        .sdram_rd(rd[0]),.sdram_addr(bank0_addr),.sdram_ack(ack[0]),.data_dst(dst[0]),.data_rdy(rdy[0]),.data_read(read_data));
    jtframe_rom_1slot #(.SDRAMW(22),.SLOT0_AW(19),.SLOT0_DW(32),.SLOT0_OFFSET(22'h090000),.SLOT0_OKLATCH(0))
    u_objects(.clk(clk),.rst(gfx_clear),.slot0_addr({cache_o,1'b0}),.slot0_cs(cache_select[3]),.slot0_dout(o_data),.slot0_ok(raw_gfx_ok[3]),
        .sdram_rd(rd[3]),.sdram_addr(bank3_addr),.sdram_ack(ack[3]),.data_dst(dst[3]),.data_rdy(rdy[3]),.data_read(read_data));
    jtframe_rom_2slots #(.SDRAMW(22),.SLOT0_AW(19),.SLOT1_AW(19),
        .SLOT0_DW(8),.SLOT1_DW(8),.SLOT0_OFFSET(22'h110000),.SLOT1_OFFSET(22'h150000),
        .SLOT0_OKLATCH(0),.SLOT1_OKLATCH(0))
    u_samples(.clk(clk),.rst(cache_reset),.slot0_addr(pcm_addr),.slot1_addr(upd_addr),
        .slot0_cs(pcm_req&&image_ready),.slot1_cs(upd_req&&image_ready),
        .slot0_dout(pcm_data),.slot1_dout(upd_data),.slot0_ok(pcm_ok),.slot1_ok(upd_ok),
        .sdram_rd(rd[2]),.sdram_addr(bank2_addr),.sdram_ack(ack[2]),.data_dst(dst[2]),.data_rdy(rdy[2]),.data_read(read_data));
    // B has the shortest global-flip sampling lead. A separate physical bank
    // lets the mature controller overlap its row operation with A/F misses.
    // The byte loader mirrors the tile region here without changing the MRA.
    jtframe_rom_1slot #(.SDRAMW(22),.SLOT0_AW(18),.SLOT0_DW(32),.SLOT0_OFFSET(22'h010000),.SLOT0_OKLATCH(0))
    u_btiles(.clk(clk),.rst(gfx_clear),.slot0_addr({cache_b,1'b0}),.slot0_cs(cache_select[2]),.slot0_dout(b_data),.slot0_ok(raw_gfx_ok[2]),
        .sdram_rd(rd[1]),.sdram_addr(bank1_addr),.sdram_ack(ack[1]),.data_dst(dst[1]),.data_rdy(rdy[1]),.data_read(read_data));
    // The common -7 module tRCD/tRP envelope is21ns: one48MHz cycle is
    // only20.833ns. The mature HF schedule adds the required idle cycle.
    pwb_sdram_controller #(.AW(22),.HF(1),.SHIFTED(CAPTURE_SHIFTED),.MISTER(1),.BA0_LEN(32),.BA1_LEN(32),.BA2_LEN(32),.BA3_LEN(32),.PROG_LEN(16),
        .BA0_WEN(0),.BA1_WEN(0),.BA2_WEN(0),.BA3_WEN(0),.BAPRIO(1))
    u_sdram(.rst(reset),.clk(clk),.init(init),.ba0_addr(bank0_addr),.ba1_addr(bank1_addr),.ba2_addr(bank2_addr),.ba3_addr(bank3_addr),
        .rd(rd),.wr(4'd0),.ba0_din(16'd0),.ba1_din(16'd0),.ba2_din(16'd0),.ba3_din(16'd0),
        .ba0_dsn(2'd3),.ba1_dsn(2'd3),.ba2_dsn(2'd3),.ba3_dsn(2'd3),.prog_en(prog_en),.prog_addr(prog_addr),.prog_rd(1'b0),.prog_wr(prog_wr),
        .prog_din(prog_din),.prog_dsn(prog_dsn),.prog_ba(prog_ba),.prog_dst(),.prog_dok(),.prog_rdy(prog_rdy),.prog_ack(prog_ack),
        .rfsh(rfsh),.ack(ack),.dst(dst),.dok(dok),.rdy(rdy),.dout(read_data),.sdram_q(sdram_sample),.sdram_din(sdram_write_data),.sdram_oe(sdram_write_enable),.sdram_a(sdram_a),.sdram_ba(sdram_ba),
        .sdram_dqml(sdram_dqml),.sdram_dqmh(sdram_dqmh),.sdram_nwe(sdram_nwe),.sdram_ncas(sdram_ncas),.sdram_nras(sdram_nras),.sdram_ncs(sdram_ncs),.sdram_cke(sdram_cke));
endmodule
