//============================================================================
//  Large 16-bit true-dual-port block RAM used by System 32 work, sprite and
//  video RAM.  Quartus 17 expands the equivalent unpacked-array RTL into a
//  multi-gigabyte logic netlist instead of inferring Cyclone V M10Ks.
//
//  The Intel primitive is confined to integrated synthesis.  Simulation with
//  Icarus, Verilator, or ModelSim uses the cycle-equivalent behavioural model
//  and does not depend on altera_mf simulation libraries.
//
//  2026-08-06: video_ram and sprite_ram tie data_b/byteena_b/wren_b to
//  constants (port B is a read-only renderer-fetch port for both), and one
//  of BIDIR_DUAL_PORT's always-synthesized port-B write-control registers
//  (reported by the fitter as .../portb_we_reg) sits on a real setup-timing
//  critical path. Tried switching those two instances to operation_mode=
//  "DUAL_PORT" (which should drop the unused write pipeline) via a second
//  altsyncram instantiation gated by a PORT_B_READ_ONLY parameter -- this
//  failed synthesis with "q_a is missing source" errors, meaning the
//  defparam set used was not a legal DUAL_PORT configuration for this
//  Quartus version. Reverted rather than keep guessing at undocumented
//  megafunction parameters. Revisit with the actual Intel altsyncram HDL
//  template/documentation (MegaWizard-generated reference) in hand before
//  trying again; do not hand-author another attempt blind.
//
//  Mixed-port collisions (sprite_ram, video_ram)
//  ---------------------------------------------
//  Both renderer RAMs run port A on clk_sys (V60 writes) and port B on
//  clk_ram (renderer fetch), with read_during_write_mode_mixed_ports =
//  DONT_CARE.  On a Cyclone V M10K that setting means a port-B read of the
//  address port A is writing in the same cycle returns UNDEFINED bits, not
//  old or new data.  On the System 32 PCB the CPU and the video/sprite chips
//  share one SRAM through the bus controller, so their accesses are
//  serialised and this case cannot occur: the hazard is introduced by the
//  dual-port BRAM, not by the board.  A single corrupted 16-bit word is one
//  wrong sprite descriptor or tile word for one frame.
//
//  The behavioural branch below always returned clean old data, so no
//  simulation could ever observe the defect.  MIXED_COLLISION_FWD now
//  resolves the collision by forwarding the port-A word to port B, which is
//  the write-first result a serialised board access would produce, and
//  SIM_COLLISION_POISON lets a bench model the undefined read so the fix is
//  falsifiable.
//
//  Limits: clk_sys is a phase-related divide-by-two of clk_ram, so wren_a is
//  observed high on two consecutive clock_b edges and the forward makes the
//  write visible up to one clk_ram cycle before the M10K commits it.  That is
//  still a legal serialisation (renderer sees the new word) and is
//  deterministic, which the undefined read is not.  A partial-byteena write
//  colliding with a port-B read still leaves the UNWRITTEN lane sourced from
//  the M10K's undefined output; closing that requires moving port A onto
//  clk_ram so the pair can use the deterministic same-clock OLD_DATA mode.
//============================================================================

module s32_big_dpram #(
    parameter integer ADDR_WIDTH = 16,
    parameter integer NUM_WORDS  = (1 << ADDR_WIDTH),
    // Asynchronous-clock collisions have no deterministic old/new ordering
    // in Cyclone V hardware.  Such clients select DONT_CARE to avoid an
    // invalid mixed-port feed-through request; same-clock clients keep OLD.
    parameter         MIXED_RDW_MODE = "OLD_DATA",
    // Port B is a read-only renderer port for video_ram and sprite_ram.  Do
    // not build the unused BIDIR_DUAL_PORT write-control pipeline for those
    // clients; the internal portb_we_reg otherwise becomes a long timing
    // launch point from the M10K to every renderer fetch register.
    parameter bit     PORT_B_READ_ONLY = 1'b0,
    // Resolve a mixed-port same-address collision on the read-only B port by
    // forwarding the port-A word.  Defaults on for exactly the two DONT_CARE
    // renderer clients.  The design must never instantiate this at 0; the
    // override exists so a bench can run the unresolved path as a control.
    parameter bit     MIXED_COLLISION_FWD = PORT_B_READ_ONLY,
    // Simulation only.  Model the M10K's undefined mixed-port read as a word
    // that is neither the old nor the new value, so a bench proves the
    // collision was resolved rather than that it happened to land on a legal
    // word.  Ignored by the synthesis branch.
    parameter bit     SIM_COLLISION_POISON = 1'b0
) (
    input                       clock_a,
    input      [ADDR_WIDTH-1:0] address_a,
    input                [15:0] data_a,
    input                 [1:0] byteena_a,
    input                       wren_a,
    output               [15:0] q_a,

    input                       clock_b,
    input      [ADDR_WIDTH-1:0] address_b,
    input                [15:0] data_b,
    input                 [1:0] byteena_b,
    input                       wren_b,
    output               [15:0] q_b
);

