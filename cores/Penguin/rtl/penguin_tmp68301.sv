// Penguin derivative of staged Guardians gd_tmp68301 (GPL-3.0-or-later).
// Upstream MiSTer-devel/Arcade-Guardians_MiSTer:
// 43bb986da05aa19adb06ac575cfcc8af5c003fb7; donor SHA256 in donors.lock.json.
// Register/IRQ semantics: local MAME 0.289 tmp68301.cpp (BSD-3-Clause).
// Changes: writable decoder/GPIO state, all three internal timers and their
// independent vectors/priority; no Guardians-only timer1 or fixed IRQ levels.
// Serial TX/RX and external timer pins are not connected on this integration.
// Unsupported active modes are counted, never reported as implemented channels.
// SPDX-License-Identifier: GPL-3.0-or-later
module penguin_tmp68301 (
    input logic clk, reset, cpu_ce, cs, write,
    input logic [9:0] address,
    input logic [15:0] data,
    input logic [1:0] byte_enable,
    output logic [15:0] q,
    input logic ext_irq0, ext_irq1, iack,
    output logic [2:0] irq_level,
    output logic [7:0] irq_vector
);
logic [7:0] icr [0:9];
logic [10:0] imr, ipr, iisr;
logic [7:0] ivnr, ieir;
logic [1:0] ext_irq_d;
logic [3:0] chosen_slot;
logic [4:0] chosen_vector;
logic [7:0] amar [0:1], aamr [0:1], aacr [0:2], ator;
logic [15:0] arelr, pdir, pmr, pdata;
logic [7:0] pcr, pcmr, ppr1, ppr2;
logic [7:0] serial_regs [0:47];
logic [15:0] tcr [0:2], tmcr1 [0:2], tmcr2 [0:2], tctr [0:2];
logic [7:0] prescaler [0:2];
logic [2:0] timer_done, timer_alt;
logic [31:0] unsupported_accesses;
wire [1:0] ext_irq = {ext_irq1, ext_irq0};
function automatic [15:0] merge_word(input [15:0] old_value, new_value, input [1:0] enables);
    merge_word = old_value;
    if (enables[1]) merge_word[15:8] = new_value[15:8];
    if (enables[0]) merge_word[7:0] = new_value[7:0];
endfunction
function automatic integer priority_of(input integer slot);
    case(slot)
      0: priority_of=9; 1: priority_of=5; 2: priority_of=0;
      4: priority_of=7; 5: priority_of=3; 6: priority_of=2;
      7: priority_of=6; 8: priority_of=8; 9: priority_of=4;
      10: priority_of=1; default: priority_of=-1;
    endcase
endfunction
integer n, idx, slot, regnum, divider;
logic [2:0] candidate_level;
logic [16:0] timer_max;
logic timer_tick;
// Balanced maximum-level tree; equal levels choose the higher fixed priority.
// Leaves are ordered by the unchanged priority_of table, not source bit order.
function automatic integer irq_leaf_slot(input integer leaf);
    case(leaf)
      0:irq_leaf_slot=0;1:irq_leaf_slot=8;2:irq_leaf_slot=4;
      3:irq_leaf_slot=7;4:irq_leaf_slot=1;5:irq_leaf_slot=9;
      6:irq_leaf_slot=5;7:irq_leaf_slot=6;8:irq_leaf_slot=10;
      9:irq_leaf_slot=2;default:irq_leaf_slot=15;
    endcase
endfunction
function automatic [2:0] irq_leaf_level(input [2:0] level_value,input enabled);
    begin
        irq_leaf_level=0;
        case(level_value)
          3'd1,3'd2,3'd3,3'd4,3'd5,3'd6,3'd7:
            if(enabled)irq_leaf_level=level_value;
          default:irq_leaf_level=0;
        endcase
    end
endfunction
wire [2:0] irq_tree_level[0:30];
wire [3:0] irq_tree_slot[0:30];
genvar g_irq_leaf,g_irq_branch;
generate
    for(g_irq_leaf=0;g_irq_leaf<16;g_irq_leaf=g_irq_leaf+1)begin:irq_leaves
        if(g_irq_leaf<10)begin:used_leaf
            localparam integer SLOT=irq_leaf_slot(g_irq_leaf);
            localparam integer REGNUM=SLOT>=3?SLOT-1:SLOT;
            assign irq_tree_level[15+g_irq_leaf]=irq_leaf_level(icr[REGNUM][2:0],ipr[SLOT]&&!imr[SLOT]);
            assign irq_tree_slot[15+g_irq_leaf]=4'(SLOT);
        end else begin:empty_leaf
            assign irq_tree_level[15+g_irq_leaf]=0;
            assign irq_tree_slot[15+g_irq_leaf]=15;
        end
    end
    for(g_irq_branch=0;g_irq_branch<15;g_irq_branch=g_irq_branch+1)begin:irq_branches
        wire take_right=irq_tree_level[2*g_irq_branch+2]>irq_tree_level[2*g_irq_branch+1];
        assign irq_tree_level[g_irq_branch]=take_right?irq_tree_level[2*g_irq_branch+2]:irq_tree_level[2*g_irq_branch+1];
        assign irq_tree_slot[g_irq_branch]=take_right?irq_tree_slot[2*g_irq_branch+2]:irq_tree_slot[2*g_irq_branch+1];
    end
