// SPDX-License-Identifier: GPL-3.0-or-later
// CPU-visible RAM plus an atomic frame-boundary rendering view. The first
// write in an epoch retains the preceding word; later writes cannot change
// that frame's image. Alternating dirty maps are cleared before reuse.
//
// A write uses a pre-read followed by a commit on the same physical RAM port.
// Its accepted reply retains the existing registered-read latency. The next
// CPU request waits one clock, and explicit B-port forwarding covers every
// live/backup collision without relying on a vendor read-during-write mode.
module thunderjaws_snapshot_ram #(parameter integer ADDRESS_BITS=12)(
 input wire clk,init_reset,snapshot_start,
 output reg initialized,
 output wire a_ready,
 output reg fault,
 input wire a_enable,a_write,
 input wire [ADDRESS_BITS-1:0] a_address,
 input wire [1:0] a_lanes,
 input wire [15:0] a_write_data,
 output wire [15:0] a_data,
 input wire b_enable,b_snapshot,
 input wire [ADDRESS_BITS-1:0] b_address,
 output wire [15:0] b_data
);
 localparam integer DEPTH=1<<ADDRESS_BITS;
 reg [15:0] before_image[0:DEPTH-1];
 integer i;
 initial for(i=0;i<DEPTH;i=i+1)before_image[i]=0;
 reg epoch,clearing,clear_bank,initial_second;
 reg [ADDRESS_BITS-1:0] clear_address;
 reg write_pending,write_epoch;
 reg [ADDRESS_BITS-1:0] write_address;
 reg [1:0] write_lanes;
 reg [15:0] write_data;
 wire dirty0_a,dirty1_a;
 wire take_snapshot=snapshot_start && initialized && !clearing;
 wire effective_epoch=epoch ^ take_snapshot;
 assign a_ready=initialized && !init_reset && !write_pending;
 wire a_accept=a_enable && a_ready;
 wire first_write=write_pending && !(write_epoch ? dirty1_a : dirty0_a);
 wire [ADDRESS_BITS-1:0] live_a_address=write_pending ? write_address : a_address;
 wire set0=first_write && !write_epoch && !init_reset;
 wire set1=first_write && write_epoch && !init_reset;
 wire tag0_write=set0 || (clearing && !clear_bank);
 wire tag1_write=set1 || (clearing && clear_bank);
 wire [ADDRESS_BITS-1:0] tag0_a_address=set0 ? write_address : tag0_write ? clear_address : a_address;
 wire [ADDRESS_BITS-1:0] tag1_a_address=set1 ? write_address : tag1_write ? clear_address : a_address;
 wire [15:0] committed={write_lanes[1] ? write_data[15:8] : a_data[15:8],
                        write_lanes[0] ? write_data[7:0] : a_data[7:0]};
 wire [15:0] live_b;
 reg [15:0] backup_b,live_forward_data,backup_forward_data;
 wire dirty0_b,dirty1_b;
 reg b_epoch,use_snapshot,live_forward,backup_forward;
 wire saved_dirty=b_epoch ? dirty1_b : dirty0_b;
 assign b_data=use_snapshot && (saved_dirty || backup_forward) ?
  (backup_forward ? backup_forward_data : backup_b) :
  (live_forward ? live_forward_data : live_b);

 // Each store owns one physical read/write A port and one read-only B port.
 thunderjaws_snapshot_tdp #(.ADDRESS_BITS(ADDRESS_BITS),.WIDTH(16),.LANES(2)) live_store(
  .clk(clk),.a_enable(a_accept || write_pending),.a_write(write_pending),
  .a_address(live_a_address),.a_lanes(write_lanes),.a_write_data(write_data),.a_data(a_data),
  .b_enable(b_enable),.b_address(b_address),.b_data(live_b));
 thunderjaws_snapshot_tdp #(.ADDRESS_BITS(ADDRESS_BITS),.WIDTH(1),.LANES(1)) dirty0_store(
  .clk(clk),.a_enable((a_accept && !effective_epoch) || tag0_write),.a_write(tag0_write),
  .a_address(tag0_a_address),.a_lanes(1'b1),.a_write_data(set0),.a_data(dirty0_a),
  .b_enable(b_enable),.b_address(b_address),.b_data(dirty0_b));
 thunderjaws_snapshot_tdp #(.ADDRESS_BITS(ADDRESS_BITS),.WIDTH(1),.LANES(1)) dirty1_store(
  .clk(clk),.a_enable((a_accept && effective_epoch) || tag1_write),.a_write(tag1_write),
  .a_address(tag1_a_address),.a_lanes(1'b1),.a_write_data(set1),.a_data(dirty1_a),
  .b_enable(b_enable),.b_address(b_address),.b_data(dirty1_b));
 always @(posedge clk)if(first_write && !init_reset)before_image[write_address]<=a_data;
 always @(posedge clk)if(b_enable)begin
  backup_b<=before_image[b_address];
  b_epoch<=effective_epoch;use_snapshot<=b_snapshot && initialized;
  live_forward<=write_pending && write_address==b_address;
  live_forward_data<=committed;
  backup_forward<=first_write && write_epoch==effective_epoch && write_address==b_address;
  backup_forward_data<=a_data;
 end
 always @(posedge clk)begin
  if(init_reset)begin
   initialized<=0;epoch<=0;clearing<=1;clear_bank<=0;clear_address<=0;initial_second<=0;
   write_pending<=0;write_epoch<=0;write_address<=0;write_lanes<=0;write_data<=0;fault<=0;
  end else begin
   write_pending<=a_accept && a_write && |a_lanes;
   if(a_accept)begin
    write_address<=a_address;write_lanes<=a_lanes;write_data<=a_write_data;write_epoch<=effective_epoch;
   end
   if(snapshot_start && (!initialized || clearing))fault<=1;
   if(take_snapshot)begin epoch<=!epoch;clearing<=1;clear_bank<=epoch;clear_address<=0;end
   else if(clearing)begin
    if(&clear_address)begin
     clear_address<=0;
     if(!initialized && !initial_second)begin initial_second<=1;clear_bank<=1;end
     else begin clearing<=0;initialized<=1;end
    end else clear_address<=clear_address+1'b1;
   end
  end
 end