// Raw port-B output of the storage array, before mixed-port collision
// resolution.  This is the net that carries undefined bits on a same-address
// mixed-port access in real silicon.
wire [15:0] q_b_ram;

`ifdef ALTERA_RESERVED_QIS
altsyncram ram (
    .clock0(clock_a),
    .address_a(address_a),
    .data_a(data_a),
    .byteena_a(byteena_a),
    .wren_a(wren_a),
    .q_a(q_a),

    .clock1(clock_b),
    .address_b(address_b),
    .data_b(data_b),
    .byteena_b(byteena_b),
    .wren_b(wren_b),
    .q_b(q_b_ram),

    .aclr0(1'b0),
    .aclr1(1'b0),
    .addressstall_a(1'b0),
    .addressstall_b(1'b0),
    .clocken0(1'b1),
    .clocken1(1'b1),
    .clocken2(1'b1),
    .clocken3(1'b1),
    .eccstatus(),
    .rden_a(1'b1),
    .rden_b(1'b1)
);
defparam
    ram.numwords_a = NUM_WORDS,
    ram.widthad_a = ADDR_WIDTH,
    ram.width_a = 16,
    ram.numwords_b = NUM_WORDS,
    ram.widthad_b = ADDR_WIDTH,
    ram.width_b = 16,
    ram.address_reg_b = "CLOCK1",
    ram.clock_enable_input_a = "BYPASS",
    ram.clock_enable_input_b = "BYPASS",
    ram.clock_enable_output_a = "BYPASS",
    ram.clock_enable_output_b = "BYPASS",
    ram.indata_reg_b = PORT_B_READ_ONLY ? "UNUSED" : "CLOCK1",
    ram.intended_device_family = "Cyclone V",
    ram.lpm_type = "altsyncram",
    ram.operation_mode = "BIDIR_DUAL_PORT",
    ram.outdata_aclr_a = "NONE",
    ram.outdata_aclr_b = "NONE",
    ram.outdata_reg_a = "UNREGISTERED",
    ram.outdata_reg_b = "UNREGISTERED",
    ram.power_up_uninitialized = "FALSE",
    ram.read_during_write_mode_mixed_ports = MIXED_RDW_MODE,
    // Cyclone V true-dual-port M10Ks require NEW_DATA on each bidirectional
    // port.  Core clients ignore q on a write cycle; mixed-port collisions
    // retain OLD_DATA, which is the only observable collision case here.
    ram.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
    ram.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
    ram.width_byteena_a = 2,
    ram.width_byteena_b = 2,
    ram.byteena_reg_b = PORT_B_READ_ONLY ? "UNUSED" : "CLOCK1",
    ram.wrcontrol_wraddress_reg_b = PORT_B_READ_ONLY ? "UNUSED" : "CLOCK1";
`else
reg [15:0] mem [0:NUM_WORDS-1];
reg [15:0] q_a_r;
reg [15:0] q_b_r;
assign q_a = q_a_r;
assign q_b_ram = q_b_r;

integer __ram_init;
initial begin
    for (__ram_init = 0; __ram_init < NUM_WORDS; __ram_init = __ram_init + 1)
        mem[__ram_init] = 16'h0000;
end

