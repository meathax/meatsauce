// SPDX-License-Identifier: BSD-3-Clause
// Native ES5510 host/execution/storage integration (Christian Brunschen/MAME).
// A held external word-memory/clear interface owns the 2 MiB delay store.
// Reset clears the real instruction/GPR banks before any client is admitted.
module gs_es5510(
    input wire clk,cold_reset,reset,
    input wire host_req,host_write,input wire [7:0] host_addr,host_wdata,
    output wire host_ack,output wire [7:0] host_rdata,
    input wire step,halt_asserted,output wire ready,serial_ready,done,halted,fault,
    input wire serial_we,input wire [127:0] serial_input,output wire [127:0] serial_output,
    output wire dram_req,dram_write,output wire [19:0] dram_addr,
    output wire [15:0] dram_wdata,input wire dram_ack,input wire [15:0] dram_rdata,
    output wire clear_req,input wire clear_ack,
    input wire [7:0] inspect_reg,output wire [31:0] inspect_data,
    output wire [7:0] pc,debug_ccr,debug_cmr,
    output wire [63:0] debug_accumulator,
    output wire [31:0] debug_dol,output wire [1:0] debug_dol_count,
    output wire [15:0] debug_dil,
    output wire [23:0] debug_dbase,debug_dlength,
    output wire [4:0] debug_memshift
);
    (* ramstyle="M10K" *) reg [23:0] gpr_a[0:191],gpr_b[0:191];
    (* ramstyle="M10K" *) reg [47:0] instructions[0:159];
    reg [23:0] gpr_q_a,gpr_q_b;
    reg [47:0] instr_q;
    reg reset_seen=0,store_clear=1,delay_clear=1;
    reg [7:0] clear_index=0;
    wire resetting=reset || cold_reset || store_clear || delay_clear;
    wire es_ready,es_fault,host_fault,host_busy;
    wire hg_req,hg_write,hi_req,hi_write,hs_req,hs_write,hd_req,hd_write,hc_req,hh_req;
    wire [7:0] hg_addr,hi_addr,hs_addr;
    wire [23:0] hg_wdata,hs_wdata;
    wire [47:0] hi_wdata;
    wire [19:0] hd_addr;
    wire [15:0] hd_wdata;
    reg hg_ack,hi_ack,hs_ack,hh_ack;
    reg hg_seen,hi_seen,hs_seen,hh_seen;
    wire ei_req,er_req,ew_req,ed_req,ed_write;
    wire [7:0] ei_addr,er_a,er_b,ew_addr;
    wire [23:0] ew_data;
    wire [19:0] ed_addr;
    wire [15:0] ed_wdata;
    wire ei_ack,er_ack;
    reg ew_ack,ei_seen,er_seen,ew_seen;
    reg [7:0] read_a_q,read_b_q,read_i_q;
    reg read_valid=0;
    reg bypass_a,bypass_b,bypass_i;
    reg [23:0] bypass_gpr_data;
    reg [47:0] bypass_instr_data;
    wire [23:0] execution_a=bypass_a ? bypass_gpr_data:gpr_q_a;
    wire [23:0] execution_b=bypass_b ? bypass_gpr_data:gpr_q_b;
    wire [47:0] execution_i=bypass_i ? bypass_instr_data:instr_q;
    // Synchronous data is valid only for the captured addresses. Forward
    // same-edge writes explicitly, independent of physical RAM collision mode.
    assign er_ack=er_req && read_valid && !resetting && !hg_req &&
                  read_a_q==er_a && read_b_q==er_b;
    assign ei_ack=ei_req && read_valid && !resetting && !hi_req && read_i_q==ei_addr;
    wire [31:0] special_data;
    wire [7:0] serial_control;
    wire refresh_disable;
    wire hg_accept=hg_req && !hg_seen && !resetting;
    wire hi_accept=hi_req && !hi_seen && !resetting;
    wire hs_accept=hs_req && !hs_seen && es_ready && !resetting;
    wire hh_accept=hh_req && !hh_seen && es_ready && !resetting;
    wire ew_accept=ew_req && !ew_seen && !resetting;
    wire [7:0] read_a=hg_req ? hg_addr:er_a;
    wire [7:0] read_i=hi_req ? hi_addr:ei_addr;
    wire write_gpr=hg_accept && hg_write || ew_accept;
    wire [7:0] write_gpr_addr=hg_accept && hg_write ? hg_addr:ew_addr;
    wire [23:0] write_gpr_data=hg_accept && hg_write ? hg_wdata:ew_data;
    integer i;
    initial begin
        for(i=0;i<192;i=i+1)begin gpr_a[i]=0;gpr_b[i]=0;end
        for(i=0;i<160;i=i+1)instructions[i]=0;
    end
    // Free read registers and complete-word writes keep native storage in RAM.
    always @(posedge clk)begin
        gpr_q_a<=gpr_a[read_a];gpr_q_b<=gpr_b[er_b];instr_q<=instructions[read_i];
        read_a_q<=read_a;read_b_q<=er_b;read_i_q<=read_i;read_valid<=!resetting;
        bypass_a<=write_gpr && write_gpr_addr<192 && write_gpr_addr==read_a;
        bypass_b<=write_gpr && write_gpr_addr<192 && write_gpr_addr==er_b;
        bypass_gpr_data<=write_gpr_data;
        bypass_i<=hi_accept && hi_write && hi_addr<160 && hi_addr==read_i;
        bypass_instr_data<=hi_wdata;
        if(store_clear)begin
            gpr_a[clear_index]<=0;gpr_b[clear_index]<=0;
            if(clear_index<160)instructions[clear_index]<=0;
        end else begin
            if(write_gpr && write_gpr_addr<192)begin
                gpr_a[write_gpr_addr]<=write_gpr_data;gpr_b[write_gpr_addr]<=write_gpr_data;
            end
            if(hi_accept && hi_write && hi_addr<160)instructions[hi_addr]<=hi_wdata;
        end
    end
    always @(posedge clk)begin
        reset_seen<=reset || cold_reset;
        if((reset || cold_reset) && !reset_seen)begin store_clear<=1;delay_clear<=1;clear_index<=0;end
        else if(store_clear)begin
            if(clear_index==191)begin store_clear<=0;clear_index<=0;end
            else clear_index<=clear_index+1'b1;
        end
        if(delay_clear && clear_ack)delay_clear<=0;
        hg_ack<=hg_accept;hi_ack<=hi_accept;hs_ack<=hs_accept;hh_ack<=hh_accept;
        ew_ack<=ew_accept;
        if(!hg_req)hg_seen<=0;else if(hg_accept)hg_seen<=1;
        if(!hi_req)hi_seen<=0;else if(hi_accept)hi_seen<=1;
        if(!hs_req)hs_seen<=0;else if(hs_accept)hs_seen<=1;
        if(!hh_req)hh_seen<=0;else if(hh_accept)hh_seen<=1;
        if(!ei_req)ei_seen<=0;else if(ei_ack)ei_seen<=1;
        if(!er_req)er_seen<=0;else if(er_ack)er_seen<=1;
        if(!ew_req)ew_seen<=0;else if(ew_accept)ew_seen<=1;
        if(resetting)begin
            hg_seen<=0;hi_seen<=0;hs_seen<=0;hh_seen<=0;ei_seen<=0;er_seen<=0;ew_seen<=0;
            hg_ack<=0;hi_ack<=0;hs_ack<=0;hh_ack<=0;ew_ack<=0;
        end
    end
    assign ready=es_ready && !host_req && !host_busy && !resetting;
    // Native halted pump routing continues while a host delay-store clear or
    // register transaction is pending. Serial lanes do not use that store.
    assign serial_ready=es_ready && !resetting;
    assign fault=es_fault || host_fault;
    assign clear_req=delay_clear || hc_req;
    assign dram_req=!resetting && (hd_req || ed_req);
    assign dram_write=hd_req ? hd_write:ed_write;
    assign dram_addr=hd_req ? hd_addr:ed_addr;
    assign dram_wdata=hd_req ? hd_wdata:ed_wdata;
    assign inspect_data=special_data;
    gs_es5510_host host(
        .clk(clk),.reset(resetting),.req(host_req),.write(host_write),.reg_addr(host_addr),.wdata(host_wdata),
        .ack(host_ack),.rdata(host_rdata),.engine_idle(es_ready),.halted(halted),.halt_asserted(halt_asserted),
        .gpr_req(hg_req),.gpr_write(hg_write),.gpr_addr(hg_addr),.gpr_wdata(hg_wdata),.gpr_ack(hg_ack),.gpr_rdata(gpr_q_a),
        .instr_req(hi_req),.instr_write(hi_write),.instr_addr(hi_addr),.instr_wdata(hi_wdata),.instr_ack(hi_ack),.instr_rdata(instr_q),
        .special_req(hs_req),.special_write(hs_write),.special_addr(hs_addr),.special_wdata(hs_wdata),
        .special_ack(hs_ack),.special_rdata(special_data),
        .dram_req(hd_req),.dram_write(hd_write),.dram_addr(hd_addr),.dram_wdata(hd_wdata),
        .dram_ack(dram_ack && hd_req),.dram_rdata(dram_rdata),.clear_req(hc_req),.clear_ack(clear_ack),
        .force_halt(hh_req),.halt_ack(hh_ack),.busy(host_busy),.fault(host_fault),
        .serial_control(serial_control),.refresh_disable(refresh_disable)
    );
    gs_es5510_execute execution(
        .clk(clk),.cold_reset(cold_reset),.reset(resetting),.step(step && ready),.halt_asserted(halt_asserted),
        .ready(es_ready),.done(done),.halted(halted),.fault(es_fault),.pc(pc),
        .ir_req(ei_req),.ir_addr(ei_addr),.ir_ack(ei_ack),.ir_data(execution_i),
        .rf_req(er_req),.rf_a(er_a),.rf_b(er_b),.rf_ack(er_ack),.rf_data_a(execution_a),.rf_data_b(execution_b),
        .rf_we(ew_req),.rf_waddr(ew_addr),.rf_wdata(ew_data),.rf_wack(ew_ack),
        .dram_req(ed_req),.dram_write(ed_write),.dram_addr(ed_addr),.dram_wdata(ed_wdata),
        .dram_ack(dram_ack && !hd_req && !resetting),.dram_rdata(dram_rdata),
        .host_we(hs_accept && hs_write),.host_halt(hh_accept),.host_reg(hs_addr),.host_data(hs_wdata),
        .inspect_reg(hs_req ? hs_addr:inspect_reg),.inspect_data(special_data),
        .serial_we(serial_we && serial_ready),.serial_input(serial_input),.serial_output(serial_output),
        .debug_accumulator(debug_accumulator),.debug_ccr(debug_ccr),.debug_cmr(debug_cmr),
        .debug_dol(debug_dol),.debug_dol_count(debug_dol_count),.debug_dil(debug_dil),
        .debug_dbase(debug_dbase),.debug_dlength(debug_dlength),.debug_memshift(debug_memshift)
    );
endmodule
