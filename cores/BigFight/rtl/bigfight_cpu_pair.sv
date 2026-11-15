// Two native FX68K buses for Big Fight / Cycle Warriors CPU integration.
// Both cores remain on clk_sys; enPhi1/enPhi2 are single-cycle clock enables.
module bigfight_cpu_pair (
    input wire pause_req,
    output wire pause_ack,
    input  logic        clk_sys,
    input  logic        reset,
    input  logic        phase_reset,

    input  logic [15:0] main_data_i,
    input  logic        main_dtack_n,
    input  logic        main_vpa_n,
    input  logic        main_berr_n,
    input  logic        main_br_n,
    input  logic        main_bgack_n,
    input  logic [2:0]  main_ipl_n,
    input  logic        main_halt_n,
    output wire  [15:0] main_data_o,
    output wire  [23:1] main_addr,
    output wire         main_as_n,
    output wire         main_rw,
    output wire         main_uds_n,
    output wire         main_lds_n,
    output wire  [2:0]  main_fc,
    output wire         main_vma_n,
    output wire         main_bg_n,
    output wire         main_reset_n,
    output wire         main_halted_n,

    input  logic [15:0] sub_data_i,
    input  logic        sub_dtack_n,
    input  logic        sub_vpa_n,
    input  logic        sub_berr_n,
    input  logic        sub_br_n,
    input  logic        sub_bgack_n,
    input  logic [2:0]  sub_ipl_n,
    input  logic        sub_halt_n,
    output wire  [15:0] sub_data_o,
    output wire  [23:1] sub_addr,
    output wire         sub_as_n,
    output wire         sub_rw,
    output wire         sub_uds_n,
    output wire         sub_lds_n,
    output wire  [2:0]  sub_fc,
    output wire         sub_vma_n,
    output wire         sub_bg_n,
    output wire         sub_reset_n,
    output wire         sub_halted_n
`ifdef BIGFIGHT_CPU_RECOVERY
    ,input logic [1:0]  program_owner_i
`endif
);

    logic main_paused_q = 1'b0, sub_paused_q = 1'b0;
    assign pause_ack = main_paused_q && sub_paused_q;
    // Suppress the admission edge itself: an idle CPU cannot start another bus
    // transaction on the same edge on which the pause is acknowledged.
    wire freeze_main = !reset && !phase_reset &&
                       (main_paused_q || (pause_req && main_as_n));
    wire freeze_sub = !reset && !phase_reset &&
                      (sub_paused_q || (pause_req && sub_as_n));
    always_ff @(posedge clk_sys) begin
        if (reset || phase_reset || !pause_req) begin
            main_paused_q <= 1'b0;
            sub_paused_q <= 1'b0;
        end else begin
            if (main_as_n) main_paused_q <= 1'b1;
            if (sub_as_n) sub_paused_q <= 1'b1;
        end
    end

