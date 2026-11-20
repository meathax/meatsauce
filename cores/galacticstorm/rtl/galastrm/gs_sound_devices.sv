// SPDX-License-Identifier: GPL-3.0-or-later
// Connected sound CPU, sampler and host register frontend.
// Dry diagnostic output only: ES5510 execution/pump routing is still required.
module gs_sound_devices #(parameter integer SYS_HZ=32000000)(
    input logic clk, reset, pause,
    output logic mem_req, mem_write,
    output logic [23:0] mem_addr,
    output logic [15:0] mem_wdata,
    output logic [1:0] mem_be,
    input logic mem_ack,
    input logic [15:0] mem_rdata,
    output logic sm_req,
    output logic [22:3] sm_addr,
    input logic [63:0] sm_line,
    input logic sm_valid, sm_busy,
    output logic dsp_halt, running,
    output logic debug_req, debug_ack, debug_write, debug_fetch,
    output logic [31:0] debug_addr,
    output logic [15:0] debug_wdata,
    output logic [1:0] debug_be,
    output logic [2:0] debug_fc,
    output logic debug_irq,
    output logic sample_valid,
    output logic signed [15:0] dry_l, dry_r,
    output logic [15:0] sampler_overrun, sampler_drop
);
    logic chip_req, chip_write, chip_ack;
    logic [23:0] chip_addr;
    logic [15:0] chip_wdata,chip_rdata;
    logic [1:0] chip_be;
    gs_sound #(.SYS_HZ(SYS_HZ)) board(.*);
    logic seen;
    wire accept=chip_req && !seen;
    always_ff @(posedge clk) begin
        if(reset || !chip_req) seen<=0;
        else seen<=1;
    end
    wire es_sel=chip_addr[23:5]==19'h10000;
    wire host_sel=chip_addr[23:9]==15'h1300;
    wire bank_sel=chip_addr[23:6]==18'hc000;
    wire volume_sel=chip_addr[23:2]==22'hd0000;
    logic [15:0] es_rdata;
    logic es_valid;
    logic [7:0] host_rdata, irqv;
    logic [4:0] active;
    logic [7:0][19:0] channels;
    logic [31:0] phase;
    logic [8:0] sample_div;
    logic sample_tick;
    wire [32:0] phase_next={1'b0,phase}+33'd15238090;
    wire crystal_ce=phase_next>=33'(SYS_HZ);
    wire [9:0] sample_period=({5'd0,active}+10'd1)<<4;
    always_ff @(posedge clk) begin
        sample_tick<=0;
        if(reset) begin phase<=0; sample_div<=0; end
        else if(!pause) begin
            phase<=crystal_ce ? 32'(phase_next-33'(SYS_HZ)) : phase_next[31:0];
            if(crystal_ce) begin
                if({1'b0,sample_div}+10'd1>=sample_period) begin sample_div<=0; sample_tick<=1; end
                else sample_div<=sample_div+1'b1;
            end
        end
    end
    rf_es5505 sampler(
        .clk(clk),.reset(reset),
        .es_we(accept && chip_write && es_sel),.es_reg(chip_addr[4:1]),
        .es_data(chip_wdata),.es_be(chip_be),
        .bk_we(accept && chip_write && bank_sel),.bk_voice(chip_addr[5:1]),
        .bk_data(chip_wdata[2:0]),.bank_mask(3'd7),
        .sm_req(sm_req),.sm_addr(sm_addr),.sm_line(sm_line),.sm_valid(sm_valid),.sm_busy(sm_busy),
        .tick(sample_tick),.out_valid(sample_valid),.out_ch(channels),.out_active(active),.irqv_out(irqv),
        .rd_req(chip_req && !chip_write && es_sel),.rd_reg(chip_addr[4:1]),
        .rd_data(es_rdata),.rd_valid(es_valid),
        .irqv_ack(accept && !chip_write && es_sel && chip_addr[4:1]==4'he),
        .dbg_overrun(sampler_overrun),.dbg_miss(),.dbg_wqdrop(sampler_drop)
    );
    rf_es5510_host host(
        .clk(clk),.reset(reset),.reg_a(chip_addr[8:1]),
        .we(accept && chip_write && host_sel && chip_be[0]),
        .wdata(chip_wdata[7:0]),.rdata(host_rdata)
    );
    always_comb begin
        chip_ack=chip_req;
        chip_rdata=16'hffff;
        if(es_sel && !chip_write) begin chip_ack=es_valid; chip_rdata=es_rdata; end
        else if(host_sel && !chip_write && chip_be[0]) chip_rdata={8'hff,host_rdata};
    end
    logic signed [22:0] sum_l,sum_r;
    always_comb begin
        sum_l={{3{channels[0][19]}},channels[0]} + {{3{channels[2][19]}},channels[2]} +
              {{3{channels[4][19]}},channels[4]} + {{3{channels[6][19]}},channels[6]};
        sum_r={{3{channels[1][19]}},channels[1]} + {{3{channels[3][19]}},channels[3]} +
              {{3{channels[5][19]}},channels[5]} + {{3{channels[7][19]}},channels[7]};
    end
    rf_mb87078 volume(
        .clk(clk),.reset(reset),.we(accept && chip_write && volume_sel && chip_be[1]),
        .offset(~chip_addr[1]),.data(chip_wdata[15:8]),
        .in_valid(sample_valid),.in_l(sum_l),.in_r(sum_r),.out_l(dry_l),.out_r(dry_r)
    );
endmodule
