// Candidate: native MAME sprites are quarter planes; existing readers require interleaved LE32.
// Psycho download is already packed and remains byte/address-identical.
module snk_late_native_loader(
 input [7:0] profile,input [24:0] native_addr,input [7:0] native_data,
 input native_wr,input bridge_wait,
 output reg [24:0] core_addr,output [7:0] core_data,output core_wr,
 output native_wait,output supported,output reg mapped,output reg transformed);
 wire valid,packed_planes;wire [7:0] region_id;wire [24:0] region_offset;
 snk_native_rom_decode decode(profile,native_addr,valid,region_id,region_offset,packed_planes);
 assign supported=profile==11||profile==12||profile==13||profile==16||profile==15||profile==17||profile==19||profile==14||profile==18;
 assign core_data=native_data;
 assign core_wr=native_wr&&mapped&&supported;
 // Keep backend admission identical to the original shared download path.
 assign native_wait=supported&&bridge_wait;
 always @* begin
  core_addr=native_addr;mapped=0;transformed=0;
  if(profile==13) mapped=valid;
  else if(supported&&valid) case(region_id)
   0,1,2: mapped=region_offset<25'hc000; // source maps decode only 0000-BFFF
   3,5: mapped=1;
   9:begin mapped=1; // gwar: native PROM slot 0x140000 -> fixed physical PROM window 0x120000
     if(profile==19) core_addr=25'h120000+region_offset;
     else if(profile==15||profile==17) core_addr=native_addr+25'h10000; end
   11:begin mapped=1; // gwar: native ym2 slot 0x150000 -> fixed sample window 0x130000
     if(profile==19) core_addr=25'h130000+region_offset;
     else if(profile==15||profile==17) core_addr=native_addr+25'h10000; end
   // sports 15/17 native PROM/ADPCM sit 0x10000 below the fixed physical windows (handled in cases 9 and 11)
   6:begin mapped=1;transformed=1;
     if(profile==19) core_addr=25'h140000+{7'd0,region_offset[15:0],region_offset[17:16]}; // 256 KiB sp16
     else core_addr=25'h80000+{8'd0,region_offset[14:0],region_offset[16:15]};end
   7:begin mapped=1;transformed=1;
     // ikari/victroad: 3bpp sprites, 64KB planes (3 ROM planes + FF plane) instead of 128KB planes
     if(profile==14||profile==18)
       core_addr=25'ha0000+{7'd0,region_offset[15:0],region_offset[17:16]};
     else
       core_addr=25'ha0000+{6'd0,region_offset[16:0],region_offset[18:17]};end
   default:begin end // padding and undumped programmable devices are not runtime memory
  endcase
 end
endmodule
