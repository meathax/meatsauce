// SPDX-License-Identifier: BSD-3-Clause
// Galastrm register front end, derived from the pinned MAME BSD models.
// Copyright-holders of reference models: Nicola Salmoria, David Graves.
// This module does not implement tile rendering or TC0610 affine execution.
module gs_video_regs (
    input logic clk, reset, cpu_req, cpu_write,
    input logic [23:0] cpu_addr,
    input logic [1:0] cpu_be,
    input logic [15:0] cpu_wdata,
    output logic cpu_ack,
    output logic [15:0] cpu_rdata,
    output wire [383:0] scp_controls,
    output wire [127:0] scn_controls,
    output wire [255:0] affine_controls
);
    logic [15:0] scp [0:23];
    logic [15:0] scn [0:7];
    logic [15:0] affine [0:15];
    logic [15:0] selector [0:1];
    wire scp_sel = cpu_addr>=24'h830000 && cpu_addr<=24'h83002f;
    wire scn_sel = cpu_addr[23:4]==20'hd2000;
    wire bank0_sel = cpu_addr[23:2]==22'h2c0000;
    wire bank1_sel = cpu_addr[23:2]==22'h300000;
    wire bank = bank1_sel;
    wire [15:0] data_masked = {cpu_be[1]?cpu_wdata[15:8]:8'b0,cpu_be[0]?cpu_wdata[7:0]:8'b0};
    function automatic [15:0] merge_word(input [15:0] old);
        merge_word={cpu_be[1]?cpu_wdata[15:8]:old[15:8],cpu_be[0]?cpu_wdata[7:0]:old[7:0]};
    endfunction
    integer i;
    initial begin
        for(i=0;i<16;i=i+1) affine[i]=0;
        selector[0]=0;selector[1]=0;
    end
    genvar item;
    generate
        for(item=0;item<24;item=item+1) begin : scp_bus
            assign scp_controls[item*16+:16]=scp[item];
        end
        for(item=0;item<8;item=item+1) begin : scn_bus
            assign scn_controls[item*16+:16]=scn[item];
        end
        for(item=0;item<16;item=item+1) begin : affine_bus
            assign affine_controls[item*16+:16]=affine[item];
        end
    endgenerate
    always_ff @(posedge clk) begin
        cpu_ack<=0;
        if(reset) begin
            for(i=0;i<24;i=i+1) scp[i]<=0;
            for(i=0;i<8;i=i+1) scn[i]<=0;
            cpu_rdata<=0;
        end else if(cpu_req && !cpu_ack && (scp_sel || scn_sel || bank0_sel || bank1_sel)) begin
            cpu_ack<=1;
            cpu_rdata<=16'hffff;
            if(scp_sel) begin
                if(cpu_write) scp[cpu_addr[5:1]]<=merge_word(scp[cpu_addr[5:1]]);
                else cpu_rdata<=scp[cpu_addr[5:1]];
            end else if(scn_sel) begin
                if(cpu_write) scn[cpu_addr[3:1]]<=merge_word(scn[cpu_addr[3:1]]);
                else cpu_rdata<=scn[cpu_addr[3:1]];
            end else if(cpu_write && |cpu_be) begin
                if(!cpu_addr[1]) selector[bank]<=data_masked;
                else if(selector[bank]<8) affine[{bank,selector[bank][2:0]}]<=data_masked;
            end
        end
    end
endmodule
