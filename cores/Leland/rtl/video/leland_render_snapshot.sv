// SPDX-License-Identifier: GPL-3.0-or-later
// Asylum foreground transactions. No pixel retention or blending: zero is data.
// DDR byte window 0x39000000..0x3902ffff, three 64 KiB banks. The tile
// background keeps its original raster/scroll path. Palette follows the bank.
module leland_render_snapshot (
 input clk, input hard_reset, input stop,
 input group_active, input group_done,
 input vblank, input [15:0] video_addr,
 input [10:0] palette_addr,
 output reg [7:0] video_data, output wire [7:0] palette_data,
 output reg pause_cpus=0, input buses_quiet,
 output reg capture_port=0, output [15:0] capture_addr,
 input [7:0] capture_data,
 output [10:0] capture_pal_addr, input [7:0] capture_pal_data,
 output reg [28:0] ddr_addr=0, output reg [63:0] ddr_din=0,
 output reg ddr_we=0, output reg ddr_rd=0,
 input ddr_busy, input [63:0] ddr_dout, input ddr_ready,
 output reg valid=0, output reg fault=0
);
 localparam [28:0] BASE = 29'h07200000; // 0x39000000 / 8
 localparam [3:0] IDLE=0, QUIET=1, PRIME=2, COPY=3, WRITE=4,
                  PAL_PRIME=5, PAL_COPY=6, FINISH=7, ABORT=8;
 reg [3:0] state=IDLE;
 reg vb_d=0;
 wire vb_start = vblank && !vb_d;
 reg request=0;
 reg [1:0] front_bank=0, pending_bank=1, copy_bank=2;
 reg pending=0;
 reg [7:0] copy_y=0;
 reg [7:0] copy_x=0;
 reg [2:0] lane=0;
 reg [63:0] pack=0;
 reg [10:0] pal_index=0;
 reg [7:0] last_video_y=0;
 reg [7:0] wanted_y=0;
 reg wanted=0;
 reg [7:0] fetch_y=0;
 reg [1:0] fetch_bank=0;
 reg [4:0] fetch_word=0;
 reg reading=0;
 reg read_wait=0;
 reg discard_read=0;
 reg [7:0] tag0=0, tag1=0;
 reg [1:0] bank0=0, bank1=0;
 reg line0_valid=0, line1_valid=0;
 (* ramstyle = "M10K" *) reg [63:0] lines [0:63];
 // Keep three explicit 2 KiB banks. Q17 expanded the conditionally read 6144
 // byte array into 49,152 registers despite its ramstyle attribute. Reuse
 // the qualified one-clock primitive wrapper, including its OLD_DATA B port.
 wire [7:0] palette_q [0:2];
 reg [1:0] palette_bank_d=0;
 reg palette_valid_d=0;
 genvar pb;
 generate for (pb=0;pb<3;pb=pb+1) begin : g_palette
  leland_qram_compact_candidate #(.ADDR_WIDTH(11),.DATA_WIDTH(8)) ram (
   .clk(clk), .addr_a(pal_index), .din_a(capture_pal_data),
   .we_a(state==PAL_COPY && !stop && !fault && copy_bank==pb), .dout_a(),
   .addr_b(palette_addr), .din_b(8'd0), .we_b(1'b0), .dout_b(palette_q[pb]));
 end endgenerate
 always @(posedge clk) begin
  palette_bank_d<=front_bank;
  palette_valid_d<=valid && !fault && !stop && !hard_reset;
 end
 assign palette_data=palette_valid_d ? ((palette_bank_d==0) ? palette_q[0] :
                       (palette_bank_d==1) ? palette_q[1] : palette_q[2]) : 8'd0;
 reg [63:0] pixel_word;
 reg [2:0] pixel_lane;
 reg pixel_valid;
 wire [7:0] vy = video_addr[15:8];
 wire line_valid = vy[0] ? (line1_valid && tag1==vy && bank1==front_bank)
                                    : (line0_valid && tag0==vy && bank0==front_bank);
 wire [12:0] copy_word = {copy_y,5'b0} + {8'd0,copy_x[7:3]};
 wire [12:0] fetch_offset = {fetch_y,5'b0} + {8'd0,fetch_word};
 wire accepted_write = ddr_we && !ddr_busy;
 wire accepted_read = ddr_rd && !ddr_busy;
 wire returned = ddr_ready && (read_wait || accepted_read);
 wire publish = vb_start && pending && !reading && !read_wait && !ddr_rd;
 // Address one byte ahead while consuming the RAM's registered reply.
 assign capture_addr = {copy_y,copy_x} + ((state==COPY && lane!=7) ? 16'd1 : 16'd0);
 assign capture_pal_addr = pal_index;

 // Reset-free synchronous memory processes. Data is observed only with tags.
 always @(posedge clk) begin
  pixel_word <= lines[{vy[0],video_addr[7:3]}];
  pixel_lane <= video_addr[2:0];
  pixel_valid <= valid && line_valid && video_addr[7:0]<160 && !stop && !fault;
  video_data <= pixel_valid ? pixel_word[pixel_lane*8 +: 8] : 8'd0;
  if (returned && !discard_read && !stop)
   lines[{fetch_y[0],fetch_word}] <= ddr_dout;
 end

 always @(posedge clk) begin
  vb_d <= vblank;
  last_video_y <= vy;
  if (hard_reset) begin
   state<=IDLE; request<=0; pause_cpus<=0; capture_port<=0;
   front_bank<=0; pending_bank<=1; copy_bank<=2; pending<=0;
   copy_y<=0; copy_x<=0; lane<=0; pack<=0; pal_index<=0;
   ddr_rd<=0; ddr_we<=0; ddr_addr<=0; ddr_din<=0;
   valid<=0; fault<=0; reading<=0; read_wait<=0; discard_read<=0;
   wanted<=0; wanted_y<=0; fetch_y<=0; fetch_bank<=0; fetch_word<=0;
   line0_valid<=0; line1_valid<=0; tag0<=0; tag1<=0; bank0<=0; bank1<=0;
   vb_d<=0; last_video_y<=0;
  end else begin
   if (accepted_write) ddr_we<=0;
   if (accepted_read) begin ddr_rd<=0; read_wait<=1; end
   if (returned) begin
    read_wait<=0;
    if (fetch_word==19 || discard_read || stop) begin
     reading<=0;
     if (!discard_read && !stop) begin
      if (fetch_y[0]) begin tag1<=fetch_y; bank1<=fetch_bank; line1_valid<=1; end
      else begin tag0<=fetch_y; bank0<=fetch_bank; line0_valid<=1; end
     end
     discard_read<=0;
    end else fetch_word<=fetch_word+1'b1;
   end
   if (ddr_ready && !read_wait && !accepted_read) fault<=1;

   if (stop || fault) begin
    // Never withdraw a command while BUSY, or forget its eventual read reply.
    valid<=0; pending<=0; request<=0; wanted<=0;
    line0_valid<=0; line1_valid<=0;
    pause_cpus<=0; capture_port<=0; state<=ABORT;
    if (read_wait || ddr_rd) discard_read<=1;
    else begin reading<=0; discard_read<=0; end
   end else begin
    if (group_done || (vb_start && !pending)) request<=1;
    if (publish) begin
     front_bank<=pending_bank;
     pending_bank<=front_bank;
     pending<=0; valid<=1;
     line0_valid<=0; line1_valid<=0;
     wanted<=1; wanted_y<=0;
    end else if (vb_start && valid) begin
     wanted<=1; wanted_y<=0;
    end else if (vy!=last_video_y && vy<239 && valid) begin
     wanted<=1; wanted_y<=vy+1'b1;
    end

    // One outstanding read, with its bank/line/word retained until response.
    // Fetch ahead; do not issue a read for a bank on its publication edge.
    if (wanted && !reading && !ddr_we && !ddr_rd && !read_wait && !publish) begin
     wanted<=0; reading<=1; fetch_y<=wanted_y; fetch_bank<=front_bank; fetch_word<=0;
     if (wanted_y[0]) line1_valid<=0; else line0_valid<=0;
    end
    if (reading && !read_wait && !ddr_rd && !ddr_we && !returned) begin
     ddr_addr<=BASE+{14'd0,fetch_bank,13'd0}+{16'd0,fetch_offset};
     ddr_rd<=1;
    end

    case (state)
     ABORT: if (!ddr_rd && !ddr_we && !read_wait && !reading) begin
      state<=IDLE; discard_read<=0;
     end
     IDLE: if (request && !group_active && !pending && !publish) begin
      pause_cpus<=1; state<=QUIET;
     end
     QUIET: if (buses_quiet) begin
      // A group may have started while BUSRQ was being acknowledged. Let it
      // finish rather than snapshotting an erased bitmap or deadlocking it.
      if (group_active) begin pause_cpus<=0; state<=IDLE; end
      else begin
       request<=0; capture_port<=1; copy_y<=0; copy_x<=0; lane<=0;
       state<=PRIME;
      end
     end
     PRIME: state<=COPY;
     COPY: begin
      pack[lane*8 +: 8]<=capture_data;
      if (lane==7) state<=WRITE;
      else begin lane<=lane+1'b1; copy_x<=copy_x+1'b1; end
     end
     WRITE: if (!ddr_we && !ddr_rd && !read_wait && !reading && !wanted) begin
      ddr_addr<=BASE+{14'd0,copy_bank,13'd0}+{16'd0,copy_word};
      ddr_din<=pack; ddr_we<=1;
      state<=FINISH;
     end
     FINISH: if (accepted_write) begin
      lane<=0;
      if (copy_x==159) begin
       copy_x<=0;
       if (copy_y==239) begin pal_index<=0; state<=PAL_PRIME; end
       else begin copy_y<=copy_y+1'b1; state<=PRIME; end
      end else begin copy_x<=copy_x+1'b1; state<=PRIME; end
     end
     PAL_PRIME: state<=PAL_COPY;
     PAL_COPY: if (pal_index==2047) begin
      pending_bank<=copy_bank;
      // The unused third bank is distinct from front and completed banks.
      copy_bank<=pending_bank;
      pending<=1; capture_port<=0; pause_cpus<=0; state<=IDLE;
     end else begin pal_index<=pal_index+1'b1; state<=PAL_PRIME; end
     default: state<=IDLE;
    endcase
   end
  end
 end
endmodule
