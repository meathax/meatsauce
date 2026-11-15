// Synthesizable CPU/board integration. External memory supplies RAM and ROM;
// graphics/sound engines and the MiSTer loader attach separately.
module bigfight_board (
    input wire cyclwarr_i,
    input wire pause_req,
    output wire pause_ack,
    input logic clk_sys,reset,cold_start,
    input logic [7:0] service_i,p1_i,p2_i,p3_i,p4_i,dsw1_i,dsw2_i,dsw3_i,
    output logic mem_valid,mem_req,mem_wr,mem_cpu,mem_uds_n,mem_lds_n,
    output logic [23:1] mem_address,
    output logic [15:0] mem_din,
    input logic mem_ready,
    input logic [15:0] mem_dout,
    output logic ce_pixel,hblank,vblank,line_start,frame_start,vblank_start,
    output logic [8:0] x,y,
    output logic [63:0] video_config,
    output logic [15:0] tile_bank,mixing_control,
    output logic [511:0] crtc_regs,
    output logic [7:0] sound_command,
    output logic sound_command_strobe,slave_halt,
    output logic [1:0] coin_outputs,
    output logic main_unmapped,sub_unmapped,
    output logic [23:1] main_addr,sub_addr,
    output logic main_as_n,sub_as_n,
    output logic [2:0] main_fc,sub_fc,
    output logic main_iack,sub_iack,
    output logic trace_req,trace_cpu,trace_wr,trace_uds_n,trace_lds_n,
    output logic [23:1] trace_address,
    output logic [15:0] trace_din,trace_dout
`ifdef BIGFIGHT_CPU_RECOVERY
    ,input logic [1:0] program_owner
`endif
);
    logic [15:0] main_data_i,sub_data_i,main_data_o,sub_data_o;
    logic main_rw,sub_rw,main_uds_n,main_lds_n,sub_uds_n,sub_lds_n;
    logic main_dtack_n,sub_dtack_n;
    logic [2:0] main_ipl_n,sub_ipl_n;
    logic owner_main,bus_valid,bus_req,bus_wr,bus_uds_n,bus_lds_n;
    logic [23:1] bus_address;
    logic [15:0] bus_din,bus_dout,io_dout;
    logic io_selected,regs_selected,bus_ready;

    function automatic logic mapped(input logic cpu,input logic [23:1] address);
        logic [23:0] a;
        begin
            a={address,1'b0};
            mapped = a<=24'h00fffe ||
                (!cpu && ((a>=24'h03e000 && a<=24'h03effe) ||
                          (a>=24'h040000 && a<=24'h04fffe))) ||
                (a>=24'h080000 && a<=24'h09fffe) ||
                (a>=24'h0a2000 && a<=24'h0a2006) ||
                a==24'h0a4000 || a==24'h0a6000 ||
                a==24'h0ac000 || a==24'h0ac002 || a==24'h0b8000 ||
                address[23:4]==20'h0b900 || address[23:4]==20'h0ba00 ||
                a==24'h0bc000 || (a>=24'h0c0000 && a<=24'h0c3ffe) ||
                (a>=24'h0ca000 && a<=24'h0ca1fe) ||
                (a>=24'h0d0000 && a<=24'h0d3ffe) ||
                (a>=24'h100000 && a<=24'h3ffffe);
        end
    endfunction
    assign main_unmapped=!main_as_n && main_fc!=3'b111 && !mapped(1'b0,main_addr);
    assign sub_unmapped=!sub_as_n && sub_fc!=3'b111 && !mapped(1'b1,sub_addr);
    assign main_iack=!main_as_n && main_fc==3'b111 && main_addr[3:1]==3'd5;
    assign sub_iack=!sub_as_n && sub_fc==3'b111 && sub_addr[3:1]==3'd5;
    bigfight_cpu_pair cpus(
        .pause_req(pause_req), .pause_ack(pause_ack),
        .clk_sys(clk_sys),.reset(reset),.phase_reset(cold_start),
`ifdef BIGFIGHT_CPU_RECOVERY
        .program_owner_i(program_owner),
`endif
        .main_data_i(main_data_i),.main_dtack_n(main_dtack_n),.main_vpa_n(!main_iack),
        .main_berr_n(1'b1),.main_br_n(1'b1),.main_bgack_n(1'b1),
        .main_ipl_n(main_ipl_n),.main_halt_n(1'b1),.main_data_o(main_data_o),
        .main_addr(main_addr),.main_as_n(main_as_n),.main_rw(main_rw),
        .main_uds_n(main_uds_n),.main_lds_n(main_lds_n),.main_fc(main_fc),
        .main_vma_n(),.main_bg_n(),.main_reset_n(),.main_halted_n(),
        .sub_data_i(sub_data_i),.sub_dtack_n(sub_dtack_n),.sub_vpa_n(!sub_iack),
        .sub_berr_n(1'b1),.sub_br_n(1'b1),.sub_bgack_n(1'b1),
        .sub_ipl_n(sub_ipl_n),.sub_halt_n(!slave_halt),.sub_data_o(sub_data_o),
        .sub_addr(sub_addr),.sub_as_n(sub_as_n),.sub_rw(sub_rw),
        .sub_uds_n(sub_uds_n),.sub_lds_n(sub_lds_n),.sub_fc(sub_fc),
        .sub_vma_n(),.sub_bg_n(),.sub_reset_n(),.sub_halted_n()
    );
    bigfight_device_bus bus(
        .clk(clk_sys),.reset(reset),
        .main_select(main_fc!=3'b111),
        .main_as_n(main_as_n),.main_rw(main_rw),.main_uds_n(main_uds_n),.main_lds_n(main_lds_n),
        .main_addr(main_addr),.main_din(main_data_o),
        .sub_select(sub_fc!=3'b111),
        .sub_as_n(sub_as_n),.sub_rw(sub_rw),.sub_uds_n(sub_uds_n),.sub_lds_n(sub_lds_n),
        .sub_addr(sub_addr),.sub_din(sub_data_o),
        .main_dtack_n(main_dtack_n),.sub_dtack_n(sub_dtack_n),
        .main_dout(main_data_i),.sub_dout(sub_data_i),.req(bus_req),.valid(bus_valid),
        .wr(bus_wr),.uds_n(bus_uds_n),.lds_n(bus_lds_n),.owner_main(owner_main),
        .address(bus_address),.din(bus_din),.dout(bus_dout),.ready(bus_ready)
    );
    bigfight_io io(
        .clk(clk_sys),.reset(reset),.cold_start(cold_start),
        .req(bus_req),.wr(bus_wr),.address(bus_address),.uds_n(bus_uds_n),.lds_n(bus_lds_n),.din(bus_din),
        .service_i(service_i),.p1_i(p1_i),.p2_i(p2_i),.p3_i(p3_i),.p4_i(p4_i),
        .dsw1_i(dsw1_i),.dsw2_i(dsw2_i),.dsw3_i(dsw3_i),
        .selected(io_selected),.dout(io_dout),.slave_halt_o(slave_halt)
    );
    bigfight_registers regs(
        .clk(clk_sys),.cold_start(cold_start),.reset(reset),.req(bus_req),.wr(bus_wr),
        .address(bus_address),.uds_n(bus_uds_n),.lds_n(bus_lds_n),.din(bus_din),
        .selected(regs_selected),.video_config(video_config),.tile_bank(tile_bank),
        .mixing_control(mixing_control),.crtc_regs(crtc_regs),.sound_command(sound_command),
        .sound_command_strobe(sound_command_strobe),.coin_outputs(coin_outputs)
    );
    bigfight_raster raster(.clk(clk_sys),.cold_start(cold_start),.*);
    bigfight_irq irq(.clk(clk_sys),.reset(reset),.vblank_start(vblank_start),
        .main_ack(main_iack),.sub_ack(sub_iack),.main_ipl_n(main_ipl_n),.sub_ipl_n(sub_ipl_n));
    // The video CPU legitimately reads outside the mapped RAM during scene
    // changes (107aac/107ab0, e.g. ffceb0..ffceb6). Match MAME's zero-valued
    // unmapped space: complete these cycles and discard writes. Withholding
    // DTACK here strands that CPU while gameplay on the other CPU continues.
    wire bus_unmapped = !mapped(!owner_main,bus_address);
    assign bus_ready=bus_unmapped || io_selected || regs_selected || mem_ready;
    assign bus_dout=bus_unmapped ? 16'h0000 : io_selected ? io_dout : regs_selected ? 16'h0000 : mem_dout;
    assign mem_valid=bus_valid && !bus_unmapped && !io_selected && !regs_selected;
    assign mem_req=bus_req && !bus_unmapped && !io_selected && !regs_selected;
    assign mem_wr=bus_wr;
    assign mem_cpu=!owner_main;
    assign mem_address=bus_address;
    assign mem_din=bus_din;
    assign mem_uds_n=bus_uds_n;
    assign mem_lds_n=bus_lds_n;
    assign trace_req=bus_req;
    assign trace_cpu=!owner_main;
    assign trace_address=bus_address;
    assign trace_din=bus_din;
    assign trace_dout=bus_dout;
    assign trace_wr=bus_wr;
    assign trace_uds_n=bus_uds_n;
    assign trace_lds_n=bus_lds_n;
endmodule
