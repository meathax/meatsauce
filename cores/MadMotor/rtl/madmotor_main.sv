// SPDX-License-Identifier: GPL-3.0-or-later
// Mad Motor 68000 bus adapter. Memory/video devices own their storage and latency.
// Phi enables must alternate. No derived clock or multicycle assumption is used.
module madmotor_main #(parameter SERVICE_ENABLE=0) (
    input tri0 bandit,
    input logic clk, reset, en_phi1, en_phi2, vblank_irq, mcu_irq5,
    input logic [15:0] controls, dips, system_port,
    output wire [23:0] address,
    output wire [15:0] write_data,
    output wire [1:0] byte_enable,
    output wire read_cycle, request,
    input logic [15:0] read_data,
    input logic ready,
    output wire rom_cs, work_cs, sprite_cs, palette_cs,
    output wire [2:0] tile_cs, control_cs, scroll_cs,
    output wire aux_cs, write_strobe,
    output logic [7:0] sound_latch,
    output logic sound_irq,
    output wire irq_ack, halted,bus_wait,
    output wire [2:0] function_code,
    input wire service_br_n,service_bgack_n,
    output wire service_bg_n,service_as_n,service_dtack_n
);
    wire [23:1] cpu_address;
    wire as_n, uds_n, lds_n, rw_n, reset_n, halt_n;
    wire fc0, fc1, fc2;
    logic irq_pending, irq5_pending, bus_seen;
    wire iack = !as_n && (&function_code);
    wire active = !as_n && !iack && (!uds_n || !lds_n);
    logic [15:0] cpu_data;
    wire io_cs = bandit ? (address >= 24'h30c000 && address <= 24'h30c00a) :
                         (address >= 24'h3f8002 && address <= 24'h3f8006);
    wire latch_cs = address == (bandit ? 24'h30c014 : 24'h3fc004) && !lds_n;
    wire complete = active && (ready || io_cs || latch_cs);
    assign bus_wait=active&&!complete;
    assign address = {cpu_address,1'b0};
    assign byte_enable = {~uds_n,~lds_n};
    assign read_cycle = rw_n;
    assign request = active;
    assign function_code = {fc2,fc1,fc0};
    assign irq_ack = iack;
    assign halted = !halt_n;
    assign service_as_n=as_n;
    assign service_dtack_n=!complete;
    assign write_strobe = complete && !rw_n && !bus_seen;
    assign rom_cs = active && address < (bandit ? 24'h060000 : 24'h080000);
    assign work_cs = active && (bandit ? (address[23:14]==10'h0c6 || address[23:14]==10'h3fe) :
                                                       address[23:14]==10'h0f8);
    assign sprite_cs = active && (bandit ? (address[23:11]==13'h638 || address[23:11]==13'h1ff8) :
                                                          address[23:11]==13'h7d0);
    assign palette_cs = active && (bandit ? (address[23:11]==13'h620 || address[23:11]==13'h628) :
                                                           address[23:11]==13'h7e0);
    assign tile_cs[0] = active && (bandit ? address[23:13]==11'h122 : address[23:13]==11'h0c4);
    assign tile_cs[1] = active && (bandit ? address[23:11]==13'h494 : address[23:11]==13'h330);
    assign tile_cs[2] = active && (bandit ? address[23:11]==13'h49a : address[23:12]==12'h1a4);
    assign control_cs[0] = active && address[23:3]==(bandit ? 21'h048000 : 21'h030000);
    assign control_cs[1] = active && address[23:3]==(bandit ? 21'h048c00 : 21'h032000);
    assign control_cs[2] = active && address[23:3]==(bandit ? 21'h049800 : 21'h034000);
    assign scroll_cs[0] = active && address[23:3]==(bandit ? 21'h048002 : 21'h030002);
    assign scroll_cs[1] = active && address[23:3]==(bandit ? 21'h048c02 : 21'h032002);
    assign scroll_cs[2] = active && address[23:3]==(bandit ? 21'h049802 : 21'h034002);
    assign aux_cs = active && (bandit ? (address[23:11]==13'h484 || address[23:11]==13'h490 || address[23:11]==13'h499) :
                                                        address[23:11]==13'h308);
    always_comb begin
        cpu_data = read_data;
        if (io_cs && bandit) case(address[3:1])
            0: cpu_data=controls;
            1: cpu_data=system_port;
            2: cpu_data=dips;
            4: cpu_data=16'd0;
            default: cpu_data=16'hffff;
        endcase
        else if (io_cs) case (address[2:1])
            2'd1: cpu_data = controls;
            2'd2: cpu_data = dips;
            2'd3: cpu_data = system_port;
            default: cpu_data = 16'hffff;
        endcase
    end
    always_ff @(posedge clk) begin
        if (reset) begin
            irq_pending <= 0;
            irq5_pending <= 0;
            bus_seen <= 0;
            sound_latch <= 0;
            sound_irq <= 0;
        end else begin
            sound_irq <= 0;
            if ((!bandit && iack) || (bandit && write_strobe && address==24'h30c018)) irq_pending <= 0;
            if (vblank_irq) irq_pending <= 1;
            if (bandit && iack && !irq_pending) irq5_pending <= 0;
            if (bandit && mcu_irq5) irq5_pending <= 1;
            // TAS keeps AS asserted across separate read and write strobes.
            // Re-arm per data transfer so its write phase is not suppressed.
            if (!active) bus_seen <= 0;
            else if (complete) bus_seen <= 1;
            if (write_strobe && latch_cs) begin
                sound_latch <= write_data[7:0];
                sound_irq <= 1;
            end
        end
    end
    fx68k cpu (
        .clk(clk), .HALTn(1'b1), .extReset(reset), .pwrUp(reset),
        .enPhi1(en_phi1), .enPhi2(en_phi2), .eRWn(rw_n), .ASn(as_n),
        .LDSn(lds_n), .UDSn(uds_n), .E(), .VMAn(),
        .FC0(fc0), .FC1(fc1), .FC2(fc2), .BGn(service_bg_n),
        .oRESETn(reset_n), .oHALTEDn(halt_n),
        .DTACKn(!complete), .VPAn(!iack), .BERRn(1'b1),
        .BRn(SERVICE_ENABLE ? service_br_n : 1'b1),
        .BGACKn(SERVICE_ENABLE ? service_bgack_n : 1'b1),
        .IPL0n(!(bandit && !irq_pending && irq5_pending)),
        .IPL1n(!irq_pending),
        .IPL2n(!(irq_pending || (bandit && irq5_pending))),
        .iEdb(cpu_data), .oEdb(write_data), .eab(cpu_address)
    );
endmodule
