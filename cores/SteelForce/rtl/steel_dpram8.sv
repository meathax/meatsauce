// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from rmonic79/Arcade-DenjinMakai_MiSTer spram_dp.sv,
// Author: Umberto Parisi (rmonic79). See rtl/PROVENANCE_MEMORY.md.
// Byte-wide true dual-port RAM; CPU reads/writes A and video reads B.
// Address capture supplies one cycle of read latency. No reset clears RAM.
module steel_dpram8 #(parameter AW=15)(
    input wire clk, cpu_we,
    input wire [AW-1:0] cpu_addr,
    input wire [7:0] cpu_data,
    output wire [7:0] cpu_q,
    input wire video_en,
    input wire [AW-1:0] video_addr,
    output wire [7:0] video_q
);
`ifdef SIMULATION
    reg [7:0] memory [0:(1<<AW)-1];
    reg [7:0] aq,bq;
    assign cpu_q=aq;
    assign video_q=bq;
    always @(posedge clk) begin
        if(cpu_we) memory[cpu_addr]<=cpu_data;
        aq<=memory[cpu_addr];
        if(video_en) bq<=memory[video_addr];
    end
`else
    altsyncram #(
        .operation_mode("BIDIR_DUAL_PORT"),
        .intended_device_family("Cyclone V"), .ram_block_type("M10K"),
        .width_a(8), .widthad_a(AW), .numwords_a(1<<AW),
        .width_b(8), .widthad_b(AW), .numwords_b(1<<AW),
        .width_byteena_a(1), .width_byteena_b(1),
        .address_reg_b("CLOCK0"), .rdcontrol_reg_b("CLOCK0"),
        .indata_reg_b("CLOCK0"), .byteena_reg_b("CLOCK0"),
        .wrcontrol_wraddress_reg_b("CLOCK0"),
        .outdata_reg_a("UNREGISTERED"), .outdata_reg_b("UNREGISTERED"),
        .clock_enable_input_a("BYPASS"), .clock_enable_input_b("BYPASS"),
        .clock_enable_output_a("BYPASS"), .clock_enable_output_b("BYPASS"),
        .read_during_write_mode_mixed_ports("DONT_CARE"),
        .power_up_uninitialized("TRUE")
    ) ram (
        .clock0(clk), .clock1(),
        .wren_a(cpu_we), .address_a(cpu_addr), .data_a(cpu_data), .q_a(cpu_q),
        .wren_b(1'b0), .address_b(video_addr), .data_b(8'b0), .q_b(video_q),
        .rden_a(1'b1), .rden_b(video_en),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
        .byteena_a(1'b1), .byteena_b(1'b1),
        .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
        .eccstatus()
    );
`endif
endmodule