endgenerate
always_comb begin
    regnum=9; candidate_level=icr[9][2:0];
    irq_level=irq_tree_level[0];
    chosen_slot=irq_level==0?4'd15:irq_tree_slot[0];
    chosen_vector=31;
    case(chosen_slot)
      0:chosen_vector=0;1:chosen_vector=1;2:chosen_vector=2;
      4:chosen_vector=8;5:chosen_vector=12;6:chosen_vector=16;
      7:chosen_vector=20;8:chosen_vector=4;9:chosen_vector=5;10:chosen_vector=6;
      default:chosen_vector=31;
    endcase
    irq_vector=ivnr | {3'd0,chosen_vector};
end
always_comb begin
    q=16'hffff;
    case(address)
      10'h000: q={amar[0],aamr[0]};
      10'h002: q={8'hff,aacr[0]};
      10'h004: q={amar[1],aamr[1]};
      10'h006: q={8'hff,aacr[1]};
      10'h008: q={8'hff,aacr[2]};
      10'h00a: q={8'hff,ator};
      10'h00c: q=arelr;
      10'h080,10'h082,10'h084,10'h086,10'h088,10'h08a,10'h08c,10'h08e,10'h090,10'h092:
        q={8'hff,icr[address[4:1]]};
      10'h094: q={5'd0,imr};
      10'h096: q={5'd0,ipr};
      10'h098: q={5'd0,iisr};
      10'h09a: q={8'hff,ivnr};
      10'h09c: q={8'hff,ieir};
      10'h100: q=pdir;
      10'h102: q={8'hff,pcr};
      10'h104: q=16'hff40;
      10'h106: q={8'hff,pcmr};
      10'h108: q=pmr;
      10'h10a: q=(pdata & pdir) | ~pdir;
      10'h10c: q={8'hff,ppr1};
      10'h10e: q={8'hff,ppr2};
      10'h200: q=tcr[0]; 10'h204: q=tmcr1[0]; 10'h20c: q=tctr[0];
      10'h220: q=tcr[1]; 10'h224: q=tmcr1[1]; 10'h228: q=tmcr2[1]; 10'h22c: q=tctr[1];
      10'h240: q=tcr[2]; 10'h244: q=tmcr1[2]; 10'h248: q=tmcr2[2]; 10'h24c: q=tctr[2];
      default: if (address>=10'h180 && address<=10'h1ae) q={8'hff,serial_regs[address-10'h180+1]};
    endcase
    if (!cs) q=16'hffff;