// Stable simulation observation API used by full-core benches.  Keep tests
// independent of whether this module is implemented as an array or a vendor
// primitive in future revisions.
function automatic [15:0] sim_peek(input [ADDR_WIDTH-1:0] addr);
    sim_peek = mem[addr];
endfunction

always @(posedge clock_a) begin
    q_a_r <= mem[address_a];
    if (wren_a) begin
        if (byteena_a[0]) mem[address_a][7:0]  <= data_a[7:0];
        if (byteena_a[1]) mem[address_a][15:8] <= data_a[15:8];
    end
end

always @(posedge clock_b) begin
    if (SIM_COLLISION_POISON && wren_a && (address_a == address_b))
        // Stands in for the M10K's undefined mixed-port read.  Deliberately
        // neither mem[address_b] nor data_a so a bench cannot pass by reading
        // a legal word out of luck.
        q_b_r <= 16'hBAD0;
    else
        q_b_r <= mem[address_b];
    if (wren_b) begin
        if (byteena_b[0]) mem[address_b][7:0]  <= data_b[7:0];
        if (byteena_b[1]) mem[address_b][15:8] <= data_b[15:8];
    end
end
`endif

// Mixed-port collision resolution, shared by the vendor primitive and the
// behavioural model so simulation and hardware carry the same semantics.
// The comparison is a register input, not an addition to the q_b_ram ->
// consumer path, so only the output multiplexer lands on the renderer's
// 96 MHz fetch cone.
generate
if (MIXED_COLLISION_FWD) begin : g_mixed_fwd
    reg        coll_r;
    reg [15:0] coll_data_r;
    reg  [1:0] coll_be_r;
    always @(posedge clock_b) begin
        coll_r      <= wren_a && (address_a == address_b);
        coll_data_r <= data_a;
        coll_be_r   <= byteena_a;
    end
    assign q_b = coll_r
               ? {coll_be_r[1] ? coll_data_r[15:8] : q_b_ram[15:8],
                  coll_be_r[0] ? coll_data_r[7:0]  : q_b_ram[7:0]}
               : q_b_ram;
end
else begin : g_mixed_raw
    assign q_b = q_b_ram;
end
endgenerate

endmodule

//============================================================================
//  Byte-wide, common-clock true-dual-port block RAM.
//
//  System 32's Z80/V60 shared RAM and the V25 mailbox both use registered
//  reads.  Quartus 17 does not reliably infer an M10K for the equivalent
//  two-write unpacked-array RTL, so synthesis uses altsyncram explicitly.
//  The behavioural branch keeps the original one-cycle, old-data collision
//  semantics: both reads sample the pre-write word, and an inactive read
//  enable holds that port's q output.  Simultaneous writes to one address are
//  forbidden because the physical M10K result is undefined.
//============================================================================

module s32_byte_dpram #(
    parameter integer ADDR_WIDTH = 13,
    parameter integer NUM_WORDS  = (1 << ADDR_WIDTH),
    parameter         POWER_UP_UNINITIALIZED = "TRUE"
) (
    input                       clock,

    input      [ADDR_WIDTH-1:0] address_a,
    input                 [7:0] data_a,
    input                       rden_a,
    input                       wren_a,
    output                [7:0] q_a,

    input      [ADDR_WIDTH-1:0] address_b,
    input                 [7:0] data_b,
    input                       rden_b,
    input                       wren_b,
    output                [7:0] q_b
);

`ifdef ALTERA_RESERVED_QIS
altsyncram ram (
    .clock0(clock),
    .address_a(address_a),
    .data_a(data_a),
    .rden_a(rden_a),
    .wren_a(wren_a),
    .q_a(q_a),

    .clock1(clock),
    .address_b(address_b),
    .data_b(data_b),
    .rden_b(rden_b),
    .wren_b(wren_b),
    .q_b(q_b),

    .aclr0(1'b0),
    .aclr1(1'b0),
    .addressstall_a(1'b0),
    .addressstall_b(1'b0),
    .clocken0(1'b1),
    .clocken1(1'b1),
    .clocken2(1'b1),
    .clocken3(1'b1),
    .eccstatus()
);
defparam
    ram.numwords_a = NUM_WORDS,
    ram.widthad_a = ADDR_WIDTH,
    ram.width_a = 8,
    ram.numwords_b = NUM_WORDS,
    ram.widthad_b = ADDR_WIDTH,
    ram.width_b = 8,
    ram.address_reg_b = "CLOCK1",
    ram.clock_enable_input_a = "BYPASS",
    ram.clock_enable_input_b = "BYPASS",
    ram.clock_enable_output_a = "BYPASS",
    ram.clock_enable_output_b = "BYPASS",
    ram.indata_reg_b = "CLOCK1",
    ram.intended_device_family = "Cyclone V",
    ram.lpm_type = "altsyncram",
    ram.operation_mode = "BIDIR_DUAL_PORT",
    ram.outdata_aclr_a = "NONE",
    ram.outdata_aclr_b = "NONE",
    ram.outdata_reg_a = "UNREGISTERED",
    ram.outdata_reg_b = "UNREGISTERED",
    ram.power_up_uninitialized = POWER_UP_UNINITIALIZED,
    ram.read_during_write_mode_mixed_ports = "OLD_DATA",
    // Cyclone V true-dual-port M10Ks require new data on a port's own write
    // cycle.  Both clients discard q on their own writes; mixed-port reads,
    // which are observable, retain the original RTL's old-data behavior.
    ram.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
    ram.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
    ram.wrcontrol_wraddress_reg_b = "CLOCK1";
`else
reg [7:0] mem [0:NUM_WORDS-1];
reg [7:0] q_a_r;
reg [7:0] q_b_r;
assign q_a = q_a_r;
assign q_b = q_b_r;

function automatic [7:0] sim_peek(input [ADDR_WIDTH-1:0] addr);
    sim_peek = mem[addr];
endfunction

always @(posedge clock) begin
    if (rden_a) q_a_r <= mem[address_a];
    if (rden_b) q_b_r <= mem[address_b];
    if (wren_a) mem[address_a] <= data_a;
    if (wren_b) mem[address_b] <= data_b;
end
`endif

endmodule

// Single-port byte RAM for board devices whose second physical port is not
// part of the hardware contract. Keeping this separate from the true-dual-port
// primitive lets Quartus select SINGLE_PORT mode instead of warning that a
// BIDIR_DUAL_PORT RAM has an unused port (the V25 HLE mailbox is the current
// user).
module s32_byte_spram #(
    parameter integer ADDR_WIDTH = 13,
    parameter integer NUM_WORDS  = (1 << ADDR_WIDTH),
    parameter         POWER_UP_UNINITIALIZED = "TRUE"
) (
    input                       clock,
    input      [ADDR_WIDTH-1:0] address_a,
    input                 [7:0] data_a,
    input                       rden_a,
    input                       wren_a,
    output                [7:0] q_a
);

`ifdef ALTERA_RESERVED_QIS
altsyncram ram (
    .clock0(clock), .address_a(address_a), .data_a(data_a),
    .rden_a(rden_a), .wren_a(wren_a), .q_a(q_a),
    .aclr0(1'b0), .clocken0(1'b1), .clocken1(1'b1),
    .addressstall_a(1'b0), .eccstatus()
);
defparam
    ram.numwords_a = NUM_WORDS,
    ram.widthad_a = ADDR_WIDTH,
    ram.width_a = 8,
    ram.address_reg_a = "CLOCK0",
    ram.clock_enable_input_a = "BYPASS",
    ram.clock_enable_output_a = "BYPASS",
    ram.intended_device_family = "Cyclone V",
    ram.lpm_type = "altsyncram",
    ram.operation_mode = "SINGLE_PORT",
    ram.outdata_aclr_a = "NONE",
    ram.outdata_reg_a = "UNREGISTERED",
    ram.power_up_uninitialized = POWER_UP_UNINITIALIZED,
    ram.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ";
`else
reg [7:0] mem [0:NUM_WORDS-1];
reg [7:0] q_a_r;
assign q_a = q_a_r;
always @(posedge clock) begin
    if (rden_a) q_a_r <= mem[address_a];
    if (wren_a) mem[address_a] <= data_a;
end
`endif

endmodule
