// Exact private candidate storage/control extraction. No CPU model or game claim.
module ram_candidate_inference_probe_replicated(
 input wire clk,held_reset,pause_game,paused,hs_access,hs_write,
 input wire [23:0] hs_addr,maddr,
 input wire [23:1] ma,
 input wire [15:0] mdout,main_rom_addr_q,
 input wire [7:0] hs_data_in,credits,
 input wire [1:0] coins_n,
 input wire coin_latch,mas_n,bus_done,iack,mrw_n,muds_n,mlds_n,
 input wire [11:0] debug_word_addr,
 output wire [7:0] hs_data_out,
 output wire [15:0] work_cpu_q,strip_cpu_q,
 output reg [15:0] renderer_q=0
);
    logic [7:0] work_hi [0:2047],work_lo [0:2047];
    logic [7:0] strip_hi [0:4095],strip_lo [0:4095];
    logic [7:0] renderer_strip_hi [0:4095],renderer_strip_lo [0:4095];
    logic [15:0] work_word22=0;
    logic [7:0] work29_high=0;
    logic [7:0] work_hi_q=0,work_lo_q=0,strip_hi_q=0,strip_lo_q=0;
    logic [15:0] work22_q=0;
    logic work_q_is22=0,hs_read_active=0,hs_read_odd=0;
    logic [7:0] hs_hold=0;
    logic [1:0] response_kind=0;
    wire [15:0] work_q=work_q_is22 ? work22_q : {work_hi_q,work_lo_q};
    wire [15:0] strip_q={strip_hi_q,strip_lo_q};
    wire [7:0] hs_current=hs_read_odd ? work_q[7:0] : work_q[15:8];
    assign hs_data_out=hs_read_active ? hs_current : hs_hold;

 initial begin
   for(integer i=0;i<2048;i=i+1) begin work_hi[i]=0;work_lo[i]=0;end
   for(integer i=0;i<4096;i=i+1) begin strip_hi[i]=0;strip_lo[i]=0;renderer_strip_hi[i]=0;renderer_strip_lo[i]=0;end
 end
 assign work_cpu_q=work_q;
 assign strip_cpu_q=strip_q;
 always @(posedge clk) renderer_q<={renderer_strip_hi[debug_word_addr],renderer_strip_lo[debug_word_addr]};
    // Exact accepted edge; no CPU enable, AS, byte-strobe or DTACK change.
    wire ram_bus_service=!held_reset && !pause_game && !mas_n && !bus_done
        && (iack || !muds_n || !mlds_n)
        && (iack || maddr>=24'h020000 || main_rom_addr_q==ma[16:1]);
    wire cpu_work_service=ram_bus_service && !iack && maddr>=24'h020000 && maddr<24'h021000;
    wire cpu_strip_service=ram_bus_service && !iack && maddr>=24'h040000 && maddr<24'h042000;
    wire hs_work_service=!held_reset && pause_game && paused && hs_access
        && hs_addr>=24'h020000 && hs_addr<24'h021000;
    wire hle_service=ram_bus_service && !iack && mrw_n && maddr>=24'h080000 && maddr<24'h080200;
    wire hle_coin=hle_service && ma[8:1]==8'h29 && !coin_latch && coins_n!=2'b11;
    wire hle_low_write=hle_service && (ma[8:1]==8'h22 || ma[8:1]==8'hff || ma[8:1]==8'h29);
    wire [10:0] work_port_addr=hs_work_service ? hs_addr[11:1] :
                             cpu_work_service ? ma[11:1] : {3'd0,ma[8:1]};
    wire work_write_hi=(hs_work_service && hs_write && !hs_addr[0])
                      || (cpu_work_service && !mrw_n && !muds_n);
    wire work_write_lo=(hs_work_service && hs_write && hs_addr[0])
                      || (cpu_work_service && !mrw_n && !mlds_n) || hle_low_write;
    wire [7:0] work_data_hi=hs_work_service ? hs_data_in : mdout[15:8];
    wire [7:0] work_data_lo=hs_work_service ? hs_data_in : cpu_work_service ? mdout[7:0] :
                  ma[8:1]==8'h22 ? credits : ma[8:1]==8'hff ? 8'h12 : hle_coin ? 8'h22 : 8'h00;
    // Write-only full-byte banks plus one selected synchronous read port.
    // The cross-port old-data contract includes hiscore write/read and CPU DI.
    always @(posedge clk) begin
        if(work_port_addr!=11'h22) begin
            if(work_write_hi) work_hi[work_port_addr]<=work_data_hi;
            if(work_write_lo) work_lo[work_port_addr]<=work_data_lo;
        end
        if(cpu_work_service || hs_work_service) begin
            work_hi_q<=work_hi[work_port_addr];
            work_lo_q<=work_lo[work_port_addr];
            work22_q<=work_word22;
            work_q_is22<=work_port_addr==11'h22;
        end
        if(hs_read_active && !hs_work_service) hs_hold<=hs_current;
        hs_read_active<=hs_work_service;
        if(hs_work_service) hs_read_odd<=hs_addr[0];
        if(work_write_hi && work_port_addr==11'h29) work29_high<=work_data_hi;
        // Word0x22 is a tiny external register. Coin writes it simultaneously
        // with low0x29; RHS shadow is the original pre-edge high0x29.
        if(work_port_addr==11'h22) begin
            if(work_write_hi) work_word22[15:8]<=work_data_hi;
            if(work_write_lo) work_word22[7:0]<=work_data_lo;
        end
        if(hle_coin) work_word22<={work29_high,8'd0};
    end
    // Two SDP copies avoid unsupported true-dual-port inference. Every byte
    // write updates both copies; CPU and physical renderer read OLD_DATA.
    // Extra65536bits remain subject to the complete fitted resource gates.
    always @(posedge clk) begin
        if(cpu_strip_service) begin
            strip_hi_q<=strip_hi[ma[12:1]];
            strip_lo_q<=strip_lo[ma[12:1]];
        end
        if(cpu_strip_service && !mrw_n) begin
            if(!muds_n) begin
                strip_hi[ma[12:1]]<=mdout[15:8];
                renderer_strip_hi[ma[12:1]]<=mdout[15:8];
            end
            if(!mlds_n) begin
                strip_lo[ma[12:1]]<=mdout[7:0];
                renderer_strip_lo[ma[12:1]]<=mdout[7:0];
            end
        end
    end

endmodule