`ifdef BIGFIGHT_CPU_RECOVERY
    wire main_read_probe /* verilator public_flat_rd */ = main_rw;
    wire sub_read_probe /* verilator public_flat_rd */ = sub_rw;
    logic main_phi1 /* verilator public_flat_rd */;
    logic main_phi2 /* verilator public_flat_rd */;
    logic sub_phi1 /* verilator public_flat_rd */;
    logic sub_phi2 /* verilator public_flat_rd */;
    logic main_wait_active_raw /* verilator public_flat_rd */;
    logic main_wait_repeat_raw /* verilator public_flat_rd */;
    logic sub_wait_active_raw /* verilator public_flat_rd */;
    logic sub_wait_repeat_raw /* verilator public_flat_rd */;
    logic [1:0] program_owner_q /* verilator public_flat_rd */;
    wire [1:0] memory_owner /* verilator public_flat_rd */;
    wire [1:0] ram_owner /* verilator public_flat_rd */;
    // A native request belongs to its CPU before it wins the shared backend.
    // ROM's granted-owner descriptor remains diagnostic, not the credit gate.
    bigfight_recovery_owner #(.IS_SUB(0)) main_owner (
        .clk(clk_sys),.reset(reset || phase_reset),.as_n(main_as_n),
        .rw(main_rw),.uds_n(main_uds_n),.lds_n(main_lds_n),
        .address(main_addr),.wdata(main_data_o),.fc(main_fc),.vpa_n(main_vpa_n),
        .owner(memory_owner[0]),.ram_owner(ram_owner[0])
    );
    bigfight_recovery_owner #(.IS_SUB(1)) sub_owner (
        .clk(clk_sys),.reset(reset || phase_reset),.as_n(sub_as_n),
        .rw(sub_rw),.uds_n(sub_uds_n),.lds_n(sub_lds_n),
        .address(sub_addr),.wdata(sub_data_o),.fc(sub_fc),.vpa_n(sub_vpa_n),
        .owner(memory_owner[1]),.ram_owner(ram_owner[1])
    );
    wire main_recovery_owner = memory_owner[0] && main_vpa_n && (main_fc != 3'b111);
    wire sub_recovery_owner = memory_owner[1] && sub_vpa_n && (sub_fc != 3'b111);
    // Raw wait-active suspends debt repayment for *all* donor bus waits,
    // including VPA service. Only an owned memory S4 repeat can earn credit.
    wire main_wait_active /* verilator public_flat_rd */ = main_wait_active_raw;
    wire main_wait_repeat /* verilator public_flat_rd */ = main_wait_repeat_raw && main_recovery_owner;
    wire sub_wait_active /* verilator public_flat_rd */ = sub_wait_active_raw;
    wire sub_wait_repeat /* verilator public_flat_rd */ = sub_wait_repeat_raw && sub_recovery_owner;

    // The ROM bridge's owner descriptor is sampled while the matching native
    // read is on the CPU bus. Retain it through bridge acceptance until FX68K
    // releases AS or both data strobes; its final S4 repeat can follow mem_ready.
    always_ff @(posedge clk_sys) begin
        if (phase_reset || reset) begin
            program_owner_q <= 2'b00;
        end else begin
            if (main_as_n || (main_uds_n && main_lds_n))
                program_owner_q[0] <= 1'b0;
            else if (program_owner_i[0] && main_rw)
                program_owner_q[0] <= 1'b1;

            if (sub_as_n || (sub_uds_n && sub_lds_n))
                program_owner_q[1] <= 1'b0;
            else if (program_owner_i[1] && sub_rw)
                program_owner_q[1] <= 1'b1;
        end
    end

    bigfight_cpu_recovery u_main_recovery (
        .clk_sys(clk_sys), .phase_reset(phase_reset), .cpu_reset(reset),
        .pause(freeze_main), .wait_active_i(main_wait_active_raw),
        .wait_repeat_i(main_wait_repeat), .phi1_o(main_phi1), .phi2_o(main_phi2),
        .credit_o(), .earned_o(), .saved_o(), .forgiven_o(),
        .overflow_o(), .protocol_fault_o()
    );
    bigfight_cpu_recovery u_sub_recovery (
        .clk_sys(clk_sys), .phase_reset(phase_reset), .cpu_reset(reset),
        .pause(freeze_sub), .wait_active_i(sub_wait_active_raw),
        .wait_repeat_i(sub_wait_repeat), .phi1_o(sub_phi1), .phi2_o(sub_phi2),
        .credit_o(), .earned_o(), .saved_o(), .forgiven_o(),
        .overflow_o(), .protocol_fault_o()
    );
`else
    logic [1:0] phase_q, sub_phase_q;
    wire enPhi1 = !phase_reset && !freeze_main && (phase_q == 2'b11);
    wire enPhi2 = !phase_reset && !freeze_main && (phase_q == 2'b01);
    wire sub_enPhi1 = !phase_reset && !freeze_sub && (sub_phase_q == 2'b11);
    wire sub_enPhi2 = !phase_reset && !freeze_sub && (sub_phase_q == 2'b01);

    // The FX68K donor documents these as single-cycle enables. They are two
    // system clocks apart and repeat every four clocks (50 MHz / 4 = 12.5 MHz).
    // phase_reset initializes this divider only; CPU reset must leave these
    // enables running so the donor can sample its phase-qualified reset state.
    always_ff @(posedge clk_sys) begin
        if (phase_reset) begin
            phase_q <= 2'b00;
            sub_phase_q <= 2'b00;
        end else begin
            if (!freeze_main) phase_q <= phase_q + 2'b01;
            if (!freeze_sub) sub_phase_q <= sub_phase_q + 2'b01;
        end
    end
`endif

`ifdef BIGFIGHT_CPU_RECOVERY
    wire enPhi1 = main_phi1;
    wire enPhi2 = main_phi2;
    wire sub_enPhi1 = sub_phi1;
    wire sub_enPhi2 = sub_phi2;
`endif

    fx68k u_main (
        .clk(clk_sys),
        .HALTn(main_halt_n),
        .extReset(reset),
        .pwrUp(reset),
`ifdef BIGFIGHT_CPU_RECOVERY
        .enPhi1(enPhi1),
        .enPhi2(enPhi2),
`else
        .enPhi1(enPhi1),
        .enPhi2(enPhi2),
`endif
        .eRWn(main_rw),
        .ASn(main_as_n),
        .LDSn(main_lds_n),
        .UDSn(main_uds_n),
        .E(),
        .VMAn(main_vma_n),
        .FC0(main_fc[0]),
        .FC1(main_fc[1]),
        .FC2(main_fc[2]),
        .BGn(main_bg_n),
        .oRESETn(main_reset_n),
        .oHALTEDn(main_halted_n),
        .DTACKn(main_dtack_n),
        .VPAn(main_vpa_n),
        .BERRn(main_berr_n),
        .BRn(main_br_n),
        .BGACKn(main_bgack_n),
        .IPL0n(main_ipl_n[0]),
        .IPL1n(main_ipl_n[1]),
        .IPL2n(main_ipl_n[2]),
        .iEdb(main_data_i),
        .oEdb(main_data_o),
        .eab(main_addr),
        .dbgPc()
`ifdef BIGFIGHT_CPU_RECOVERY
        ,.wait_active_o(main_wait_active_raw)
        ,.wait_repeat_o(main_wait_repeat_raw)
`endif
    );

    fx68k u_sub (
        .clk(clk_sys),
        .HALTn(sub_halt_n),
        .extReset(reset),
        .pwrUp(reset),
`ifdef BIGFIGHT_CPU_RECOVERY
        .enPhi1(sub_enPhi1),
        .enPhi2(sub_enPhi2),
`else
        .enPhi1(sub_enPhi1),
        .enPhi2(sub_enPhi2),
`endif
        .eRWn(sub_rw),
        .ASn(sub_as_n),
        .LDSn(sub_lds_n),
        .UDSn(sub_uds_n),
        .E(),
        .VMAn(sub_vma_n),
        .FC0(sub_fc[0]),
        .FC1(sub_fc[1]),
        .FC2(sub_fc[2]),
        .BGn(sub_bg_n),
        .oRESETn(sub_reset_n),
        .oHALTEDn(sub_halted_n),
        .DTACKn(sub_dtack_n),
        .VPAn(sub_vpa_n),
        .BERRn(sub_berr_n),
        .BRn(sub_br_n),
        .BGACKn(sub_bgack_n),
        .IPL0n(sub_ipl_n[0]),
        .IPL1n(sub_ipl_n[1]),
        .IPL2n(sub_ipl_n[2]),
        .iEdb(sub_data_i),
        .oEdb(sub_data_o),
        .eab(sub_addr),
        .dbgPc()
`ifdef BIGFIGHT_CPU_RECOVERY
        ,.wait_active_o(sub_wait_active_raw)
        ,.wait_repeat_o(sub_wait_repeat_raw)
`endif
    );

endmodule


// Per-native-CPU descriptor. Backend arbitration is an implementation stall;
// peripheral/IACK waits and ROM writes never acquire recovery ownership.
module bigfight_recovery_owner #(parameter bit IS_SUB=0)(
    input wire clk,reset,as_n,rw,uds_n,lds_n,vpa_n,
    input wire [23:1] address,
    input wire [15:0] wdata,
    input wire [2:0] fc,
    output wire owner,ram_owner
);
    wire [23:0] a={address,1'b0};
    // Exact memory windows from bigfight_work_ram and bigfight_program_rom.
    wire ram_decode = a <= 24'h00fffe ||
        (!IS_SUB && ((a >= 24'h03e000 && a <= 24'h03effe) ||
                     (a >= 24'h040000 && a <= 24'h04fffe))) ||
        (a >= 24'h080000 && a <= 24'h09fffe) ||
        (a >= 24'h0c0000 && a <= 24'h0c3ffe) ||
        (a >= 24'h0ca000 && a <= 24'h0ca1fe) ||
        (a >= 24'h0d0000 && a <= 24'h0d3ffe);
    wire rom_decode = a >= 24'h100000 && a <= 24'h3ffffe;
    reg held=0,cancelled=0,ram_q=0,rom_q=0,rw_q=1,uds_q=1,lds_q=1;
    reg [23:1] address_q=0;
    reg [15:0] data_q=0;
    reg [2:0] fc_q=0;
    wire tuple_match = address==address_q && rw==rw_q &&
        uds_n==uds_q && lds_n==lds_q && fc==fc_q && (rw_q || wdata==data_q);
    assign owner = !reset && !as_n && (!uds_n || !lds_n) && vpa_n &&
        fc != 3'b111 && held && !cancelled && tuple_match &&
        (ram_q || (rom_q && rw_q));
    assign ram_owner = owner && ram_q;
    always @(posedge clk) begin
        if(reset || as_n || (uds_n && lds_n)) begin
            held<=0;cancelled<=0;ram_q<=0;rom_q<=0;
        end else if(!held) begin
            held<=1;cancelled<=0;ram_q<=ram_decode;rom_q<=rom_decode;
            address_q<=address;data_q<=wdata;rw_q<=rw;
            uds_q<=uds_n;lds_q<=lds_n;fc_q<=fc;
        end else if(!tuple_match) cancelled<=1;
    end
endmodule
