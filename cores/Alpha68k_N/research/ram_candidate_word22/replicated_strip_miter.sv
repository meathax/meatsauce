module replicated_strip_miter;
 reg clk=0;always #5 clk=~clk;
 reg held_reset=0,pause_game=0,paused=0,hs_access=0,hs_write=0,coin_latch=0,mas_n=0,bus_done=0,iack=0,mrw_n=1,muds_n=0,mlds_n=0;
 reg[23:0] hs_addr=0,maddr=24'h040000;
 wire[23:1] ma=maddr[23:1];
 reg[15:0] mdout=0,main_rom_addr_q=0;reg[7:0] hs_data_in=0,credits=7;reg[1:0] coins_n=3;reg[11:0] debug_word_addr=0;
 wire[7:0] ah,bh;wire[15:0] aw,bw,asq,bsq,ar,br;
 ram_candidate_reference_old refold(.clk(clk),.held_reset(held_reset),.pause_game(pause_game),.paused(paused),.hs_access(hs_access),.hs_write(hs_write),
 .hs_addr(hs_addr),.maddr(maddr),.ma(ma),.mdout(mdout),.main_rom_addr_q(main_rom_addr_q),.hs_data_in(hs_data_in),
 .credits(credits),.coins_n(coins_n),.coin_latch(coin_latch),.mas_n(mas_n),.bus_done(bus_done),.iack(iack),
 .mrw_n(mrw_n),.muds_n(muds_n),.mlds_n(mlds_n),.debug_word_addr(debug_word_addr),.hs_data_out(ah),.work_cpu_q(aw),.strip_cpu_q(asq),.renderer_q(ar));
 ram_candidate_inference_probe_replicated candidate(.clk(clk),.held_reset(held_reset),.pause_game(pause_game),.paused(paused),.hs_access(hs_access),.hs_write(hs_write),
 .hs_addr(hs_addr),.maddr(maddr),.ma(ma),.mdout(mdout),.main_rom_addr_q(main_rom_addr_q),.hs_data_in(hs_data_in),
 .credits(credits),.coins_n(coins_n),.coin_latch(coin_latch),.mas_n(mas_n),.bus_done(bus_done),.iack(iack),
 .mrw_n(mrw_n),.muds_n(muds_n),.mlds_n(mlds_n),.debug_word_addr(debug_word_addr),.hs_data_out(bh),.work_cpu_q(bw),.strip_cpu_q(bsq),.renderer_q(br));

 integer checked=0;
 always @(posedge clk) begin
 #1;
 if({ah,aw,asq,ar}!=={bh,bw,bsq,br})$fatal(1,"contract mismatch cycle%0d",checked);
 checked=checked+1;
 end
 initial begin
 for(integer n=0;n<8192;n=n+1) begin
 @(negedge clk);
 held_reset=0;pause_game=0;paused=0;hs_access=0;hs_write=0;bus_done=0;mas_n=0;iack=0;
 maddr=24'h040000+2*(n%4096);mdout=(n*353)^16'ha55a;mrw_n=n%5==0;
 muds_n=n%4==1;mlds_n=n%4==2;debug_word_addr=n%4096;
 // Directed work upper shadow and special mailbox, followed by coinHLE.
 case(n%32)
 0:begin maddr=24'h020052;mrw_n=0;muds_n=0;mlds_n=0;end
 1:begin maddr=24'h080052;mrw_n=1;coins_n=2;coin_latch=0;end
 2:begin maddr=24'h020044;mrw_n=1;end
 3:begin pause_game=1;paused=1;hs_access=1;hs_write=1;hs_addr=24'h020052;hs_data_in=n[7:0];end
 4:begin pause_game=1;paused=1;hs_access=1;hs_write=1;hs_addr=24'h020053;hs_data_in=8'hcc;end
 5:begin pause_game=1;paused=1;hs_access=1;hs_write=1;hs_addr=24'h020044;hs_data_in=8'h66;end
 6:begin pause_game=1;paused=1;hs_access=1;hs_write=1;hs_addr=24'h020045;hs_data_in=8'h77;end
 7:begin maddr=24'h080052;mrw_n=1;coins_n=1;coin_latch=0;end
 8:begin maddr=24'h080044;mrw_n=1;end
 9:begin maddr=24'h0801fe;mrw_n=1;end
 10:begin maddr=24'h080052;mrw_n=1;coins_n=3;coin_latch=1;end
 11:begin held_reset=1;end
 default:begin end
 endcase
 end
 @(negedge clk);held_reset=1;
 for(integer n=0;n<4096;n=n+1)begin
 if(candidate.strip_hi[n]!==candidate.renderer_strip_hi[n] ||
    candidate.strip_lo[n]!==candidate.renderer_strip_lo[n] ||
    candidate.strip_hi[n]!==refold.strip_hi[n] || candidate.strip_lo[n]!==refold.strip_lo[n])
 $fatal(1,"copy identity mismatch%0d",n);
 end
 for(integer n=0;n<2048;n=n+1)begin
 if(candidate.work_hi[n]!==refold.work_hi[n] || candidate.work_lo[n]!==refold.work_lo[n])$fatal(1,"work changed%0d",n);
 end
 if(candidate.work_word22!==refold.work_word22 || candidate.work29_high!==refold.work29_high)$fatal(1,"specialworkchanged");
 $display("PASS replicated SDP exact OLD_DATA contract checked=%0d all4096copies/all2048work",checked);
 $finish;
 end
endmodule
