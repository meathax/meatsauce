// Explicit dual-clock RAM used by the VHDL scaler's Avalon/video and
// coefficient-clock crossings. Imported unchanged from the documented Sega
// Y Board donor; SHA-256 863e9d3531c30d19cace6e7c89ae8526aaf367b850cf6d1ee99270789cba31ca.
module yb_ascal_dual_ram #(
    parameter integer ADDR_WIDTH = 1,
    parameter integer DATA_WIDTH = 1,
    parameter integer NUM_WORDS = (1 << ADDR_WIDTH)
) (
    input logic clock_a, input logic [ADDR_WIDTH-1:0] address_a,
    input logic [DATA_WIDTH-1:0] data_a, input logic wren_a,
    output logic [DATA_WIDTH-1:0] q_a,
    input logic clock_b, input logic [ADDR_WIDTH-1:0] address_b,
    input logic [DATA_WIDTH-1:0] data_b, input logic wren_b,
    output logic [DATA_WIDTH-1:0] q_b
);
`ifdef SYNTHESIS
    altsyncram ram (
        .clock0(clock_a), .address_a(address_a), .data_a(data_a),
        .wren_a(wren_a), .q_a(q_a),
        .clock1(clock_b), .address_b(address_b), .data_b(data_b),
        .wren_b(wren_b), .q_b(q_b),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0),
        .addressstall_b(1'b0), .byteena_a(1'b1), .byteena_b(1'b1),
        .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1),
        .clocken3(1'b1), .eccstatus(), .rden_a(1'b1), .rden_b(1'b1)
    );
    defparam
        ram.address_reg_a = "UNREGISTERED", ram.address_reg_b = "CLOCK1",
        ram.clock_enable_input_a = "BYPASS", ram.clock_enable_input_b = "BYPASS",
        ram.clock_enable_output_a = "BYPASS", ram.clock_enable_output_b = "BYPASS",
        ram.intended_device_family = "Cyclone V", ram.indata_reg_b = "CLOCK1",
        ram.lpm_type = "altsyncram", ram.numwords_a = NUM_WORDS,
        ram.numwords_b = NUM_WORDS, ram.operation_mode = "BIDIR_DUAL_PORT",
        ram.outdata_reg_a = "UNREGISTERED", ram.outdata_reg_b = "UNREGISTERED",
        ram.power_up_uninitialized = "FALSE", ram.ram_block_type = "M10K",
        ram.read_during_write_mode_mixed_ports = "DONT_CARE",
        ram.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
        ram.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
        ram.widthad_a = ADDR_WIDTH, ram.widthad_b = ADDR_WIDTH,
        ram.width_a = DATA_WIDTH, ram.width_b = DATA_WIDTH,
        ram.width_byteena_a = 1, ram.width_byteena_b = 1;
`else
    logic [DATA_WIDTH-1:0] mem [0:NUM_WORDS-1];
    integer init_i;
    assign q_a = mem[address_a];
    assign q_b = mem[address_b];
    initial for (init_i = 0; init_i < NUM_WORDS; init_i = init_i + 1) mem[init_i] = '0;
    always_ff @(posedge clock_b) if (wren_b) mem[address_b] <= data_b;
`endif
endmodule
