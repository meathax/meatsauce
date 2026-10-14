module actual_cpu_miter;
 reg clk=0;always #5 clk=~clk;
 reg reset=1,downloading=1,load_wr=0,pause_game=0,hs_access=0,hs_write=0;
 reg[24:0] load_addr=0;reg[15:0] load_data=0;reg[23:0] hs_addr=0;reg[7:0] hs_data_in=0;
 reg[1:0] coins_n=2;reg[11:0] debug_word_addr=0;
 wire[23:0] la,na;wire[3:0] lat,nat;wire[15:0] ldi,ndi,ldo,ndo,lw,nw,ls,ns;
 wire las,nas,lp,np;wire[7:0] lhs,nhs;wire[31:0] ltx,ntx,lww,nww,lsw,nsw;
 legacy_alpha68kn_board oldboard(.clk(clk),.reset(reset),.downloading(downloading),.load_wr(load_wr),
 .load_addr(load_addr),.load_data(load_data),.controls(16'd0),.dips(8'h8e),.coins_n(coins_n),
 .pause_game(pause_game),.paused(lp),.hs_access(hs_access),.hs_write(hs_write),.hs_addr(hs_addr),.hs_data_in(hs_data_in),.hs_data_out(lhs),
 .sound_io_read_data(8'hff),.debug_main_addr(la),.debug_main_as_n(las),.debug_main_attrs(lat),.debug_main_din(ldi),.debug_main_dout(ldo),
 .main_transactions(ltx),.work_writes(lww),.strip_writes(lsw),.debug_word_addr(debug_word_addr),
 .debug_work_data(lw),.debug_strip_data(ls),.debug_rom_kind(4'd0),.debug_rom_addr(16'd0));
 alpha68kn_board newboard(.clk(clk),.reset(reset),.downloading(downloading),.load_wr(load_wr),
 .load_addr(load_addr),.load_data(load_data),.controls(16'd0),.dips(8'h8e),.coins_n(coins_n),
 .pause_game(pause_game),.paused(np),.hs_access(hs_access),.hs_write(hs_write),.hs_addr(hs_addr),.hs_data_in(hs_data_in),.hs_data_out(nhs),
 .sound_io_read_data(8'hff),.debug_main_addr(na),.debug_main_as_n(nas),.debug_main_attrs(nat),.debug_main_din(ndi),.debug_main_dout(ndo),
 .main_transactions(ntx),.work_writes(nww),.strip_writes(nsw),.debug_word_addr(debug_word_addr),
 .debug_work_data(nw),.debug_strip_data(ns),.debug_rom_kind(4'd0),.debug_rom_addr(16'd0));
 reg[15:0] rom[0:255];integer ticks=0,checked=0,read_checked=0,write_DI_diffs=0,coinA=0,coinB=0;
 reg monitoring=0;
 always @(posedge clk) begin
   #1;
   if(monitoring) begin
     checked=checked+1;
     if({la,lat,las,ldo,ltx,lww,lsw,lp}!=={na,nat,nas,ndo,ntx,nww,nsw,np})
       $fatal(1,"bus/control mismatch tick%0d la%h na%h",ticks,la,na);
     if(oldboard.bus_done && oldboard.mrw_n) begin
       read_checked=read_checked+1;
       if(ldi!==ndi)$fatal(1,"read DI mismatch tick%0d addr%h old%h new%h",ticks,la,ldi,ndi);
     end
     if(ldi!==ndi)write_DI_diffs=write_DI_diffs+1;
     if(lhs!==nhs)$fatal(1,"HS mismatch tick%0d old%h new%h",ticks,lhs,nhs);
     if(ls!==ns || lw!==nw)$fatal(1,"observed memory port mismatch tick%0d",ticks);
     if({oldboard.maincpu.excUnit.PcH,oldboard.maincpu.excUnit.PcL}!=={newboard.maincpu.excUnit.PcH,newboard.maincpu.excUnit.PcL})
       $fatal(1,"real fx68k PC mismatch tick%0d",ticks);
     for(integer regn=0;regn<18;regn=regn+1)
       if({oldboard.maincpu.excUnit.regs68H[regn],oldboard.maincpu.excUnit.regs68L[regn]}!==
          {newboard.maincpu.excUnit.regs68H[regn],newboard.maincpu.excUnit.regs68L[regn]})
          $fatal(1,"real fx68k register mismatch tick%0d reg%0d",ticks,regn);
   end
   ticks=ticks+1;
 end
 always @(negedge clk) if(monitoring && !pause_game && !oldboard.mas_n && !oldboard.bus_done &&
         oldboard.mrw_n && oldboard.maddr==24'h080052 && !oldboard.coin_latch) begin
   if(!coins_n[0])coinA=coinA+1;else if(!coins_n[1])coinB=coinB+1;
 end
 task waitn(input integer n);begin repeat(n)@(negedge clk);end endtask
 task hsop(input[23:0] a,input bit wr,input[7:0] d);begin
 hs_access=1;hs_addr=a;hs_write=wr;hs_data_in=d;waitn(2);hs_access=0;hs_write=0;waitn(2);end endtask
 initial begin
 for(integer i=0;i<256;i=i+1)rom[i]=16'h4e71;
 rom[0]=16'h0002;rom[1]=16'h0ff0;rom[2]=0;rom[3]=16'h0100;
rom[128]=16'h33fc;
rom[129]=16'habcd;
rom[130]=16'h0002;
rom[131]=16'h0052;
rom[132]=16'h33fc;
rom[133]=16'h1111;
rom[134]=16'h0002;
rom[135]=16'h0044;
rom[136]=16'h13fc;
rom[137]=16'h0066;
rom[138]=16'h0002;
rom[139]=16'h0052;
rom[140]=16'h13fc;
rom[141]=16'h0077;
rom[142]=16'h0002;
rom[143]=16'h0053;
rom[144]=16'h33fc;
rom[145]=16'hdead;
rom[146]=16'h0004;
rom[147]=16'h0000;
rom[148]=16'h3039;
rom[149]=16'h0002;
rom[150]=16'h0052;
rom[151]=16'h3239;
rom[152]=16'h0002;
rom[153]=16'h0044;
rom[154]=16'h3439;
rom[155]=16'h0004;
rom[156]=16'h0000;
rom[157]=16'h1639;
rom[158]=16'h0008;
rom[159]=16'h0052;
rom[160]=16'h3839;
rom[161]=16'h0002;
rom[162]=16'h0044;
rom[163]=16'h3a39;
rom[164]=16'h0002;
rom[165]=16'h0052;
rom[166]=16'h1c39;
rom[167]=16'h0008;
rom[168]=16'h0044;
rom[169]=16'h1e39;
rom[170]=16'h0008;
rom[171]=16'h01fe;
rom[172]=16'h1639;
rom[173]=16'h0008;
rom[174]=16'h0052;
rom[175]=16'h3839;
rom[176]=16'h0002;
rom[177]=16'h0044;
rom[178]=16'h3a39;
rom[179]=16'h0002;
rom[180]=16'h0052;
rom[181]=16'h60ec;
 // Load actual board interface; ROM fixture is an instruction-level contract,
 // not a game replay or acceptance proof. Real pinned fx68k and T80 execute.
 for(integer i=0;i<256;i=i+1)begin
 @(negedge clk);load_wr=1;load_addr=25'h100+2*i;load_data={rom[i][7:0],rom[i][15:8]};
 end
 @(negedge clk);load_addr=25'h20100;load_data=16'h00c3;
 @(negedge clk);load_addr=25'h20102;load_data=0;
 @(negedge clk);load_wr=0;downloading=0;reset=0;monitoring=1;
 waitn(6000);
 if(lww<4 || lsw<1)$fatal(1,"actual CPU did not exercise RAM writes");
 pause_game=1;waitn(4);
 hsop(24'h020044,1,8'h77);hsop(24'h020045,1,8'h88);
 hsop(24'h020052,1,8'h99);hsop(24'h020053,1,8'haa);
 hsop(24'h020044,0,0);hsop(24'h020045,0,0);hsop(24'h020052,0,0);hsop(24'h020053,0,0);
 pause_game=0;coins_n=3;waitn(1200);coins_n=1;waitn(1600);
 for(integer i=0;i<2048;i=i+1)begin
 if(oldboard.work_ram[i] !== (i==11'h22 ? newboard.work_word22 : {newboard.work_hi[i],newboard.work_lo[i]}))
 $fatal(1,"work RAM mismatch%h",i);
 end
 for(integer i=0;i<4096;i=i+1)begin
 if(oldboard.strip_ram[i]!=={newboard.strip_hi[i],newboard.strip_lo[i]})$fatal(1,"strip RAM mismatch%h",i);
 end
 if(coinA==0 || coinB==0)$fatal(1,"both actual coin branch coverage missing A%0d B%0d",coinA,coinB);
 reset=1;waitn(16);
 if(newboard.work_word22!==oldboard.work_ram['h22] || newboard.work29_high!==oldboard.work_ram['h29][15:8])
 $fatal(1,"reset retained special/shadow mismatch");
 $display("PASS real fx68k board miter checked=%0d read=%0d write_DI_diff_ticks=%0d coinA=%0d coinB=%0d",checked,read_checked,write_DI_diffs,coinA,coinB);
 $finish;
 end
endmodule
