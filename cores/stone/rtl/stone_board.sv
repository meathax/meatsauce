// SPDX-License-Identifier: GPL-3.0-or-later
// Stone Ball board. All addresses at the SDRAM boundary are 16-bit WORDS.
// 000000 CPU ROM, 040000 graphics, 240000 OKI, 280000 CPU RAM,
// 2c0000 TMS high RAM, 300000/320000 VRAM pages (byte total 0x680000).
// VRAM low bytes live in on-chip stone_vram; the SDRAM VRAM region holds only
// the high bytes that the GSP writes as nonzero.
`default_nettype none
module stone_board import tms34010_pkg::*; #(parameter bit FAST_BOOT=1'b1, parameter int BOOT_CPU_DIV=2) (
 input wire clk,reset,fabric_reset,vclk,vreset,
 input wire [1:0] game, // 0 Stone Ball, 1 Ultimate Tennis, 2 Cheese Chase
 input wire [7:0] p1,p2,p3,p4,coins,dip1,dip2,
 input wire load_req,input wire [22:0] load_addr,input wire [15:0] load_data,input wire [1:0] load_be,output wire load_ack,
 input wire nv_wr,input wire [10:0] nv_addr,input wire [7:0] nv_din,output wire [7:0] nv_dout,output reg nv_dirty,input wire nv_clear,nv_saving,
 output wire mem_req,mem_we,output wire [22:0] mem_addr,output wire [15:0] mem_din,output wire [1:0] mem_be,input wire mem_ack,input wire [15:0] mem_dout,
 output wire [23:0] rgb,output wire hs,vs,de,hblank,vblank,output wire signed [15:0] audio,
 output wire [31:0] debug_gsp_pc,output wire [23:0] debug_cpu_addr,output wire debug_illegal,debug_blit_busy);
 wire [5:0] rq,wr,ma;
 wire [22:0] adr[6];wire [15:0] wd[6];wire [1:0] be[6];wire [15:0] data;
 assign rq[0]=load_req;assign wr[0]=1;assign adr[0]=load_addr;assign wd[0]=load_data;assign be[0]=load_be;assign load_ack=ma[0];
 stone_arbiter arb(.clk(clk),.reset(fabric_reset),.req(rq),.we(wr),.addr(adr),.din(wd),.be(be),.ack(ma),.dout(data),.mem_req(mem_req),.mem_we(mem_we),.mem_addr(mem_addr),.mem_din(mem_din),.mem_be(mem_be),.mem_ack(mem_ack),.mem_dout(mem_dout));
 reg [2:0] phase;
 reg boot_fast;
 reg [6:0] audio_count;
 // Run Stone Ball's original self-tests at 50 MHz (25 MHz with divisor 4).
 // BOOT_CPU_DIV is 2 or 4; the fabric and all device clocks stay unchanged.
 // Stall the HSTCTL write
 // that releases the GSP until an entire CPU phase has finished and the
 // 12.5 MHz enable pattern is restored. All device clocks remain unchanged.
 always @(posedge clk) if(reset) begin phase<=0;boot_fast<=FAST_BOOT && game==0;audio_count<=0;end
 else begin
   phase<=phase+1'b1;audio_count<=audio_count==74 ? 7'd0:audio_count+1'b1;
   if(phase==7 && boot_release_cycle) boot_fast<=0;
 end
 wire cpu_phi1=boot_fast ? (BOOT_CPU_DIV==2 ? !phase[0]:phase[1:0]==0):phase==0;
 wire cpu_phi2=boot_fast ? (BOOT_CPU_DIV==2 ?  phase[0]:phase[1:0]==2):phase==4;
 wire asn,rwn,udsn,ldsn,fc0,fc1,fc2,hintn;
 wire [23:1] cpu_ab;wire [15:0] cpu_do;reg [15:0] cpu_di;reg dtackn;
 wire autovec=!(asn || !(fc0&&fc1&&fc2));
 assign debug_cpu_addr={cpu_ab,1'b0};
 // Ultimate Tennis IRQ5 workaround (MAME ultennis_hack_r): the input-polling
 // routine's read of 300000 raises IRQ5 for 1 us. The 68000 core exposes no PC,
 // so the polling instruction is recognised by the last program-space fetch
 // (its prefetch address: 18c2 in the World set, 18e4 in the Japan set).
 reg [23:0] fetch_addr;reg [6:0] hack_cnt;
 wire hack_irq=hack_cnt!=0;
 wire hack_pc=(fetch_addr>=24'h0018c0 && fetch_addr<=24'h0018c4) || (fetch_addr>=24'h0018e2 && fetch_addr<=24'h0018e6);
 fx68k cpu(.clk(clk),.HALTn(1'b1),.extReset(reset),.pwrUp(reset),.enPhi1(cpu_phi1),.enPhi2(cpu_phi2),
 .eRWn(rwn),.ASn(asn),.LDSn(ldsn),.UDSn(udsn),.E(),.VMAn(),.FC0(fc0),.FC1(fc1),.FC2(fc2),.BGn(),.oRESETn(),.oHALTEDn(),
 .DTACKn(dtackn),.VPAn(!autovec),.BERRn(1'b1),.BRn(1'b1),.BGACKn(1'b1),.IPL0n(!hack_irq),.IPL1n(1'b1),.IPL2n(hintn && !hack_irq),.iEdb(cpu_di),.oEdb(cpu_do),.eab(cpu_ab));
 reg [2:0] cs;
 // 68000 ROM/RAM front end: zero-wait cache with next-word prefetch and posted
 // RAM writes (see stone_cpumem.sv). Host-port writes are posted the same way.
 reg cm_rd,cm_wr,cm_touch,host_pend;reg [1:0] cm_wbe;reg [15:0] cm_wd;
 wire cm_hit,cm_idle,cm_done,cm_req,cm_we;wire [15:0] cm_hit_data,cm_rdata,cm_din;wire [22:0] cm_addr;wire [1:0] cm_be;
 wire [18:0] cm_key={|cpu_ab[23:19],cpu_ab[18:1]};
 stone_cpumem cpumem(.clk(clk),.reset(reset),.key(cm_key),.hit_now(cm_hit),.hit_data(cm_hit_data),.idle(cm_idle),
 .rd_go(cm_rd),.wr_go(cm_wr),.touch(cm_touch),.wbe(cm_wbe),.wdata(cm_wd),.done(cm_done),.rdata(cm_rdata),
 .mem_req(cm_req),.mem_we(cm_we),.mem_addr(cm_addr),.mem_din(cm_din),.mem_be(cm_be),.mem_ack(ma[3]),.mem_dout(data));
 assign rq[3]=cm_req;assign wr[3]=cm_we;assign adr[3]=cm_addr;assign wd[3]=cm_din;assign be[3]=cm_be;
 reg host_req,host_we;host_reg_sel_t host_reg;reg [1:0] host_be;reg [15:0] host_din;wire [15:0] host_dout;wire host_ack;
 reg prot_strobe,prot_in;wire prot_out;
 stone_protection prot(.clk(clk),.reset(reset),.strobe(prot_strobe),.bit_in(prot_in),.game(game),.bit_out(prot_out));
 wire [23:0] ca={cpu_ab,1'b0};
 wire boot_release_cycle=!asn && !rwn && !udsn && !autovec && ca==24'h380006 && !cpu_do[HSTCTL_HLT_BIT];
 // Memory map: Stone Ball differs from Ultimate Tennis / Cheese Chase
 // (MAME artmagic.cpp stonebal_map vs main_map).
 wire stone=game==2'd0, ultennis=game==2'd1;
 wire ram_hit=stone ? (ca>=24'h200000 && ca<24'h280000) : (ca>=24'h220000 && ca<24'h240000);
 wire eep_hit=stone ? (ca>=24'h280000 && ca<24'h281000) : (ca>=24'h240000 && ca<24'h241000);
 wire oki_hit=ca==(stone ? 24'h340000 : 24'h360000);
 wire [7:0] eeprom_cpu_data;
 wire eeprom_cpu_we=!reset && cs==0 && !asn && !autovec && !rwn && !ldsn && eep_hit;
 stone_nvram nvram(.clk(clk),.cpu_we(eeprom_cpu_we),.nv_we(nv_wr),.cpu_addr(ca[11:1]),.nv_addr(nv_addr),
 .cpu_din(cpu_do[7:0]),.nv_din(nv_din),.cpu_dout(eeprom_cpu_data),.nv_dout(nv_dout));
 reg bank,oki_wr,gsp_boot_released;reg [7:0] oki_din;wire [7:0] oki_status;
 reg nv_saving_d,nv_write_during_save;
 always @(posedge clk) begin
   prot_strobe<=0;oki_wr<=0;cm_rd<=0;cm_wr<=0;cm_touch<=0;
   if(host_pend && host_ack) begin host_req<=0;host_pend<=0;end
   if(hack_cnt!=0) hack_cnt<=hack_cnt-1'b1;
   // The EEPROM contents survive game reset, so preserve the pending-save
   // flag as well. Clear it only on initial fabric reset or after MiSTer has
   // restored the NVRAM image; any later CPU EEPROM write marks it dirty.
   nv_saving_d<=nv_saving;
   if(fabric_reset) begin nv_dirty<=0;nv_saving_d<=0;nv_write_during_save<=0;end
   else begin
     // A streamed upload is not an atomic snapshot. A CPU write after its
     // byte has been read must request another save, even if the write came
     // many clocks before the upload-complete pulse.
     if(nv_saving && !nv_saving_d) nv_write_during_save<=eeprom_cpu_we;
     else if(nv_saving && eeprom_cpu_we) nv_write_during_save<=1;
     else if(nv_clear) nv_write_during_save<=0;
     if(eeprom_cpu_we) nv_dirty<=1;
     else if(nv_wr) nv_dirty<=0;
     else if(nv_clear) nv_dirty<=nv_write_during_save;
   end
   if(reset) begin fetch_addr<=0;hack_cnt<=0;cs<=0;dtackn<=1;host_req<=0;host_pend<=0;cm_wbe<=0;cm_wd<=0;bank<=0;cpu_di<=16'hffff;host_we<=0;host_reg<=HOST_REG_HSTADRL;host_be<=0;host_din<=0;prot_in<=0;oki_din<=0;gsp_boot_released<=0;end
   else case(cs)
     0:if(!asn && (!udsn || !ldsn) && !autovec) begin
       cpu_di<=16'hffff;cs<=4;
       if(fc1 && !fc0) fetch_addr<=ca;
       if(ca<24'h080000 || ram_hit) begin
         if(rwn) begin
           if(cm_hit) begin cpu_di<=cm_hit_data;cm_touch<=1;end
           else if(cm_idle) begin cm_rd<=1;cs<=1;end
           else cs<=0;
         end else if(ca>=24'h200000) begin
           if(cm_idle) begin cm_wr<=1;cm_wbe<={!udsn,!ldsn};cm_wd<=cpu_do;end
           else cs<=0;
         end
       end else if(eep_hit) begin
          // The replicated M10K EEPROM read is registered. Its address is
          // stable during this request; capture the prefetched byte before
          // asserting DTACK on the following state.
          if(rwn) cs<=3;
       end else if(ca>=24'h300000 && ca<24'h300010) begin
         if(rwn && ca[3:1]==0 && ultennis && hack_pc) hack_cnt<=7'd100;
         if(rwn) case(ca[3:1])
           0:cpu_di<={8'hff,p1};1:cpu_di<={8'hff,p2};2:cpu_di<={8'hff,dip1};3:cpu_di<={8'hff,dip2};
           4:cpu_di<={12'hfff,coins[3:0]};5:cpu_di<={14'h3fff,1'b0,prot_out};6:if(stone)cpu_di<={8'hff,p3};7:if(stone)cpu_di<={8'hff,p4};
         endcase
         else if(ca[3:1]==0 && !cpu_do[0]) bank<=cpu_do[4];
         else if(ca[3:2]==1) begin prot_strobe<=1;prot_in<=ca[1];end
       end else if(oki_hit && !ldsn) begin
         cpu_di<={8'hff,oki_status};if(!rwn) begin
           oki_wr<=1;
           // Tennis starts its nine-second intro tune before the GSP RAM
           // tests, then requests it again when the wizard intro starts.
           // The second start is ignored if that voice is still busy. Retire
           // only the initial AC/80 command with no voices; the separate
           // 9E/10 sound-busy self-test and the real AC/82 intro pass through.
           oki_din<=ultennis && !gsp_boot_released && oki_din==8'hac && cpu_do[7:0]==8'h80
                      ? 8'h00 : cpu_do[7:0];
         end
       end else if(ca>=24'h380000 && ca<24'h380008) begin
         if(host_pend || (boot_fast && boot_release_cycle)) cs<=0;
         else begin
           host_req<=1;host_we<=!rwn;host_reg<=host_reg_sel_t'(ca[2:1]);host_be<={!udsn,!ldsn};host_din<=cpu_do;
           if(boot_release_cycle) gsp_boot_released<=1;
           if(rwn) cs<=2;else host_pend<=1;
         end
       end
     end
     1:if(cm_done) begin cpu_di<=cm_rdata;cm_touch<=1;cs<=4;end
     2:if(host_ack) begin cpu_di<=host_dout;host_req<=0;cs<=4;end
     3:begin cpu_di<={8'hff,eeprom_cpu_data};cs<=4;end
     4:begin dtackn<=0;cs<=5;end
     5:if(asn) begin dtackn<=1;cs<=0;end
     default:cs<=0;
   endcase
 end
 wire [17:0] oki_addr;wire signed [13:0] sound;wire sample;
 reg [18:0] cached_addr,pending_addr;reg [7:0] cached_data;reg cached_valid,sound_req,sound_wait;
 wire [18:0] sound_addr={bank,oki_addr};
 assign rq[2]=sound_req;assign wr[2]=0;assign adr[2]=23'h240000+{5'b0,pending_addr[18:1]};assign wd[2]=0;assign be[2]=3;
 always @(posedge clk) begin
   if(reset) begin cached_valid<=0;sound_req<=0;sound_wait<=0;cached_addr<=0;pending_addr<=0;cached_data<=0;end
   else if(!sound_wait && (!cached_valid || cached_addr!=sound_addr)) begin pending_addr<=sound_addr;sound_req<=1;sound_wait<=1;end
   else if(sound_req && ma[2]) begin cached_addr<=pending_addr;cached_data<=pending_addr[0] ? data[15:8]:data[7:0];cached_valid<=1;sound_req<=0;end
 else if(sound_wait && !sound_req) sound_wait<=0;
 end
 reg sound_reset=1'b1;
 always @(posedge clk) sound_reset<=reset;
 jt6295 #(.INTERPOL(0),.SAMPLE(1)) oki(.clk(clk),.rst(sound_reset),.cen(audio_count==0),.ss(1'b0),.wrn(!oki_wr),.din(oki_din),.dout(oki_status),.rom_addr(oki_addr),.rom_data(cached_data),.rom_ok(cached_valid && cached_addr==sound_addr),.sound(sound),.sample(sample));
 // JT6295 sums four raw 12-bit voices into 14 bits without normalization.
 // MAME normalizes each voice by 2048, so signed16 PCM needs x16 before
 // applying the board route: 0.45 Stone Ball, 0.65 Tennis, 1.0 Cheese Chase.
 // Q11 gain keeps truncation within one LSB of ideal floor-rounded PCM.
 wire signed [28:0] gain=$signed(sound)*(stone ? 29'sd14746 : (ultennis ? 29'sd21299 : 29'sd32768));
 wire signed [17:0] pcm=gain[28:11];
 assign audio=pcm>18'sd32767 ? 16'sh7fff : (pcm< -18'sd32768 ? 16'sh8000 : pcm[15:0]);
 wire g_req /*verilator public_flat_rd*/;local_cycle_kind_t g_kind /*verilator public_flat_rd*/;wire [31:0] g_addr /*verilator public_flat_rd*/;wire [15:0] g_wdata,g_io;reg [15:0] g_rdata;reg g_ack;
 wire [13:0] srf,ssrf;wire [15:0] tap,stap;wire sreq,sorg;wire org,ghs,gvs,ghb,gvb,gblank;
 tms34010_system #(.EXT_SCREEN(1'b1)) gsp(.clk(clk),.vclk_i(vclk),.rst(reset),.vclk_rst_i(vreset),.video_hsync_n_i(1'b1),.video_vsync_n_i(1'b1),.run_emu_n_i(1'b1),.emua_n_o(),
 .hcs_n_i(1'b1),.host_req_i(host_req),.host_we_i(host_we),.host_reg_i(host_reg),.host_be_i(host_be),.host_wdata_i(host_din),.host_rdata_o(host_dout),.host_ack_o(host_ack),.host_busy_o(),.hint_n_o(hintn),
 .lint1_n_i(1'b1),.lint2_n_i(1'b1),.dpyint_set_i(1'b0),.hold_req_i(1'b0),.hold_ack_o(),
 .video_hsync_o(ghs),.video_vsync_o(gvs),.video_hblank_o(ghb),.video_vblank_o(gvb),.video_blank_o(gblank),.video_hsync_oe_o(),.video_vsync_oe_o(),
 .cycle_req_o(g_req),.cycle_kind_o(g_kind),.cycle_addr_o(g_addr),.cycle_wdata_o(g_wdata),.cycle_io_rdata_o(g_io),.cycle_iaq_o(),.cycle_srfaddr_o(srf),.cycle_dpytap_o(tap),.cycle_screen_org_o(org),.cycle_dram_row_o(),.cycle_rdata_i(g_rdata),.cycle_ack_i(g_ack),.screen_req_o(sreq),.screen_srfaddr_o(ssrf),.screen_dpytap_o(stap),.screen_org_o(sorg),.screen_ext_ack_i(screen_ack),.state_o(),.pc_o(debug_gsp_pc),.instr_word_o(),.illegal_opcode_o(debug_illegal));
 reg blit_wr;wire blit_ready;wire [15:0] blit_status;
 wire blit_vwe;wire [17:0] blit_vaddr;wire [7:0] blit_vdata;
 // GSP request registered once before decode (gs 0 -> 6); the GSP holds a
 // request until acknowledged, so the registered copy stays valid.
 local_cycle_kind_t rk;reg [31:0] ra;reg [15:0] rwd;
 wire blit_req,blit_ack,blit_mem_we,blit_cache_enable;wire [22:0] blit_addr;wire [15:0] blit_data,blit_mem_data;
 stone_gfxcache gfxcache(.clk(clk),.reset(reset),.req(blit_req),.cache_enable(blit_cache_enable),.addr(blit_addr),.ack(blit_ack),.dout(blit_data),
  .mem_req(rq[5]),.mem_addr(adr[5]),.mem_ack(ma[5]),.mem_data(data));
 assign wr[5]=blit_mem_we;assign wd[5]=blit_mem_data;
 stone_blitter blit(.game(game),.clk(clk),.reset(reset),.reg_wr(blit_wr),.reg_addr(ra[6:4]),.reg_data(rwd),.reg_be(2'b11),.reg_ready(blit_ready),.status(blit_status),.req(blit_req),.we(blit_mem_we),.addr(blit_addr),.wdata(blit_mem_data),.ack(blit_ack),.rdata(blit_data),
 .vram_we(blit_vwe),.vram_addr(blit_vaddr),.vram_data(blit_vdata),.busy(debug_blit_busy),.cache_enable(blit_cache_enable));
 assign be[5]=3;
 reg pal_wr,pal_rd;wire [7:0] pal_data,pixel;wire vhs,vvs,vde,vhb,vvb;
 reg [3:0] pal_addr;reg [7:0] pal_din;
 stone_palette palette(.clk(clk),.reset(reset),.wr(pal_wr),.rd(pal_rd),.addr(pal_addr),.din(pal_din),.dout(pal_data),.vclk(vclk),.pixel(pixel),.rgb(rgb));
 reg [1:0] hs_pipe,vs_pipe,de_pipe,hb_pipe,vb_pipe;
 always @(posedge vclk) begin hs_pipe<={hs_pipe[0],vhs};vs_pipe<={vs_pipe[0],vvs};de_pipe<={de_pipe[0],vde};hb_pipe<={hb_pipe[0],vhb};vb_pipe<={vb_pipe[0],vvb};end
 assign hs=hs_pipe[1];assign vs=vs_pipe[1];assign de=de_pipe[1];assign hblank=hb_pipe[1];assign vblank=vb_pipe[1];
 wire screen_ack;wire [17:0] vb_addr;wire [7:0] vb_q;
 // Scanout no longer uses an SDRAM port.
 assign rq[1]=0;assign wr[1]=0;assign adr[1]=0;assign wd[1]=0;assign be[1]=3;
 stone_video video(.clk(clk),.reset(reset),.vclk(vclk),.vreset(vreset),.screen_req(sreq),.srfaddr(ssrf),.dpytap(stap),.org(sorg),.screen_ack(screen_ack),.hs(ghs),.vs(gvs),.hblank(ghb),.vblank(gvb),.blank(gblank),.vram_addr(vb_addr),.vram_data(vb_q),.pixel(pixel),.out_hs(vhs),.out_vs(vvs),.out_de(vde),.out_hb(vhb),.out_vb(vvb),.underrun());
  reg [4:0] gs;reg vwrite;reg gmem_req,gmem_we;reg [22:0] gmem_addr;reg [15:0] gmem_data;
 reg [8:0] shift_count;reg shift_write;reg [15:0] shift_first;
 // VRAM shift register: one M10K, single-clock simple dual port. The read
 // address is presented for one cycle and the data is used on the next
 // (gs 6->16, 2->17, 14->18); writes are registered one clock.
 // Eight lanes retain the full 512-word shift register, including high
 // bytes. Aligned zero-high-byte blocks use the parallel on-chip VRAM port;
 // unaligned transfers and SDRAM-backed high bytes keep the word path.
 reg [15:0] sr_wd;reg [8:0] sr_wa;reg sr_we;
 wire [127:0] sr_block_q;reg [2:0] sr_lane_q;
 reg sr_block_we;reg [5:0] sr_block_wa;reg [127:0] sr_block_wd;
 wire [15:0] sr_q=sr_block_q[16*sr_lane_q+:16];
 wire [8:0] sr_ra=(gs==6) ? 9'd0:shift_count;
 always @(posedge clk) sr_lane_q<=sr_ra[2:0];
 genvar sr_lane;
 generate for(sr_lane=0;sr_lane<8;sr_lane=sr_lane+1) begin:shift_bank
   (* ramstyle="M10K, no_rw_check" *) reg [15:0] mem[0:63];
   reg [15:0] q;
   always @(posedge clk) begin
     if(sr_block_we) mem[sr_block_wa]<=sr_block_wd[16*sr_lane+:16];
     else if(sr_we && sr_wa[2:0]==3'(sr_lane)) mem[sr_wa[8:3]]<=sr_wd;
     q<=mem[sr_ra[8:3]];
   end
   assign sr_block_q[16*sr_lane+:16]=q;
 end endgenerate
 wire [71:0] va_block_q,va_block_wd;
 wire [7:0] va_block_flags;
 wire sr_block_high;
 wire fast_shift_write=gs==19 && shift_write && !sr_block_high && !blit_vwe;
 genvar pack_lane;
 generate for(pack_lane=0;pack_lane<8;pack_lane=pack_lane+1) begin:shift_pack
   assign va_block_wd[9*pack_lane+:9]={1'b0,sr_block_q[16*pack_lane+:8]};
   assign va_block_flags[pack_lane]=va_block_q[9*pack_lane+8];
 end endgenerate
 assign sr_block_high=|(sr_block_q & 128'hff00ff00ff00ff00ff00ff00ff00ff00);
 always @(posedge clk) begin
   sr_we<=0;
   sr_block_we<=0;
   if(!reset && gs==22 && !(|va_block_flags)) begin
     sr_block_we<=1;sr_block_wa<=shift_count[8:3];
     for(integer lane=0;lane<8;lane=lane+1)
       sr_block_wd[16*lane+:16]<={8'd0,va_block_q[9*lane+:8]};
   end
   if(!reset && !shift_write && !shift_first[15]) begin
     if(gs==1 && ma[4]) begin sr_we<=1;sr_wa<=shift_count;sr_wd<=data;end
     else if(gs==11) begin sr_we<=1;sr_wa<=shift_count;sr_wd<=vword;end
   end
 end
 // On-chip VRAM port A: blitter pixel writes take priority for their single
 // clock; GSP accesses issue in gs 8 only when the blitter is not writing.
 reg [17:0] vidx;reg [15:0] vword,vw_data;reg [7:0] vlo;
 wire gsp_vgo=gs==8 && !blit_vwe;
 wire gsp_vwe=gsp_vgo && vwrite;
 wire [7:0] va_lo_q;wire va_hi_q;
 stone_vram vram(.clk(clk),.a_we(blit_vwe || gsp_vwe),.a_addr(blit_vwe ? blit_vaddr:vidx),.a_lo(blit_vwe ? blit_vdata:vw_data[7:0]),
 .a_hi(!blit_vwe && vw_data[15:8]!=0),.a_lo_q(va_lo_q),.a_hi_q(va_hi_q),
 .a_burst_we({8{fast_shift_write}}),.a_burst_data(va_block_wd),.a_burst_q(va_block_q),.b_addr(vb_addr),.b_q(vb_q));
 assign rq[4]=gmem_req;assign wr[4]=gmem_we;assign adr[4]=gmem_addr;assign wd[4]=gmem_data;assign be[4]=3;
 wire isvram=(ra<32'h00200000)||(ra>=32'h00400000 && ra<32'h00600000);
 wire tms_ram=stone ? ra>=32'hffc00000 : ra>=32'hffe00000;
 wire [22:0] mapped=ra>=32'hffc00000 ? 23'h2c0000+{5'd0,ra[21:4]}: 23'h300000+{5'd0,ra[22],ra[20:4]};
 always @(posedge clk) begin
   g_ack<=0;blit_wr<=0;pal_wr<=0;pal_rd<=0;
    if(reset) begin gs<=0;vwrite<=0;vidx<=0;vword<=0;vw_data<=0;vlo<=0;gmem_req<=0;gmem_we<=0;gmem_addr<=0;gmem_data<=0;g_rdata<=0;shift_count<=0;shift_write<=0;shift_first<=0;rk<=LOCAL_CYCLE_WORD_READ;ra<=0;rwd<=0;pal_addr<=0;pal_din<=0;end
    else case(gs)
      0:if(g_req) begin rk<=g_kind;ra<=g_addr;rwd<=g_wdata;gs<=6;end
      6:begin
        if(rk==LOCAL_CYCLE_SCREEN_REFRESH) begin if(screen_ack) begin g_ack<=1;gs<=4;end end
       else if(rk==LOCAL_CYCLE_IO_READ || rk==LOCAL_CYCLE_IO_WRITE) begin g_rdata<=g_io;g_ack<=1;gs<=4;end
       else if(rk==LOCAL_CYCLE_DRAM_RAS || rk==LOCAL_CYCLE_DRAM_CBR) begin g_ack<=1;gs<=4;end
       else if(ra>=32'h00800000 && ra<32'h00800080) begin
         if(rk==LOCAL_CYCLE_WORD_READ) begin g_rdata<=blit_status;g_ack<=1;gs<=4;end
         else if(blit_ready) begin blit_wr<=1;gs<=3;end
       end else if(ra>=32'h00c00000 && ra<32'h00c00100) begin
         // Present the registered address first; the read value is taken
         // in state 7, before the read side effect is applied.
         pal_addr<=ra[7:4];pal_din<=rwd[7:0];pal_wr<=rk==LOCAL_CYCLE_WORD_WRITE;pal_rd<=rk==LOCAL_CYCLE_WORD_READ;gs<=7;
       end else if(isvram) begin
         shift_count<=0;shift_write<=rk==LOCAL_CYCLE_PIXEL_RTM;
         shift_first<=((rk==LOCAL_CYCLE_PIXEL_MTR)||(rk==LOCAL_CYCLE_PIXEL_RTM)) ? 16'h0000 : 16'h8000;
         vwrite<=rk==LOCAL_CYCLE_WORD_WRITE || rk==LOCAL_CYCLE_PIXEL_RTM;
         vidx<={ra[22],ra[20:4]};
         gs<=((rk==LOCAL_CYCLE_PIXEL_MTR || rk==LOCAL_CYCLE_PIXEL_RTM) && ra[6:4]==0) ? 5'd19:5'd14;
       end else if(tms_ram) begin
         // Mark a normal word transaction in the held state.  The live GSP
         // kind may change as soon as an acknowledge returns, so gs=1 must
         // use this marker instead of re-decoding the next cycle.
         shift_count<=0;shift_write<=rk==LOCAL_CYCLE_PIXEL_RTM;
         shift_first<=((rk==LOCAL_CYCLE_PIXEL_MTR)||(rk==LOCAL_CYCLE_PIXEL_RTM)) ? 16'h0000 : 16'h8000;
         gmem_addr<=mapped;gmem_req<=rk!=LOCAL_CYCLE_PIXEL_RTM;
         gmem_we<=rk==LOCAL_CYCLE_WORD_WRITE || rk==LOCAL_CYCLE_PIXEL_RTM;
         gmem_data<=rwd;gs<=(rk==LOCAL_CYCLE_PIXEL_RTM) ? 5'd16:5'd1;
       end else begin g_rdata<=16'hffff;g_ack<=1;gs<=4;end
     end
     1:if(ma[4]) begin
       gmem_req<=0;
       if(shift_first[15]) begin
         g_rdata<=data;g_ack<=1;gs<=4;
       end else begin
         if(!shift_write) begin
           if(shift_count==0) g_rdata<=data;
         end
         if(shift_count==511) begin g_ack<=1;gs<=4;end
         else begin shift_count<=shift_count+1'b1;gmem_addr<=gmem_addr+1'b1;gs<=2;end
       end
     end
     2:gs<=17;
     16:begin gmem_req<=1;gmem_data<=sr_q;gs<=1;end
     17:begin gmem_req<=1;gmem_data<=sr_q;gs<=1;end
     // The physical VRAM shifts a whole 0x400-byte block. Serializing every
     // word delayed tennis's vblank handler by 34 lines and reloaded DPYADR
     // in the visible picture. Eight lanes keep the transfer in its blanking
     // budget without changing the display registers or the ROM.
     19:if(shift_write) begin
       if(sr_block_high) gs<=14;
       else if(!blit_vwe) begin
         if(shift_count==9'd504) gs<=24;
         else begin shift_count<=shift_count+9'd8;vidx<=vidx+18'd8;gs<=23;end
       end
     end else if(!blit_vwe) gs<=20;
     20:gs<=21;
     21:gs<=22;
     22:if(|va_block_flags) gs<=14;
     else begin
       if(shift_count==0) g_rdata<={8'd0,va_block_q[7:0]};
       if(shift_count==9'd504) gs<=24;
       else begin shift_count<=shift_count+9'd8;vidx<=vidx+18'd8;gs<=19;end
     end
     23:gs<=19; // synchronous shift-register read of the next eight words
     24:begin g_ack<=1;gs<=4;end // drain the registered VRAM/SR write
     18:begin vw_data<=shift_write ? sr_q:rwd;gs<=8;end
     // On-chip VRAM word. A nonzero high byte is written to, or read from,
     // the SDRAM copy; otherwise the high byte is zero.
     // Registered write word keeps the shift register a synchronous RAM.
     14:gs<=18;
     8:if(gsp_vgo) begin
       gmem_addr<=23'h300000+{5'd0,vidx};gmem_data<=vw_data;
       if(!vwrite) gs<=9;
       else if(vw_data[15:8]!=0) begin gmem_req<=1;gmem_we<=1;gs<=10;end
       else gs<=11;
     end
     9:gs<=15;
     15:gs<=12;
     12:begin
       vlo<=va_lo_q;vword<={8'd0,va_lo_q};
       if(va_hi_q) begin gmem_req<=1;gmem_we<=0;gs<=13;end else gs<=11;
     end
     13:if(ma[4]) begin gmem_req<=0;vword<={data[15:8],vlo};gs<=11;end
     10:if(ma[4]) begin gmem_req<=0;gs<=11;end
     11:if(shift_first[15]) begin
       g_rdata<=vword;g_ack<=1;gs<=4;
     end else begin
       if(!shift_write) begin
         if(shift_count==0) g_rdata<=vword;
       end
       if(shift_count==511) begin g_ack<=1;gs<=4;end
       else begin shift_count<=shift_count+1'b1;vidx<=vidx+1'b1;gs<=14;end
     end
     3:begin g_ack<=1;gs<=4;end
     7:begin g_rdata<={8'hff,pal_data};g_ack<=1;gs<=4;end
     4:gs<=5;
     5:gs<=0;
     default:gs<=0;
   endcase
 end
endmodule
`default_nettype wire