end
always_ff @(posedge clk) begin
    ext_irq_d<=ext_irq;
    if (reset) begin
        for(n=0;n<10;n=n+1) icr[n]<=7;
        imr<=11'h7f7; ipr<=0; iisr<=0; ivnr<=0; ieir<=0; ext_irq_d<=0;
        amar[0]<=0; amar[1]<=0; aamr[0]<=255; aamr[1]<=255;
        aacr[0]<=8'h3d; aacr[1]<=8'h18; aacr[2]<=8'h18; ator<=8'h08; arelr<=16'hfffc;
        pdir<=0; pcr<=0; pcmr<=0; pmr<=0; pdata<=0; ppr1<=0; ppr2<=0;
        for(n=0;n<48;n=n+1) serial_regs[n]<=0;
        serial_regs[1]<=8'hc2; serial_regs[17]<=8'hc2; serial_regs[33]<=8'hc2;
        serial_regs[7]<=4; serial_regs[23]<=4; serial_regs[39]<=4;
        serial_regs[15]<=8'h41;
        timer_done<=0; timer_alt<=0; unsupported_accesses<=0;
        for(n=0;n<3;n=n+1) begin
            tcr[n]<=n==0 ? 16'h0052 : 16'h0012;
            tmcr1[n]<=0; tmcr2[n]<=0; tctr[n]<=0; prescaler[n]<=0;
        end
    end else begin
        for(n=0;n<2;n=n+1) begin
            if(icr[n][3]) ipr[n]<=ext_irq[n];
            else if(ext_irq[n] && !ext_irq_d[n]) ipr[n]<=1;
        end
        for(n=0;n<3;n=n+1) begin
            if(!tcr[n][0]) begin tctr[n]<=0; prescaler[n]<=0; timer_done[n]<=0; timer_alt[n]<=0; end
            else if(cpu_ce && !tcr[n][1] && tcr[n][15:14]==0 && !timer_done[n]) begin
                prescaler[n]<=prescaler[n]+1;
                divider=tcr[n][13:10]>=8 ? 8 : integer'(tcr[n][13:10]);
                timer_tick=(integer'(prescaler[n]) & ((1<<divider)-1)) == ((1<<divider)-1);
                timer_max=(tcr[n][5:4]==2 || (tcr[n][5:4]==3 && timer_alt[n]))
                    ? {1'b0,tmcr2[n]} : {1'b0,tmcr1[n]};
                if(timer_max==0) timer_max=17'h10000;
                if(timer_tick) begin
                    if(tcr[n][5:4]!=0 && {1'b0,tctr[n]}==timer_max-1) begin
                        tctr[n]<=0;
                        if(tcr[n][2]) ipr[n+8]<=1;
                        if(!tcr[n][7]) timer_done[n]<=1;
                        if(tcr[n][5:4]==3) timer_alt[n]<=~timer_alt[n];
                    end else tctr[n]<=tctr[n]+1;
                end
            end
        end
        if(iack && chosen_slot!=15) begin
            iisr[chosen_slot]<=1;
            if(chosen_slot>=3 || !icr[chosen_slot][3]) ipr[chosen_slot]<=0;
        end
        if(cs && write) begin
            if(address>=10'h080 && address<=10'h092 && byte_enable[0])
                icr[address[4:1]]<=data[7:0] & (address[4:1]<3 ? 8'h1f : 8'h07);
            case(address)
              10'h000: begin if(byte_enable[1]) amar[0]<=data[15:8]; if(byte_enable[0]) aamr[0]<=data[7:0]; end
              10'h002: if(byte_enable[0]) aacr[0]<=data[7:0];
              10'h004: begin if(byte_enable[1]) amar[1]<=data[15:8]; if(byte_enable[0]) aamr[1]<=data[7:0]; end
              10'h006: if(byte_enable[0]) aacr[1]<=data[7:0];
              10'h008: if(byte_enable[0]) aacr[2]<=data[7:0];
              10'h00a: if(byte_enable[0]) ator<=data[7:0]&8'h0f;
              10'h00c: begin arelr<=merge_word(arelr,data,byte_enable)&16'hfffc;
                if((merge_word(arelr,data,byte_enable)&16'hfffc)!=16'hfffc) unsupported_accesses<=unsupported_accesses+1; end
              10'h094: imr<=merge_word({5'd0,imr},data,byte_enable)&16'h07f7;
              10'h096: begin
                ipr<=ipr & (merge_word(16'hffff,data,byte_enable) |
                    {8'd0,1'b0,(icr[2][3] ? 1'b1:1'b0),(icr[1][3] ? 1'b1:1'b0),(icr[0][3] ? 1'b1:1'b0)});
              end
              10'h098: iisr<=iisr & merge_word(16'hffff,data,byte_enable);
              10'h09a: if(byte_enable[0]) ivnr<=data[7:0]&8'he0;
              10'h09c: if(byte_enable[0]) ieir<=data[7:0]&8'h7f;
              10'h100: pdir<=merge_word(pdir,data,byte_enable);
              10'h102: if(byte_enable[0]) begin pcr<=data[7:0]; if(data[7:0]!=0) unsupported_accesses<=unsupported_accesses+1; end
              10'h106: if(byte_enable[0]) pcmr<=data[7:0];
              10'h108: pmr<=merge_word(pmr,data,byte_enable);
              10'h10a: pdata<=merge_word(pdata,data,byte_enable);
              10'h10c: if(byte_enable[0]) ppr1<=data[7:0];
              10'h10e: if(byte_enable[0]) ppr2<=data[7:0];
              10'h200,10'h220,10'h240: begin
                idx=integer'(address[6:5]);
                tcr[idx]<=idx==0 ? ((merge_word(tcr[idx],data,byte_enable)&16'hff87)|16'h0050)
                    : (merge_word(tcr[idx],data,byte_enable)&16'hfff7);
                timer_done[idx]<=0; timer_alt[idx]<=0;
                if((merge_word(tcr[idx],data,byte_enable)&16'hc000)!=0) unsupported_accesses<=unsupported_accesses+1;
              end
              10'h204,10'h224,10'h244: tmcr1[address[6:5]]<=merge_word(tmcr1[address[6:5]],data,byte_enable);
              10'h228,10'h248: tmcr2[address[6:5]]<=merge_word(tmcr2[address[6:5]],data,byte_enable);
              10'h20c,10'h22c,10'h24c: begin if(address[6:5]!=0) tctr[address[6:5]]<=0; end
              default: if(address>=10'h180 && address<=10'h1ae && byte_enable[0]) begin
                serial_regs[address-10'h180+1]<=data[7:0];
                if(address==10'h188 || address==10'h198 || address==10'h1a8 ||
                   ((address==10'h182 || address==10'h192 || address==10'h1a2) && data[7:0]!=0))
                    unsupported_accesses<=unsupported_accesses+1;
              end
            endcase
        end
    end
end
endmodule
