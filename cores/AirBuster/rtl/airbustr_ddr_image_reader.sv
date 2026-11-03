// SPDX-License-Identifier: GPL-3.0-or-later
// Main MRA fast header -> the unchanged Heavy Unit sequential word loader.
// The staged M92 ddr_download_adaptor by Martin Donlon (GPL-2.0-or-later,
// donors/irem_m92/rtl/rom.sv) supplies the fixed-base/single64-bit-read model.
// This adaptation adds WIDE words, full index decode, captured-start length,
// generation drain and explicit ownership. Original donor remains pristine.
module airbustr_ddr_image_reader #(
 parameter logic [31:0] DDR_BASE=32'h30000000,
 parameter logic [26:0] IMAGE_BYTES=27'h2c1000
)(
 input logic clk,reset,
 input logic host_download,host_wr,
 input logic [15:0] host_index,host_dout,
 input logic [26:0] host_addr,
 output wire host_wait,
 output wire loader_download,loader_wr,
 output wire [15:0] loader_index,loader_dout,
 output wire [26:0] loader_addr,
 input logic loader_wait,loader_initialized,loader_rom_loaded,loader_drained,loader_transfer_active,
 input logic [2:0] loader_error,
 output wire load_claim,rotation_pause,fast_selected,copy_active,reader_drained,image_valid,
 output logic copy_done=0,protocol_error=0,
 output logic [3:0] error_code=0,
 output logic [26:0] copied_bytes=0,
 input logic ddr_grant,ddr_busy,ddr_data_ready,
 input logic [63:0] ddr_data,
 output wire [28:0] ddr_addr,
 output wire [7:0] ddr_burstcnt,
 output wire ddr_rd
);
 typedef enum logic [3:0] {IDLE,NORMAL,NORMAL_DRAIN,FAST_HOST,FAST_GRANT,READ_REQ,READ_WAIT,WORDS,FINAL_DRAIN,ABORT_WAIT,ABORT_DRAIN,BAD_BEGIN} state_t;
 state_t state=IDLE;
 logic last_download=0,reset_pending=0;
 logic [63:0] buffer=0;
 logic [1:0] lane=0;
 logic [15:0] normal_data[0:1];logic [26:0] normal_addr[0:1];
 logic normal_head=0,normal_tail=0;logic [1:0] normal_count=0;
 wire selected=host_index==16'd0;
 wire start=host_download&&!last_download&&selected;
 wire fast=state>=FAST_HOST;
 wire normal=state==NORMAL;
 wire normal_operating=state==NORMAL||state==NORMAL_DRAIN;
 wire normal_push=normal_operating&&host_download&&selected&&host_wr&&!reset&&!reset_pending;
 wire normal_pop=normal_operating&&normal_count!=0&&!loader_wait&&!reset&&!reset_pending;
 wire word_accept=state==WORDS&&!loader_wait&&!reset&&!reset_pending;
 assign fast_selected=fast;
 assign copy_active=state!=IDLE;
 assign reader_drained=state==IDLE;
 // Retire frontend ownership as well as the actual final storage response.
 assign image_valid=loader_rom_loaded&&state==IDLE&&!protocol_error&&!reset&&!reset_pending;
 assign load_claim=fast;
 assign rotation_pause=load_claim;
 assign host_wait=normal_operating?(loader_wait||normal_count!=0):(fast&&state!=FAST_HOST);
 assign loader_download=(normal&&(host_download||normal_count!=0)) ||
                         (state==NORMAL_DRAIN&&normal_count!=0) ||
                         (fast&&state!=FINAL_DRAIN&&state!=ABORT_WAIT&&state!=ABORT_DRAIN);
 assign loader_wr=normal_pop || word_accept;
 assign loader_index=16'd0;
 assign loader_addr=normal_operating?normal_addr[normal_head]:copied_bytes;
 assign loader_dout=normal_operating?normal_data[normal_head]:buffer[{lane,4'b0000}+:16];
 assign ddr_addr=DDR_BASE[31:3]+{5'd0,copied_bytes[26:3]};
 assign ddr_burstcnt=8'd1;
 assign ddr_rd=state==READ_REQ&&ddr_grant&&!reset&&!reset_pending;

 always_ff @(posedge clk)begin
  copy_done<=0;last_download<=host_download;
  if(reset)reset_pending<=1;
  if((reset||reset_pending)&&state!=READ_WAIT&&state!=ABORT_WAIT&&state!=ABORT_DRAIN)begin
   if(state==IDLE)begin
    copied_bytes<=0;protocol_error<=0;error_code<=0;reset_pending<=0;normal_count<=0;normal_head<=0;normal_tail<=0;
   end else begin state<=ABORT_DRAIN;normal_count<=0;end
  end else begin
   // ioctl_wr is pipelined after the HPS data strobe. Two words cover the
   // already-issued next payload before host_wait becomes visible upstream.
   if(normal_push)begin
    if(normal_count==2&&!normal_pop)begin state<=ABORT_DRAIN;normal_count<=0;protocol_error<=1;error_code<=4'd5;end
    else begin normal_addr[normal_tail]<=host_addr;normal_data[normal_tail]<=host_dout;normal_tail<=~normal_tail;end
   end
   if(normal_pop)begin normal_head<=~normal_head;copied_bytes<=copied_bytes+27'd2;end
   if(normal_push&&(normal_count!=2||normal_pop)&&!normal_pop)normal_count<=normal_count+2'd1;
   else if(normal_pop&&!normal_push)normal_count<=normal_count-2'd1;
   case(state)
    IDLE:if(start&&!reset)begin
     protocol_error<=0;error_code<=0;copied_bytes<=0;lane<=0;normal_count<=0;normal_head<=0;normal_tail<=0;
     if(host_addr==0)state<=NORMAL;
     else if(host_addr==IMAGE_BYTES)state<=FAST_HOST;
     else begin state<=BAD_BEGIN;protocol_error<=1;error_code<=4'd1;end
    end
    NORMAL:if(host_download&&host_index!=0)begin state<=ABORT_DRAIN;normal_count<=0;protocol_error<=1;error_code<=4'd2;end
           else if(!host_download)state<=NORMAL_DRAIN;
    NORMAL_DRAIN:if(normal_count==0&&!loader_transfer_active&&loader_drained&&(loader_error!=0||!loader_wait))begin
     if(loader_rom_loaded&&!loader_error)copy_done<=1;
     state<=IDLE;
    end
    FAST_HOST:begin
     if(host_index!=0||host_wr)begin state<=ABORT_DRAIN;protocol_error<=1;error_code<=4'd2;end
     else if(!host_download)state<=FAST_GRANT;
    end
    FAST_GRANT:if(ddr_grant&&loader_initialized)state<=READ_REQ;
    READ_REQ:if(ddr_rd&&!ddr_busy)begin
     if(ddr_data_ready)begin buffer<=ddr_data;lane<=0;state<=WORDS;end
     else state<=READ_WAIT;
    end
    READ_WAIT:if(reset||reset_pending)begin
     if(ddr_data_ready)state<=ABORT_DRAIN;else state<=ABORT_WAIT;
    end else if(ddr_data_ready)begin buffer<=ddr_data;lane<=0;state<=WORDS;end
    WORDS:if(word_accept)begin
     copied_bytes<=copied_bytes+27'd2;
     if(copied_bytes+27'd2==IMAGE_BYTES)state<=FINAL_DRAIN;
     else if(lane==2'd3)begin lane<=0;state<=READ_REQ;end
     else lane<=lane+2'd1;
    end
    FINAL_DRAIN:if(!loader_transfer_active&&loader_drained&&(loader_error!=0||!loader_wait))begin
     if(loader_rom_loaded&&!loader_error)copy_done<=1;
     else begin protocol_error<=1;error_code<=4'd3;end
     state<=IDLE;
    end
    ABORT_WAIT:if(ddr_data_ready)state<=ABORT_DRAIN;
    ABORT_DRAIN:if(!loader_transfer_active&&loader_drained&&(loader_error!=0||!loader_wait))begin state<=IDLE;reset_pending<=0;end
    BAD_BEGIN:state<=ABORT_DRAIN;
    default:state<=ABORT_DRAIN;
   endcase
   if(start&&state!=IDLE)begin
    protocol_error<=1;error_code<=4'd4;
    state <= (state==READ_WAIT&&!ddr_data_ready) ? ABORT_WAIT : ABORT_DRAIN;
    normal_count<=0;
   end
  end
 end
endmodule
