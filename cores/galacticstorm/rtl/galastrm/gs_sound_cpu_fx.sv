// SPDX-License-Identifier: GPL-3.0-or-later
// MC68000 sound adapter. A request belongs to one UDS/LDS strobe, not one AS.
module gs_sound_cpu_fx #(
    parameter integer SYS_HZ=64000000,CPU_HZ=15238090
)(
    input wire clk,reset,pause,input wire [2:0] irq_n,
    output reg bus_req,output reg [31:0] bus_addr,
    output reg [15:0] bus_wdata,output reg [1:0] bus_be,
    output reg bus_write,bus_fetch,output reg [2:0] bus_fc,
    input wire bus_ack,input wire [15:0] bus_rdata,
    // Assert only for a selected external-memory transaction. Device and
    // DUART/IACK waits retain ordinary CPU phases and never earn credit.
    input wire bus_external_wait,
    output wire paused,bus_idle,
    output wire phi1,phi2,output wire [23:0] debt,
    output wire earned,repaid,nominal,output wire fault,
    output wire [23:0] raw_addr,output wire [2:0] raw_fc,
    output wire raw_as_n,raw_uds_n,raw_lds_n,raw_rw_n
);
    wire [23:1] eab;
    wire [15:0] data_out;
    wire dtack_n,next_phi1,idle_no_debt;
    reg [15:0] response;
    reg response_ready,seen,pause_hold,external_owner;
    wire strobe=!raw_as_n && !(raw_uds_n && raw_lds_n);
    wire can_pause=pause && idle_no_debt && !bus_req && !response_ready && next_phi1;
    wire run=!(pause_hold || can_pause);
    assign paused=pause_hold;
    assign bus_idle=!strobe && !bus_req && !response_ready;
    assign raw_addr={eab,1'b0};
    wire legitimate=raw_fc==3'b111 || (!raw_as_n && !(external_owner || bus_external_wait));
    gs_fx68k_cen #(.SYS_HZ(SYS_HZ),.CPU_HZ(CPU_HZ)) timing(
        .clk(clk),.reset(reset),.run(run),.as_n(raw_as_n),.ds_n({raw_uds_n,raw_lds_n}),
        .busy(!response_ready),.legitimate(legitimate),
        .retire_ready(response_ready && !dtack_n && raw_fc!=3'b111),
        .phi1(phi1),.phi2(phi2),
        .next_phi1(next_phi1),.idle_no_debt(idle_no_debt),.dtack_n(dtack_n),
        .debt(debt),.earned(earned),.repaid(repaid),.nominal(nominal),.overflow(fault));
    fx68k cpu(.clk(clk),.extReset(reset),.pwrUp(reset),
        .enPhi1(phi1),.enPhi2(phi2),.HALTn(!pause),
        .eRWn(raw_rw_n),.ASn(raw_as_n),.LDSn(raw_lds_n),.UDSn(raw_uds_n),
        .FC0(raw_fc[0]),.FC1(raw_fc[1]),.FC2(raw_fc[2]),
        .DTACKn(dtack_n),.VPAn(1'b1),.BERRn(1'b1),.BRn(1'b1),.BGACKn(1'b1),
        .IPL0n(irq_n[0]),.IPL1n(irq_n[1]),.IPL2n(irq_n[2]),
        .iEdb(response),.oEdb(data_out),.eab(eab),
        .E(),.VMAn(),.BGn(),.oRESETn(),.oHALTEDn());
    always @(posedge clk)begin
        if(reset)begin
            bus_req<=0;bus_addr<=0;bus_wdata<=0;bus_be<=0;
            bus_write<=0;bus_fetch<=0;bus_fc<=0;
            response<=0;response_ready<=0;seen<=0;pause_hold<=0;external_owner<=0;
        end else begin
            if(!pause)pause_hold<=0;
            else if(can_pause)pause_hold<=1;
            if(!strobe)begin seen<=0;response_ready<=0;external_owner<=0;end
            if(bus_req && bus_external_wait)external_owner<=1;
            if(strobe && !seen && !bus_req)begin
                seen<=1;bus_req<=1;bus_addr<={8'b0,eab,1'b0};
                bus_wdata<=data_out;bus_be<={!raw_uds_n,!raw_lds_n};
                bus_write<=!raw_rw_n;bus_fc<=raw_fc;
                bus_fetch<=raw_fc[1] && !raw_fc[0];
            end
            if(bus_req && bus_ack)begin
                bus_req<=0;response<=bus_rdata;response_ready<=1;
            end
        end
    end
endmodule