endmodule

// Physical template follows MiSTer AtariSystem2 sys/sd_card.sv altsyncram.
// A read on a write edge is unconsumed by the snapshot protocol. Mixed-port
// collisions are resolved by the parent's explicit registered forwarding.
module thunderjaws_snapshot_tdp #(parameter integer ADDRESS_BITS=12,WIDTH=16,LANES=2)(
 input wire clk,a_enable,a_write,
 input wire [ADDRESS_BITS-1:0] a_address,
 input wire [LANES-1:0] a_lanes,
 input wire [WIDTH-1:0] a_write_data,
 output wire [WIDTH-1:0] a_data,
 input wire b_enable,
 input wire [ADDRESS_BITS-1:0] b_address,
 output wire [WIDTH-1:0] b_data
);
`ifdef ALTERA_RESERVED_QIS
 altsyncram #(
  .intended_device_family("Cyclone V"),.lpm_type("altsyncram"),
  .operation_mode("BIDIR_DUAL_PORT"),.numwords_a(1<<ADDRESS_BITS),.numwords_b(1<<ADDRESS_BITS),
  .widthad_a(ADDRESS_BITS),.widthad_b(ADDRESS_BITS),.width_a(WIDTH),.width_b(WIDTH),
  .width_byteena_a(LANES),.width_byteena_b(1),
  .address_reg_b("CLOCK1"),.indata_reg_b("CLOCK1"),.wrcontrol_wraddress_reg_b("CLOCK1"),
  .clock_enable_input_a("NORMAL"),.clock_enable_input_b("NORMAL"),
  .clock_enable_output_a("BYPASS"),.clock_enable_output_b("BYPASS"),
  .outdata_aclr_a("NONE"),.outdata_aclr_b("NONE"),
  .outdata_reg_a("UNREGISTERED"),.outdata_reg_b("UNREGISTERED"),
  .power_up_uninitialized("FALSE"),.read_during_write_mode_mixed_ports("DONT_CARE"),
  .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),.read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ")
 ) storage(.clock0(clk),.clock1(clk),.clocken0(a_enable),.clocken1(b_enable),
  .address_a(a_address),.data_a(a_write_data),.wren_a(a_write),.byteena_a(a_lanes),.rden_a(1'b1),.q_a(a_data),
  .address_b(b_address),.data_b({WIDTH{1'b0}}),.wren_b(1'b0),.byteena_b(1'b1),.rden_b(1'b1),.q_b(b_data),
  .aclr0(1'b0),.aclr1(1'b0),.addressstall_a(1'b0),.addressstall_b(1'b0));
`else
 reg [WIDTH-1:0] memory[0:(1<<ADDRESS_BITS)-1];
 reg [WIDTH-1:0] qa,qb;
 integer i,j;
 initial for(i=0;i<(1<<ADDRESS_BITS);i=i+1)memory[i]=0;
 assign a_data=qa;assign b_data=qb;
 always @(posedge clk)if(a_enable)begin
  qa<=memory[a_address];
  if(a_write)for(j=0;j<LANES;j=j+1)if(a_lanes[j])memory[a_address][j*(WIDTH/LANES)+:(WIDTH/LANES)]<=a_write_data[j*(WIDTH/LANES)+:(WIDTH/LANES)];
 end
 always @(posedge clk)if(b_enable)qb<=memory[b_address];
`endif
endmodule
