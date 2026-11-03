// SPDX-License-Identifier: GPL-3.0-or-later
// Two production fx68k wrappers sharing one held bus arbiter and 64 KiB SRAM.
// Non-shared devices remain behind the explicit external backend interface.
module thunderjaws_cpu_pair #(parameter integer RECOVERY_ENABLE=0) (
    input  logic        clk_sys,
    input  logic        init_reset,
    input  logic        main_reset,
    input  logic        extra_reset,
    input  logic        pause_request,
    output wire         paused,
    input  logic  [2:0] main_ipl_n,
    input  logic  [2:0] extra_ipl_n,

    output wire [23:0]  main_address,
    output wire [15:0]  main_data_out,
    output wire         main_as,
    output wire         main_uds_n,
    output wire         main_lds_n,
    output wire         main_rw,
    output wire  [2:0]  main_fc,
    output wire [23:0]  extra_address,
    output wire [15:0]  extra_data_out,
    output wire         extra_as,
    output wire         extra_uds_n,
    output wire         extra_lds_n,
    output wire         extra_rw,
    output wire  [2:0]  extra_fc,

    output wire         backend_valid,
    input  logic        backend_ready,
    output wire         backend_owner,
    output wire [23:1]  backend_address,
    output wire         backend_read,
    output wire  [1:0]  backend_lanes,
    output wire [15:0]  backend_data,
    output wire [14:0]  backend_select,
    input  logic        backend_response_valid,
    input  logic [15:0] backend_response_data
);
    logic [2:0] phase_count;
    wire phase_phi1;
    wire phase_phi2;
    wire main_phase_phi1,main_phase_phi2,extra_phase_phi1,extra_phase_phi2;

    wire [15:0] main_data_in;
    wire [15:0] extra_data_in;
    wire main_dtack;
    wire extra_dtack;
    wire main_vpa_n;
    wire extra_vpa_n;

    wire [1:0] request_valid;
    wire [1:0] request_ready;
    wire [45:0] request_address;
    wire [1:0] request_read;
    wire [3:0] request_lanes;
    wire [31:0] request_data;
    wire [29:0] request_select;
    wire [1:0] response_valid;
    wire [15:0] response_data;

    // A logical CPU reset must outlive its accepted backend reply. Otherwise
    // the restarted kernel can raise AS while its bridge is still draining,
    // leaving that new AS stuck behind WAIT_IDLE (native warm-reset negative).
    // Track accepted ownership independently of AS and never cancel the arbiter.
    logic [1:0] accepted_pending;
    logic [1:0] reset_drain_hold;
    wire [1:0] requested_reset = {extra_reset,main_reset};
    wire [1:0] cpu_cycle_active = {extra_as,main_as};
    wire [1:0] effective_reset = requested_reset | reset_drain_hold;
    reg [1:0] pause_mask;
    wire [1:0] phase_active={extra_phase_phi1 || extra_phase_phi2,main_phase_phi1 || main_phase_phi2};
    wire [1:0] quiet=~(cpu_cycle_active | accepted_pending | request_valid | phase_active);
    assign paused=&pause_mask;
    integer pause_owner;
    always_ff @(posedge clk_sys)begin
        if(init_reset || !pause_request)pause_mask<=0;
        else if(RECOVERY_ENABLE!=0)begin
            for(pause_owner=0;pause_owner<2;pause_owner=pause_owner+1)
                if(quiet[pause_owner])pause_mask[pause_owner]<=1;
        end else if(&quiet)pause_mask<=2'b11;
    end
    genvar reset_owner;
    generate for(reset_owner=0;reset_owner<2;reset_owner=reset_owner+1)begin:g_reset_drain
        always_ff @(posedge clk_sys) begin
            if(init_reset)begin
                accepted_pending[reset_owner]<=1'b0;
                reset_drain_hold[reset_owner]<=1'b0;
            end else begin
                // Returning wins over accepting for a legal zero-latency reply.
                if(response_valid[reset_owner])accepted_pending[reset_owner]<=1'b0;
                else if(request_valid[reset_owner] && request_ready[reset_owner])
                    accepted_pending[reset_owner]<=1'b1;
                if(requested_reset[reset_owner])
                    reset_drain_hold[reset_owner]<=accepted_pending[reset_owner] ||
                        cpu_cycle_active[reset_owner];
                else if(!accepted_pending[reset_owner] && !cpu_cycle_active[reset_owner])
                    reset_drain_hold[reset_owner]<=1'b0;
            end
        end
    end endgenerate

    wire arb_backend_valid;
    wire arb_backend_ready;
    wire arb_backend_owner;
    wire [23:1] arb_backend_address;
    wire arb_backend_read;
    wire [1:0] arb_backend_lanes;
    wire [15:0] arb_backend_data;
    wire [14:0] arb_backend_select;
    wire arb_backend_response_valid;
    wire [15:0] arb_backend_response_data;

    wire shared_hit = arb_backend_select[1];
    wire shared_request_valid = !init_reset && arb_backend_valid && shared_hit;
    wire shared_request_ready;
    wire shared_response_valid;
    wire [15:0] shared_response_data;

    // Baseline profile only. Logical CPU reset never changes this phase origin.
    always_ff @(posedge clk_sys) begin
        if (init_reset)
            phase_count <= 3'd0;
        else if(!(&pause_mask))
            phase_count <= (phase_count == 3'd5) ? 3'd0 : phase_count + 3'd1;
    end

    assign phase_phi1 = !init_reset && (phase_count == 3'd0);
    assign phase_phi2 = !init_reset && (phase_count == 3'd3);

    generate if(RECOVERY_ENABLE!=0)begin:g_recovery
        // Block only an asserted transfer/IACK that lacks both DTACK and VPA.
        // AS/DS/FC are registered kernel outputs; replies are held by each bus
        // bridge. These are full-rate same-clock controls, not clock signals.
        wire main_block=main_as && (!main_uds_n || !main_lds_n || main_fc==3'b111) &&
            !main_dtack && main_vpa_n;
        wire extra_block=extra_as && (!extra_uds_n || !extra_lds_n || extra_fc==3'b111) &&
            !extra_dtack && extra_vpa_n;
        thunderjaws_cpu_clock main_clock(.clk_sys(clk_sys),.init_reset(init_reset),
            .cpu_reset(effective_reset[0]),.pause_safe(pause_mask[0]),.block_phi2(main_block),
            .phi1(main_phase_phi1),.phi2(main_phase_phi2));
        thunderjaws_cpu_clock extra_clock(.clk_sys(clk_sys),.init_reset(init_reset),
            .cpu_reset(effective_reset[1]),.pause_safe(pause_mask[1]),.block_phi2(extra_block),
            .phi1(extra_phase_phi1),.phi2(extra_phase_phi2));
    end else begin:g_baseline
        assign main_phase_phi1=phase_phi1 && !pause_mask[0];
        assign main_phase_phi2=phase_phi2 && !pause_mask[0];
        assign extra_phase_phi1=phase_phi1 && !pause_mask[1];
        assign extra_phase_phi2=phase_phi2 && !pause_mask[1];
    end endgenerate

    thunderjaws_cpu #(.EXTERNAL_PHASE(1)) main_cpu (
        .clk_sys(clk_sys), .reset(init_reset || effective_reset[0]),
        .phase_phi1(main_phase_phi1), .phase_phi2(main_phase_phi2), .ipl_n(main_ipl_n),
        .address(main_address), .data_out(main_data_out), .data_in(main_data_in),
        .as(main_as), .uds_n(main_uds_n), .lds_n(main_lds_n), .rw(main_rw),
        .fc(main_fc), .dtack_n(!main_dtack), .vpa_n(main_vpa_n)
    );

    thunderjaws_cpu #(.EXTERNAL_PHASE(1)) extra_cpu (
        .clk_sys(clk_sys), .reset(init_reset || effective_reset[1]),
        .phase_phi1(extra_phase_phi1), .phase_phi2(extra_phase_phi2), .ipl_n(extra_ipl_n),
        .address(extra_address), .data_out(extra_data_out), .data_in(extra_data_in),
        .as(extra_as), .uds_n(extra_uds_n), .lds_n(extra_lds_n), .rw(extra_rw),
        .fc(extra_fc), .dtack_n(!extra_dtack), .vpa_n(extra_vpa_n)
    );

    thunderjaws_cpu_bus #(.EXTRA_CPU(0)) main_bus (
        .clk_sys(clk_sys), .init_reset(init_reset), .game_reset(effective_reset[0]),
        .as_active(main_as), .rw(main_rw), .uds_n(main_uds_n), .lds_n(main_lds_n),
        .fc(main_fc), .address(main_address[23:1]), .write_data(main_data_out),
        .dtack(main_dtack), .vpa_n(main_vpa_n), .read_data(main_data_in),
        .request_valid(request_valid[0]), .request_ready(request_ready[0]),
        .request_address(request_address[22:0]), .request_read(request_read[0]),
        .request_lanes(request_lanes[1:0]), .request_data(request_data[15:0]),
        .request_select(request_select[14:0]), .response_valid(response_valid[0]),
        .response_data(response_data)
    );

    thunderjaws_cpu_bus #(.EXTRA_CPU(1)) extra_bus (
        .clk_sys(clk_sys), .init_reset(init_reset), .game_reset(effective_reset[1]),
        .as_active(extra_as), .rw(extra_rw), .uds_n(extra_uds_n), .lds_n(extra_lds_n),
        .fc(extra_fc), .address(extra_address[23:1]), .write_data(extra_data_out),
        .dtack(extra_dtack), .vpa_n(extra_vpa_n), .read_data(extra_data_in),
        .request_valid(request_valid[1]), .request_ready(request_ready[1]),
        .request_address(request_address[45:23]), .request_read(request_read[1]),
        .request_lanes(request_lanes[3:2]), .request_data(request_data[31:16]),
        .request_select(request_select[29:15]), .response_valid(response_valid[1]),
        .response_data(response_data)
    );

    thunderjaws_cpu_arbiter arbiter (
        .clk_sys(clk_sys), .init_reset(init_reset),
        .request_valid(request_valid), .request_ready(request_ready),
        .request_address(request_address), .request_read(request_read),
        .request_lanes(request_lanes), .request_data(request_data),
        .request_select(request_select), .response_valid(response_valid),
        .response_data(response_data), .backend_valid(arb_backend_valid),
        .backend_ready(arb_backend_ready), .backend_owner(arb_backend_owner),
        .backend_address(arb_backend_address), .backend_read(arb_backend_read),
        .backend_lanes(arb_backend_lanes), .backend_data(arb_backend_data),
        .backend_select(arb_backend_select),
        .backend_response_valid(arb_backend_response_valid),
        .backend_response_data(arb_backend_response_data),
        .cycle_active({extra_as, main_as})
    );

    thunderjaws_shared_ram shared_ram (
        .clk_sys(clk_sys), .init_reset(init_reset),
        .request_valid(shared_request_valid), .request_ready(shared_request_ready),
        .word_address(arb_backend_address[15:1]),
        .request_read(arb_backend_read), .request_lanes(arb_backend_lanes),
        .request_data(arb_backend_data), .response_valid(shared_response_valid),
        .response_data(shared_response_data)
    );

    // The selected descriptor remains owned by the arbiter until its reply.
    // Shared RAM is handled locally; every other select, including an unmapped
    // zero select, must receive a real response from the external device model.
    assign backend_valid = !init_reset && arb_backend_valid && !shared_hit;
    assign backend_owner = arb_backend_owner;
    assign backend_address = arb_backend_address;
    assign backend_read = arb_backend_read;
    assign backend_lanes = arb_backend_lanes;
    assign backend_data = arb_backend_data;
    assign backend_select = arb_backend_select;

    assign arb_backend_ready = shared_hit ? shared_request_ready :
                               (!init_reset && backend_ready);
    assign arb_backend_response_valid = !init_reset &&
        (shared_hit ? shared_response_valid : backend_response_valid);
    assign arb_backend_response_data = shared_hit ? shared_response_data :
                                      backend_response_data;
endmodule
