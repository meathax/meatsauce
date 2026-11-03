// SPDX-License-Identifier: GPL-3.0-or-later
// Physical ROM path for the normal32MiB MiSTer module. The HPS loader and all
// running clients share one controller; caches contain immutable ROM only.
module thunderjaws_rom_memory (
 input wire clk_sys,init_reset,invalidate,
 input wire cpu_valid,
 output wire cpu_ready,
 input wire cpu_owner,
 input wire [22:0] cpu_address,
 output wire cpu_response_valid,
 output wire [15:0] cpu_response_data,
 input wire pf1_fetch,pf2_fetch,mo_fetch,
 input wire [17:0] pf1_address,pf2_address,mo_address,
 output wire [31:0] pf1_data,pf2_data,mo_data,
 output wire pf1_data_valid,pf2_data_valid,mo_data_valid,
 output wire [2:0] graphics_late,
 input wire char_wr,
 input wire [15:0] char_address,
 input wire [7:0] char_data,
 input wire [14:0] alpha_address,
 output reg [15:0] alpha_data,
 input wire oki_request,
 input wire [17:0] oki_address,
 output reg oki_ack,
 output reg [7:0] oki_data,
 input wire write_valid,
 output wire write_ready,
 input wire [23:0] write_address,
 input wire [15:0] write_data,
 output wire write_response_valid,
 output reg initialized,
 inout wire [15:0] SDRAM_DQ,
 output wire [12:0] SDRAM_A,
 output wire [1:0] SDRAM_BA,
 output wire SDRAM_DQML,SDRAM_DQMH,SDRAM_CKE,SDRAM_nCS,SDRAM_nRAS,SDRAM_nCAS,SDRAM_nWE
);
 wire [4:0] rvalid,rready,rreply;
 wire [119:0] raddress;
 wire [14:0] rlength;
 wire [15:0] rdata;
 wire creq,cready,cwe,cvalid;
 wire [23:0] ca;wire [15:0] cw,cd;wire [2:0] clen;
 thunderjaws_program_cache program_cache(.clk_sys(clk_sys),.init_reset(init_reset),.invalidate(invalidate),
  .request_valid(cpu_valid),.request_ready(cpu_ready),.request_owner(cpu_owner),.request_address(cpu_address),
  .response_valid(cpu_response_valid),.response_data(cpu_response_data),
  .memory_valid(rvalid[0]),.memory_ready(rready[0]),.memory_address(raddress[23:0]),.memory_length(rlength[2:0]),
  .memory_response_valid(rreply[0]),.memory_response_data(rdata));
 thunderjaws_graphics_cache #(.BASE_WORD(24'h090000)) pf1_cache(
  .clk_sys(clk_sys),.init_reset(init_reset),.invalidate(invalidate),.fetch(pf1_fetch && !invalidate),.address(pf1_address),
  .data(pf1_data),.data_valid(pf1_data_valid),.late(graphics_late[0]),
  .memory_valid(rvalid[1]),.memory_ready(rready[1]),.memory_address(raddress[47:24]),.memory_length(rlength[5:3]),
  .memory_response_valid(rreply[1]),.memory_response_data(rdata));
 thunderjaws_graphics_cache #(.BASE_WORD(24'h090000)) pf2_cache(
  .clk_sys(clk_sys),.init_reset(init_reset),.invalidate(invalidate),.fetch(pf2_fetch && !invalidate),.address(pf2_address),
  .data(pf2_data),.data_valid(pf2_data_valid),.late(graphics_late[1]),
  .memory_valid(rvalid[2]),.memory_ready(rready[2]),.memory_address(raddress[71:48]),.memory_length(rlength[8:6]),
  .memory_response_valid(rreply[2]),.memory_response_data(rdata));
 thunderjaws_graphics_cache #(.BASE_WORD(24'h110000)) mo_cache(
  .clk_sys(clk_sys),.init_reset(init_reset),.invalidate(invalidate),.fetch(mo_fetch && !invalidate),.address(mo_address),
  .data(mo_data),.data_valid(mo_data_valid),.late(graphics_late[2]),
  .memory_valid(rvalid[3]),.memory_ready(rready[3]),.memory_address(raddress[95:72]),.memory_length(rlength[11:9]),
  .memory_response_valid(rreply[3]),.memory_response_data(rdata));
 reg [7:0] char_hi[0:32767],char_lo[0:32767];
 always @(posedge clk_sys)begin
  alpha_data<={char_hi[alpha_address],char_lo[alpha_address]};
  if(char_wr)begin
   if(char_address[0])char_lo[char_address[15:1]]<=char_data;
   else char_hi[char_address[15:1]]<=char_data;
  end
 end
 localparam O_IDLE=0,O_ISSUE=1,O_REPLY=2,O_DROP=3;
 reg [1:0] ostate;reg [17:0] held_oki;
 assign rvalid[4]=ostate==O_ISSUE;
 assign raddress[119:96]=24'h1a0000+{7'd0,held_oki[17:1]};assign rlength[14:12]=0;
 always @(posedge clk_sys)begin
  oki_ack<=0;
  if(init_reset)begin ostate<=O_IDLE;oki_data<=0;held_oki<=0;initialized<=0;end
  else begin
   if(cready)initialized<=1;
   case(ostate)
    O_IDLE:if(oki_request && !invalidate)begin held_oki<=oki_address;ostate<=O_ISSUE;end
    O_ISSUE:if(rready[4])ostate<=O_REPLY;
    O_REPLY:if(rreply[4])begin oki_data<=held_oki[0] ? rdata[7:0] : rdata[15:8];oki_ack<=1;ostate<=O_DROP;end
    O_DROP:if(!oki_request)ostate<=O_IDLE;
   endcase
  end
 end
 thunderjaws_rom_arbiter arbiter(.clk_sys(clk_sys),.init_reset(init_reset),
  .read_valid(rvalid),.read_ready(rready),.read_address(raddress),.read_length(rlength),
  .read_response_valid(rreply),.read_response_data(rdata),
  .write_valid(write_valid),.write_ready(write_ready),.write_address(write_address),.write_data(write_data),.write_response_valid(write_response_valid),
  .controller_request(creq),.controller_ready(cready),.controller_address(ca),.controller_write_data(cw),.controller_write(cwe),
  .controller_length(clen),.controller_valid(cvalid),.controller_data(cd));
 thunderjaws_sdram controller(.clk(clk_sys),.reset(init_reset),.addr(ca),.wdata(cw),.we(cwe),.blen(clen),
  .req(creq),.rdata(cd),.valid(cvalid),.ready(cready),.rfsh_ok(1'b1),
  .SDRAM_DQ(SDRAM_DQ),.SDRAM_A(SDRAM_A),.SDRAM_BA(SDRAM_BA),.SDRAM_DQML(SDRAM_DQML),.SDRAM_DQMH(SDRAM_DQMH),
  .SDRAM_CKE(SDRAM_CKE),.SDRAM_nCS(SDRAM_nCS),.SDRAM_nRAS(SDRAM_nRAS),.SDRAM_nCAS(SDRAM_nCAS),.SDRAM_nWE(SDRAM_nWE));
endmodule
