// SPDX-License-Identifier: GPL-3.0-or-later
// Physical board memory: live RAM in SDRAM, original ROM/BIOS in DDR,
// persistent NVRAM and the MAME-derived boot/reset region in local memory.
module cs_memory_fabric #(parameter SDRAM_REGISTERED_IO=0, SDRAM_PHASED_CAPTURE=0,
    parameter logic [22:0] CLEAR_LAST=23'h7ffffc, parameter logic [13:0] TEST_LAST=14'h3fff) (
    input logic clk, reset,
    input logic [3:0] cart_banks, // MRA board record: populated flash chips (0 = legacy 3)
    output logic memory_initialized,
    output logic sdram_test_done,
    output logic [15:0] sdram_test_errors,
    output logic [13:0] sdram_test_first_addr,
    output logic [31:0] sdram_test_first_actual,
    input logic req_valid,
    output logic req_ready,
    input logic [3:0] req_target,
    input logic [31:0] req_offset, req_data,
    input logic [3:0] req_strobe,
    input logic req_write,
    output logic rsp_valid,
    output logic [31:0] rsp_data,
    output logic rsp_error,
    input logic load_valid,
    output logic load_ready,
    input logic [3:0] load_target,
    input logic [31:0] load_offset,
    input logic [63:0] load_data,
    input logic [7:0] load_be,
    output logic load_done, load_error,
    input logic backup_valid,
    output logic backup_ready,
    input logic [13:0] backup_address,
    input logic [31:0] backup_data,
    input logic [3:0] backup_strobe,
    input logic backup_write,
    output logic backup_rsp_valid,
    output logic [31:0] backup_rsp_data,
    // GPU 32-byte line burst port, straight to the SDRAM backend (see cs_sdram_backend).
    input logic gpu_burst_valid, gpu_burst_write, gpu_burst_region,
    input logic gpu_burst_urgent,
    input logic [17:0] gpu_burst_line,
    input logic [7:0][31:0] gpu_burst_wdata,
    input logic [7:0][3:0] gpu_burst_wstrobe,
    output logic gpu_burst_ready, gpu_burst_done,
    output logic [7:0][31:0] gpu_burst_rdata,
    // Texture-region word-write snoop for the GPU read caches (see cs_sdram_backend).
    output logic gpu_snoop_valid,
    output logic [17:0] gpu_snoop_line,
    input logic sdram_capture_clk,
    input logic [15:0] sdram_data_in,
    output logic sdram_clk, sdram_cke, sdram_cs_n,
    output logic sdram_ras_n, sdram_cas_n, sdram_we_n,
    output logic [1:0] sdram_dqm, sdram_ba,
    output logic [12:0] sdram_address,
    output logic [15:0] sdram_data_out,
    output logic sdram_data_oe,
    input logic DDRAM_BUSY,
    output logic [7:0] DDRAM_BURSTCNT,
    output logic [28:0] DDRAM_ADDR,
    input logic [63:0] DDRAM_DOUT,
    input logic DDRAM_DOUT_READY,
    output logic DDRAM_RD,
    output logic [63:0] DDRAM_DIN,
    output logic [7:0] DDRAM_BE,
    output logic DDRAM_WE
);
    typedef enum logic [1:0] {LOCAL,SDRAM,DDR} route_t;
    route_t route, owner;
    logic busy, dispatching, local_error;
    logic [3:0] owned_target,owned_strobe;
    logic [31:0] owned_offset,owned_data;
    logic owned_write;
    logic [31:0] local_data, nvram_read;
    logic local_nvram;
    logic s_ready,s_valid,s_error,d_ready,d_valid,d_error;
    logic [31:0] s_data,d_data;
    logic [13:0] nvram_clear_address=0;
    logic nvram_cleared=0, sdram_initialized;
    // MAME zero-initializes work, texture and frame RAM. A real MiSTer SDRAM
    // keeps the previous core's contents, so clear all 24 MiB once at power-up
    // (memory_reset only; game resets keep RAM, as in MAME) before the board runs.
    logic sdram_cleared=0;
    logic [22:0] clear_offset=0;
    logic [1:0] clear_region=0;
    wire clearing=sdram_initialized && !sdram_cleared;
    // Power-up SDRAM self-test of the first 64 KiB (two complementary hashed
    // patterns, write pass then read-back pass) through the real controller.
    // Results are exported for the on-screen hardware diagnostic. The board is
    // released even when errors are found so they can be observed.
    typedef enum logic [1:0] {T_WRITE,T_READ,T_WAIT} tstate_t;
    tstate_t tstate=T_WRITE;
    logic [13:0] tindex=0;
    logic [1:0] tpass=0; // 0/1 complementary patterns, 2 restores zero (MAME power-up RAM)
    wire testing=sdram_cleared && !sdram_test_done;
    wire bist=clearing || testing;
    wire [31:0] tdata=tpass==2 ? 32'b0 : (32'(tindex)*32'h9E3779B1) ^ (tpass[0] ? 32'hffffffff : 32'h5a5aa5a5);
    assign memory_initialized=nvram_cleared && sdram_initialized && sdram_cleared && sdram_test_done;
    logic [31:0] reset_region [0:12];
    // NVRAM powers up zero as MAME DEFAULT_ALL_0. Runtime reset preserves it.
    // Reset-region seed is the driver's reconstructed boot sequence, not a
    // replacement for execution of the original BIOS/cartridge by the CPU.
    initial begin
        for (integer n=0;n<13;n=n+1) reset_region[n]=0;
        reset_region[0]=32'h40c0ea01;reset_region[1]=32'he906400a;
        reset_region[2]=32'h40c02a20;reset_region[3]=32'he906400a;
        reset_region[4]=32'ha1d03a20;reset_region[5]=32'hdef4d4fa;
    end
    wire nvram_ok=owned_target==5 && owned_offset[31:16]==0 && owned_offset[1:0]==0;
    wire reset_ok=owned_target==12 && owned_offset<52 && owned_offset[1:0]==0;
    always_comb begin
        route=LOCAL;
        if(owned_target>=1 && owned_target<=3) route=SDRAM;
        else if(owned_target==0 || owned_target==4) route=DDR;
    end
    // Register one owned token before decode/physical RAM enables.
    assign req_ready=!reset && !busy;
    wire local_take=!reset && busy && dispatching && route==LOCAL && (!nvram_ok || nvram_cleared);
    wire s_take=!reset && !bist && busy && dispatching && route==SDRAM && s_ready;
    wire d_take=!reset && busy && dispatching && route==DDR && d_ready;
    wire accept=req_valid && req_ready;
    wire nvram_accept=local_take && nvram_ok;
    assign backup_ready=!reset && nvram_cleared && !nvram_accept;
    wire backup_accept=backup_valid && backup_ready;
    wire nvram_enable=!nvram_cleared || nvram_accept || backup_accept;
    wire [13:0] nvram_address=!nvram_cleared ? nvram_clear_address : (nvram_accept ? owned_offset[15:2] : backup_address);
    wire nvram_write=!nvram_cleared || (nvram_accept ? owned_write : backup_write);
    wire [31:0] nvram_data=!nvram_cleared ? 32'b0 : (nvram_accept ? owned_data : backup_data);
    wire [3:0] nvram_strobe=!nvram_cleared ? 4'b1111 : (nvram_accept ? owned_strobe : backup_strobe);
    assign backup_rsp_data=nvram_read;
    // Explicit single address/read/write port for Cyclone V block RAM inference.
    initial begin sdram_test_done=0;sdram_test_errors=0;sdram_test_first_addr=0;sdram_test_first_actual=0; end
    always_ff @(posedge clk) begin
        if(testing && !reset) begin
            case(tstate)
                T_WRITE: if(s_ready) begin
                    if(tindex==TEST_LAST) begin
                        tindex<=0;
                        if(tpass==2) sdram_test_done<=1; else tstate<=T_READ;
                    end else tindex<=tindex+1'b1;
                end
                T_READ: if(s_ready) tstate<=T_WAIT;
                T_WAIT: if(s_valid) begin
                    if(s_error || s_data!=tdata) begin
                        if(sdram_test_errors!=16'hffff) sdram_test_errors<=sdram_test_errors+1'b1;
                        if(sdram_test_errors==0) begin sdram_test_first_addr<=tindex;sdram_test_first_actual<=s_data;end
                    end
                    tstate<=T_READ;
                    if(tindex==TEST_LAST) begin
                        tindex<=0;
                        tpass<=tpass+1'b1;tstate<=T_WRITE;
                    end else tindex<=tindex+1'b1;
                end
                default: tstate<=T_WRITE;
            endcase
        end
    end
    always_ff @(posedge clk) begin
        if(reset) begin clear_offset<=0;clear_region<=0;end
        else if(clearing && s_ready) begin
            if(clear_offset==CLEAR_LAST) begin
                clear_offset<=0;
                if(clear_region==2) sdram_cleared<=1;
                else clear_region<=clear_region+1'b1;
            end else clear_offset<=clear_offset+23'd4;
        end
    end
    always_ff @(posedge clk) begin
        // FPGA power-up performs a real port clear, not a large unrolled
        // initializer. Transport/game reset never restarts or erases NVRAM.
        if(!nvram_cleared) begin
            if(nvram_clear_address==16383) nvram_cleared<=1;
            else nvram_clear_address<=nvram_clear_address+1'b1;
        end
    end
    genvar byte_bank;
    generate for(byte_bank=0;byte_bank<4;byte_bank=byte_bank+1) begin : nvram_banks
        cs_nvram_port ram (
            .clk,.enable(nvram_enable && (!reset || !nvram_cleared)),
            .write_enable(nvram_write && nvram_strobe[byte_bank]),
            .address(nvram_address),.write_data(nvram_data[byte_bank*8+:8]),
            .read_data(nvram_read[byte_bank*8+:8])
        );
    end endgenerate
    cs_sdram_backend #(.REGISTERED_IO(SDRAM_REGISTERED_IO),.PHASED_CAPTURE(SDRAM_PHASED_CAPTURE)) sdram (
        .clk,.reset,.sdram_capture_clk(sdram_capture_clk),.initialized(sdram_initialized),
        .req_valid(clearing ? !reset : testing ? (!reset && tstate!=T_WAIT) : busy && dispatching && !reset && route==SDRAM),.req_ready(s_ready),
        .req_target(clearing ? 4'(clear_region)+4'd1 : testing ? 4'd1 : owned_target),
        .req_offset(clearing ? {9'b0,clear_offset} : testing ? {16'b0,tindex,2'b00} : owned_offset),
        .req_data(clearing ? 32'b0 : testing ? tdata : owned_data),.req_strobe(bist ? 4'hf : owned_strobe),
        .req_write(clearing || (testing && tstate==T_WRITE) || (!bist && owned_write)),
        .rsp_valid(s_valid),.rsp_data(s_data),.rsp_error(s_error),
        .burst_valid(gpu_burst_valid && !reset && !bist && sdram_initialized),.burst_write(gpu_burst_write),
        .burst_region(gpu_burst_region),.burst_urgent(gpu_burst_urgent),.burst_line(gpu_burst_line),.burst_wdata(gpu_burst_wdata),
        .burst_wstrobe(gpu_burst_wstrobe),.burst_ready(gpu_burst_ready),.burst_done(gpu_burst_done),
        .burst_rdata(gpu_burst_rdata),
        .texture_snoop_valid(gpu_snoop_valid),.texture_snoop_line(gpu_snoop_line),
        .sdram_data_in,.sdram_clk,.sdram_cke,.sdram_cs_n,.sdram_ras_n,
        .sdram_cas_n,.sdram_we_n,.sdram_dqm,.sdram_ba,.sdram_address,
        .sdram_data_out,.sdram_data_oe
    );
    cs_ddr_rom_backend ddr (
        .clk,.reset,.cart_banks,.req_valid(busy && dispatching && !reset && route==DDR),.req_ready(d_ready),
        .req_target(owned_target),.req_offset(owned_offset),.req_write(owned_write),.rsp_valid(d_valid),.rsp_data(d_data),.rsp_error(d_error),
        .load_valid,.load_ready,.load_target,.load_offset,.load_data,.load_be,.load_done,.load_error,
        .DDRAM_BUSY,.DDRAM_BURSTCNT,.DDRAM_ADDR,.DDRAM_DOUT,.DDRAM_DOUT_READY,
        .DDRAM_RD,.DDRAM_DIN,.DDRAM_BE,.DDRAM_WE
    );
    // Child responses are already registered. Forward the owned response
    // directly rather than adding another wait cycle to every scanout word.
    always_comb begin
        rsp_valid=0;rsp_data=0;rsp_error=0;
        if(!reset && busy && !dispatching) case(owner)
            SDRAM: begin rsp_valid=s_valid;rsp_data=s_data;rsp_error=s_error;end
            DDR: begin rsp_valid=d_valid;rsp_data=d_data;rsp_error=d_error;end
            default: begin rsp_valid=1;rsp_data=local_nvram ? nvram_read : local_data;rsp_error=local_error;end
        endcase
    end
    // One physical NVRAM port. Board access takes priority over backup, so
    // no same-word write collision or independent multiwriter RAM inference.
    always_ff @(posedge clk) begin
        backup_rsp_valid<=0;
        if(reset) begin busy<=0;dispatching<=0;owned_target<=0;owned_offset<=0;owned_data<=0;owned_strobe<=0;owned_write<=0;owner<=LOCAL;local_error<=0;local_data<=0;local_nvram<=0;
            // MAME machine_reset() re-runs patchreset(): the test-menu reset patch RAM is restored on every reset.
            for(int n=0;n<13;n++) reset_region[n]<=32'd0;
            reset_region[0]<=32'h40c0ea01;reset_region[1]<=32'he906400a;
            reset_region[2]<=32'h40c02a20;reset_region[3]<=32'he906400a;
            reset_region[4]<=32'ha1d03a20;reset_region[5]<=32'hdef4d4fa;
        end
        else begin
            if(backup_accept) backup_rsp_valid<=1;
            if(accept) begin
                busy<=1;dispatching<=1;
                owned_target<=req_target;owned_offset<=req_offset;owned_data<=req_data;
                owned_strobe<=req_strobe;owned_write<=req_write;
            end
            if(local_take || s_take || d_take) begin dispatching<=0;owner<=route;end
            if(local_take) begin
                local_nvram<=nvram_ok;
                if(route==LOCAL) begin
                    local_data<=32'hffffffff;local_error<=!(nvram_ok || reset_ok);
                    if(reset_ok) begin
                        local_data<=reset_region[owned_offset[5:2]];
                        if(owned_write) for(int b=0;b<4;b=b+1)
                            if(owned_strobe[b]) reset_region[owned_offset[5:2]][b*8+:8]<=owned_data[b*8+:8];
                    end
                end
            end
            if(rsp_valid) busy<=0;
        end
    end
endmodule
