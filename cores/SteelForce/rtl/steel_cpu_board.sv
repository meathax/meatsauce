// CPU/chip bring-up boundary. External memory is a latency model in the CPU bench.
// The production board RAM/SDRAM/video integration will use this same byte-lane protocol.
module steel_cpu_board(
    input logic clk, reset, pause_cpu, mortalr, cpu_turbo,
    input logic [15:0] input_word, system_word,
    output wire mem_valid, mem_write,
    output wire [23:0] mem_addr,
    output wire [15:0] mem_wdata,
    output wire [1:0] mem_lanes,
    input logic mem_ready, mem_write_grant,
    input logic [15:0] mem_rdata,
    input logic [5:0] nv_addr,
    input logic nv_we,
    input logic [15:0] nv_din,
    output wire [15:0] nv_dout,
    output wire [17:0] oki_addr,
    input logic [7:0] oki_data,
    input logic oki_ok,
    output wire signed [13:0] audio,
    output wire audio_sample,
    output wire debug_io_accept,
    output wire [15:0] debug_io_rdata,
    output logic video_command_valid,
    output logic [15:0] video_command,
    input logic video_command_done,
    output wire [31:0] frame_number,
    output wire frame_tick, vblank,
    output wire [23:0] debug_cpu_addr,
    output wire [15:0] debug_cpu_wdata,
    output wire [2:0] debug_fc,
    output wire debug_asn, debug_rwn, debug_haltedn,
    output wire irq_pending, irq_ack
);
    wire phi1,phi2,oki_cen;
    steel_timing timing(.clk(clk),.reset(reset),.pause_cpu(pause_cpu),.mortalr(mortalr),.turbo(cpu_turbo),
        .phi1(phi1),.phi2(phi2),.oki_cen(oki_cen),.frame_tick(frame_tick),
        .vblank(vblank),.frame_number(frame_number));
    wire [23:1] cpu_a;
    wire [15:0] cpu_wdata;
    logic [15:0] cpu_rdata;
    wire asn,rwn,udsn,ldsn,fc0,fc1,fc2;
    wire dtackn;
    wire iack=(!asn)&&({fc2,fc1,fc0}==3'b111);
    logic irq;
    assign irq_pending=irq;
    assign irq_ack=iack;
    wire [23:0] address={cpu_a,1'b0};
    wire io_input=address==24'h400000;
    wire io_system=address==24'h400002;
    wire io_eeprom=address==24'h400010;
    wire io_command=address==24'h40001e;
    wire io_oki=address==24'h410000;
    wire local_io=io_input||io_system||io_eeprom||io_command||io_oki;
    logic io_done,io_issued,command_pending;
    wire io_accept=!asn && local_io && !io_issued && (!udsn||!ldsn);
    // Read-only probes of the actual accepted local-device transaction.
    assign debug_io_accept=io_accept;
    assign debug_io_rdata=cpu_rdata;
    assign mem_valid=!asn && !iack && !local_io && (!udsn||!ldsn);
    assign mem_write=!rwn;
    assign mem_addr=address;
    assign mem_wdata=cpu_wdata;
    assign mem_lanes={!udsn,!ldsn};
    // Write strobes arrive later than AS on the 68000. Waiting for a registered
    // strobe-qualified commit misses S4 for some master-clock phases.
    // On-chip RAM grants early DTACK; data still commits under real UDS/LDS.
    assign dtackn=!(local_io ? io_done :
                   (!iack && (mem_ready || (!asn && !rwn && mem_write_grant))));
    wire ee_do;
    logic [2:0] ee_lines;
    wire [7:0] oki_status;
    wire oki_wrn=!(io_accept && io_oki && !rwn && !ldsn);
    always_comb begin
        cpu_rdata=mem_rdata;
        if(io_input) cpu_rdata=input_word;
        else if(io_system) begin
            cpu_rdata=system_word;
            cpu_rdata[4]=!vblank;
            cpu_rdata[6]=ee_do;
        end else if(io_oki) cpu_rdata={8'hff,oki_status};
        else if(local_io) cpu_rdata=16'hffff;
    end
    always_ff @(posedge clk) begin
        if(reset) begin
            irq<=0;io_done<=0;io_issued<=0;command_pending<=0;ee_lines<=0;
            video_command_valid<=0;video_command<=0;
        end else begin
            video_command_valid<=0;
            if(command_pending && video_command_done) begin io_done<=1;command_pending<=0;end
            if(frame_tick) irq<=1;
            if(iack) irq<=0;
            if(asn) begin io_done<=0;io_issued<=0;command_pending<=0;end
            else if(io_accept) begin
                io_issued<=1;
                io_done<=!(io_command && !rwn);
                if(!rwn) begin
                    if(io_eeprom && !ldsn) ee_lines<=cpu_wdata[2:0];
                    if(io_command) begin
                        video_command<={udsn ? 8'b0 : cpu_wdata[15:8],ldsn ? 8'b0 : cpu_wdata[7:0]};
                        video_command_valid<=1;
                        command_pending<=1;
                    end
                end
            end
        end
    end
    // Synchronous host/NVRAM boundary. Writes commit one clock later;
    // address-to-dump-read is two clocks. It stays active during CPU reset.
    logic nv_we_q=0;
    logic [5:0] nv_addr_q;
    logic [15:0] nv_din_q;
    always_ff @(posedge clk) begin
        nv_we_q<=nv_we;nv_addr_q<=nv_addr;nv_din_q<=nv_din;
    end
    jt9346 #(.AW(6),.CW(6),.DW(16) , .WRITE_CYCLES(79800), .ERASE_CYCLES(45600), .ALL_CYCLES(364800)) eeprom(
        .rst(reset),.clk(clk),.sclk(ee_lines[2]),.sdi(ee_lines[0]),
        .sdo(ee_do),.scs(ee_lines[1]),.dump_clk(clk),.dump_addr(nv_addr_q),
        .dump_we(nv_we_q),.dump_din(nv_din_q),.dump_dout(nv_dout),.dump_clr(1'b0),.dump_flag());
    jt6295 #(.INTERPOL(0),.SAMPLE(1)) oki(
        .rst(reset),.clk(clk),.cen(oki_cen),.ss(1'b1),.wrn(oki_wrn),
        .din(cpu_wdata[7:0]),.dout(oki_status),.rom_addr(oki_addr),
        .rom_data(oki_data),.rom_ok(oki_ok),.sound(audio),.sample(audio_sample));
    fx68k cpu(
        .clk(clk),.HALTn(1'b1),.extReset(reset),.pwrUp(reset),
        .enPhi1(phi1),.enPhi2(phi2),.eRWn(rwn),.ASn(asn),.LDSn(ldsn),.UDSn(udsn),
        .E(),.VMAn(),.FC0(fc0),.FC1(fc1),.FC2(fc2),.BGn(),.oRESETn(),.oHALTEDn(debug_haltedn),
        .DTACKn(dtackn),.VPAn(!iack),.BERRn(1'b1),.BRn(1'b1),.BGACKn(1'b1),
        .IPL0n(1'b1),.IPL1n(1'b1),.IPL2n(!irq),.iEdb(cpu_rdata),.oEdb(cpu_wdata),.eab(cpu_a));
    assign debug_cpu_addr=address;
    assign debug_cpu_wdata=cpu_wdata;
    assign debug_fc={fc2,fc1,fc0};
    assign debug_asn=asn;
    assign debug_rwn=rwn;
endmodule
