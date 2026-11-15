// Four ROM clients on the proven shared store. Canonical byte order is
// converted at this boundary; one owned backend transaction is in flight.
module snk_union_rom_bridge #(parameter integer CLK_HZ=53600000,parameter integer CLK_MIN_HZ=CLK_HZ)(
 input wire clk,clk_shifted,init,rst,
 input wire big_sp16, // profile 19 (gwar): 256 KiB sp16 stored at 0x140000 (loader remaps), s16 word base 0xA0000
 output wire initialized,
 input wire ioctl_wr,input wire [24:0] ioctl_addr,input wire [7:0] ioctl_data,
 output wire ioctl_wait,load_idle,
 input wire bg_cs,input wire [16:0] bg_addr,output reg [31:0] bg_data,
 output wire bg_ok,output reg [16:0] bg_tag,
 input wire s16_cs,input wire [15:0] s16_addr,output wire [31:0] s16_data,
 output wire s16_ok,output wire [15:0] s16_tag,
 input wire s32_cs,input wire [16:0] s32_addr,output wire [31:0] s32_data,
 output wire s32_ok,output wire [16:0] s32_tag,
 input wire sample_cs,input wire [20:0] sample_addr,output reg [7:0] sample_data,
 output wire sample_ok,output reg [20:0] sample_tag,
 inout wire [15:0] SDRAM_DQ,output wire [12:0] SDRAM_A,
 output wire [1:0] SDRAM_BA,
 output wire SDRAM_DQML,SDRAM_DQMH,SDRAM_nCS,SDRAM_nWE,
 output wire SDRAM_nRAS,SDRAM_nCAS,SDRAM_CLK,SDRAM_CKE
);
 reg vb=0,v16=0,v32=0,vs=0;
 assign bg_ok=vb&&bg_tag==bg_addr&&bg_cs&&!rst;
 assign sample_ok=vs&&sample_tag==sample_addr&&sample_cs&&!rst;
 reg pending_write=0;reg [24:0] write_addr;reg [7:0] write_data;
 // One input stage for the download strobe/address/data: the profile-dependent loader decode
 // upstream no longer feeds the arbiter and cache controls in the same 96MHz cycle.
 // ioctl_wait covers the stage, so a second write cannot be accepted while one is in flight.
 reg in_wr=0;reg [24:0] in_addr=0;reg [7:0] in_data=0;
 wire dl_range=(in_addr>=25'h40000&&in_addr<25'h120000)||
               (in_addr>=25'h130000&&in_addr<25'h180000);
 assign ioctl_wait=!initialized||pending_write||in_wr;
 always @(posedge clk)begin
  in_wr<=ioctl_wr&&!ioctl_wait;in_addr<=ioctl_addr;in_data<=ioctl_data;
 end
 wire store_wait,store_idle;reg dl_valid=0;
 reg [23:0] addr1=0,addr2=0;reg req1=0,req2=0;
 wire ack1,ack2;wire [15:0] data1,data2;wire [31:0] pair1,pair2;
 reg busy=0,canceled=0,saw_write_busy=0;reg [2:0] owner=0,rr=0;
 reg [20:0] grant_tag=0;
 assign load_idle=initialized&&!in_wr&&!pending_write&&!(busy&&owner==4)&&store_idle;
 wire [31:0] le_pair={pair1[7:0],pair1[15:8],pair1[23:16],pair1[31:24]};
 wire [4:0] ready_w={pending_write,
   sample_cs&&!sample_ok&&!rst,s32_cs&&!s32_ok&&!rst,
   s16_cs&&!s16_ok&&!rst,bg_cs&&!bg_ok&&!rst};
 // Registered request vector (96MHz timing: cache RAM read -> tag compare -> arbiter was one cycle).
 // busy_d blocks a grant on the clock after a fetch completes, when ready still shows the pre-completion state.
 reg [4:0] ready=0;reg busy_d=0;
 always @(posedge clk)begin ready<=ready_w;busy_d<=busy; end
 reg [31:0] s16_backend_data=0,s32_backend_data=0;
 reg [15:0] s16_backend_tag=0;reg [16:0] s32_backend_tag=0;
 wire accepted_download=in_wr&&dl_range;
 wire cache_invalidate=init||rst||accepted_download;
 wire s16_backend_hit=v16&&s16_backend_tag==s16_addr;
 wire s32_backend_hit=v32&&s32_backend_tag==s32_addr;
 wire s16_cache_hit,s32_cache_hit;wire [31:0] s16_cache_data,s32_cache_data;
 assign s16_data=s16_backend_hit?s16_backend_data:s16_cache_data;
 assign s32_data=s32_backend_hit?s32_backend_data:s32_cache_data;
 assign s16_tag=s16_backend_hit?s16_backend_tag:(s16_cache_hit?s16_addr:s16_backend_tag);
 assign s32_tag=s32_backend_hit?s32_backend_tag:(s32_cache_hit?s32_addr:s32_backend_tag);
 assign s16_ok=(s16_backend_hit||s16_cache_hit)&&s16_cs&&!rst;
 assign s32_ok=(s32_backend_hit||s32_cache_hit)&&s32_cs&&!rst;
 wire cache_fill=busy&&owner!=4&&ack1==req1&&!canceled&&!rst&&!accepted_download;
 snk_immutable_word_cache #(.ADDR_WIDTH(16)) s16_cache(
  .clk(clk),.invalidate(cache_invalidate),.request(s16_cs),.read_addr(s16_addr),
  .hit(s16_cache_hit),.read_data(s16_cache_data),.fill(cache_fill&&owner==1),
  .fill_addr(grant_tag[15:0]),.fill_data(le_pair));
 snk_immutable_word_cache #(.ADDR_WIDTH(17)) s32_cache(
  .clk(clk),.invalidate(cache_invalidate),.request(s32_cs),.read_addr(s32_addr),
  .hit(s32_cache_hit),.read_data(s32_cache_data),.fill(cache_fill&&owner==2),
  .fill_addr(grant_tag[16:0]),.fill_data(le_pair));
 integer k,idx;reg found;reg [2:0] choice;
 always @* begin
  found=0;choice=0;idx=0;
  for(k=0;k<5;k=k+1)begin
   idx=rr+k;if(idx>=5)idx=idx-5;
   if(!found&&ready[idx])begin choice=idx[2:0];found=1;end
  end
 end
 snk_rom_store #(.CLK_HZ(CLK_HZ),.READ_BURST2(1),.FAST_READS(1),.CLK_MIN_HZ(CLK_MIN_HZ)) store(
  .clk(clk),.clk_shifted(clk_shifted),.init(init),.initialized(initialized),
  .dl_valid(dl_valid),.dl_word_addr(write_addr[24:1]),.dl_data(write_data),
  .dl_low_byte(write_addr[0]),.dl_wait(store_wait),.load_idle(store_idle),
  .read_addr1(addr1),.read_addr2(addr2),.read_req1(req1),.read_req2(req2),
  .read_ack1(ack1),.read_ack2(ack2),.read_data1(data1),.read_data2(data2),
  .read_pair1(pair1),.read_pair2(pair2),
  .SDRAM_DQ(SDRAM_DQ),.SDRAM_A(SDRAM_A),.SDRAM_BA(SDRAM_BA),
  .SDRAM_DQML(SDRAM_DQML),.SDRAM_DQMH(SDRAM_DQMH),.SDRAM_nCS(SDRAM_nCS),
  .SDRAM_nWE(SDRAM_nWE),.SDRAM_nRAS(SDRAM_nRAS),.SDRAM_nCAS(SDRAM_nCAS),
  .SDRAM_CLK(SDRAM_CLK),.SDRAM_CKE(SDRAM_CKE));
 always @(posedge clk)begin
  dl_valid<=0;
  if(init)begin
   vb<=0;v16<=0;v32<=0;vs<=0;busy<=0;pending_write<=0;
   req1<=0;req2<=0;rr<=0;canceled<=0;saw_write_busy<=0;
   bg_data<=0;s16_backend_data<=0;s32_backend_data<=0;sample_data<=0;
   bg_tag<=0;s16_backend_tag<=0;s32_backend_tag<=0;sample_tag<=0;
  end else begin
   if(accepted_download)begin
    pending_write<=1;write_addr<=in_addr;write_data<=in_data;
    vb<=0;v16<=0;v32<=0;vs<=0;
   end
   if(rst)begin vb<=0;v16<=0;v32<=0;vs<=0;if(busy&&owner!=4)canceled<=1;end
   if(busy)begin
    if(owner==4)begin
     if(!store_idle)saw_write_busy<=1;
     if(saw_write_busy&&store_idle)begin
      busy<=0;pending_write<=0;saw_write_busy<=0;
     end
    end else if((owner==3&&ack2==req2)||(owner!=3&&ack1==req1))begin
     busy<=0;
     if(!canceled&&!rst&&!accepted_download)case(owner)
      0:begin bg_data<=le_pair;bg_tag<=grant_tag[16:0];vb<=1;end
      1:begin s16_backend_data<=le_pair;s16_backend_tag<=grant_tag[15:0];v16<=1;end
      2:begin s32_backend_data<=le_pair;s32_backend_tag<=grant_tag[16:0];v32<=1;end
      3:begin sample_data<=grant_tag[0] ? data2[7:0] : data2[15:8];
              sample_tag<=grant_tag;vs<=1;end
      default:begin end
     endcase
    end
   end else if(initialized&&found&&!busy_d)begin
    busy<=1;owner<=choice;canceled<=0;rr<=choice==4 ? 3'd0 : choice+3'd1;
    case(choice)
     0:begin addr1<=24'h20000+{6'd0,bg_addr,1'b0};
             grant_tag<={4'd0,bg_addr};req1<=!req1;end
     1:begin addr1<=big_sp16 ? 24'hA0000+{7'd0,s16_addr[15:0],1'b0} : 24'h40000+{8'd0,s16_addr[14:0],1'b0};
             grant_tag<={5'd0,s16_addr};req1<=!req1;end
     2:begin addr1<=24'h50000+{6'd0,s32_addr,1'b0};
             grant_tag<={4'd0,s32_addr};req1<=!req1;end
     3:begin addr2<=24'h98000+{7'd0,sample_addr[17:1]};
             grant_tag<=sample_addr;req2<=!req2;end
     4:begin dl_valid<=1;saw_write_busy<=0;end
     default:begin end
    endcase
   end
  end
 end
endmodule
