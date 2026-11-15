// Exact ASO ROM RAM contract: registered addresses and persistent download data.
module dpram_dc #(
    parameter init_file = " ",
    parameter integer widthad_a = 10,
    parameter integer width_a = 8,
    parameter outdata_reg_a = "UNREGISTERED",
    parameter outdata_reg_b = "UNREGISTERED"
) (
    input [widthad_a-1:0] address_a, address_b,
    input clock_a, clock_b,
    input tri0 [width_a-1:0] data_a, data_b,
    input tri0 wren_a, wren_b,
    input tri1 [(width_a/8)-1:0] byteena_a, byteena_b,
    output [width_a-1:0] q_a, q_b
);
`ifdef VERILATOR
    reg [width_a-1:0] mem [0:(1<<widthad_a)-1];
    reg [widthad_a-1:0] addr_a_q, addr_b_q;
    reg [width_a-1:0] data_a_q, data_b_q;
    integer i;
    initial begin
        addr_a_q = 0; addr_b_q = 0; data_a_q = 0; data_b_q = 0;
        for (i=0; i<(1<<widthad_a); i=i+1) mem[i] = 0;
        if (init_file != " " && init_file != "") $readmemh(init_file, mem);
    end
    always @(posedge clock_a) begin
        addr_a_q <= address_a;
        data_a_q <= wren_a ? data_a : mem[address_a];
        for (integer b=0; b<width_a/8; b=b+1)
            if (wren_a && byteena_a[b]) mem[address_a][b*8+:8] <= data_a[b*8+:8];
    end
    always @(posedge clock_b) begin
        addr_b_q <= address_b;
        data_b_q <= wren_b ? data_b : mem[address_b];
        for (integer b=0; b<width_a/8; b=b+1)
            if (wren_b && byteena_b[b]) mem[address_b][b*8+:8] <= data_b[b*8+:8];
    end
    assign q_a = outdata_reg_a == "UNREGISTERED" ? mem[addr_a_q] : data_a_q;
    assign q_b = outdata_reg_b == "UNREGISTERED" ? mem[addr_b_q] : data_b_q;
`else
    altsyncram #(
        .operation_mode("BIDIR_DUAL_PORT"), .intended_device_family("Cyclone V"),
        .width_a(width_a), .width_b(width_a), .widthad_a(widthad_a),
        .widthad_b(widthad_a), .numwords_a(1<<widthad_a), .numwords_b(1<<widthad_a),
        .width_byteena_a(width_a/8), .width_byteena_b(width_a/8),
        .address_reg_b("CLOCK1"), .indata_reg_b("CLOCK1"),
        .wrcontrol_wraddress_reg_b("CLOCK1"), .byteena_reg_b("CLOCK1"),
        .outdata_reg_a(outdata_reg_a), .outdata_reg_b(outdata_reg_b),
        .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
        .power_up_uninitialized("FALSE"), .init_file(init_file), .lpm_type("altsyncram")
    ) ram (
        .clock0(clock_a), .clock1(clock_b), .address_a(address_a), .address_b(address_b),
        .data_a(data_a), .data_b(data_b), .wren_a(wren_a), .wren_b(wren_b),
        .byteena_a(byteena_a), .byteena_b(byteena_b), .q_a(q_a), .q_b(q_b),
        .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
        .rden_a(1'b1), .rden_b(1'b1), .eccstatus()
    );
`endif
endmodule
