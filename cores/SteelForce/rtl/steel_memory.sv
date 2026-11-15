// CPU port plus synchronous video port on the single board clock.
// Neither reset nor profile changes erase physical RAM; the 68000 clears it at boot.
module steel_memory #(parameter HISCORE_PORT=0)(
    input logic clk, reset, mortalr,
    input logic cpu_valid, cpu_write,
    input logic [23:0] cpu_addr,
    input logic [15:0] cpu_wdata,
    input logic [1:0] cpu_lanes,
    output wire cpu_ready, cpu_write_grant,
    output wire [15:0] cpu_rdata,
    output wire rom_req,
    output wire [18:0] rom_word_addr,
    input logic rom_ready,
    input logic [15:0] rom_rdata,
    input logic dma_en,
    input logic [16:0] dma_word_addr,
    output wire [15:0] dma_rdata,
    input logic video_en,
    input logic [16:0] video_word_addr,
    output logic [15:0] video_rdata,
    input wire hs_en, hs_write,
    input wire [23:0] hs_addr,
    input wire [7:0] hs_din,
    output wire [7:0] hs_dout
);
    wire is_rom=cpu_addr<24'h100000;
    wire is_ram=cpu_addr>=24'h100000 &&
                cpu_addr<(mortalr?24'h130000:24'h120000);
    logic done;
    wire accept=cpu_valid && !done && !(is_rom && !cpu_write);
    wire hs_access=HISCORE_PORT && hs_en && !dma_en && !reset;
    wire hs_mapped=hs_addr>=24'h100000 && hs_addr<(mortalr?24'h130000:24'h120000);
    wire write_ram=accept && is_ram && cpu_write && !reset && !dma_en && !hs_access;
    wire hs_we=hs_access && hs_mapped && hs_write;
    wire [14:0] ram_a_addr=dma_en ? dma_word_addr[14:0] : hs_access ? hs_addr[15:1] : cpu_addr[15:1];
    wire [23:0] write_addr=hs_access ? hs_addr : cpu_addr;
    wire [15:0] write_data=hs_access ? {hs_din,hs_din} : cpu_wdata;
    wire [1:0] write_lanes=hs_access ? {hs_we && !hs_addr[0],hs_we && hs_addr[0]} : {2{write_ram}} & cpu_lanes;
    logic [1:0] hs_bank;
    logic hs_odd, hs_read_valid;
    logic [15:0] cpu_q [0:2],video_q [0:2];
    logic [1:0] cpu_bank,video_bank,forward_lanes;
    logic video_mapped;
    logic [15:0] forward_data;
    // Three 64 KiB banks keep each memory in the donor's simple dual-port form.
    genvar bank;
    generate for(bank=0;bank<3;bank=bank+1) begin: banks
        localparam [1:0] BANK_ID=bank;
        steel_dpram8 hi_bank(
            .clk(clk), .cpu_we(write_addr[17:16]==BANK_ID && write_lanes[1]),
            .cpu_addr(ram_a_addr), .cpu_data(write_data[15:8]), .cpu_q(cpu_q[bank][15:8]),
            .video_en(video_en), .video_addr(video_word_addr[14:0]), .video_q(video_q[bank][15:8]));
        steel_dpram8 lo_bank(
            .clk(clk), .cpu_we(write_addr[17:16]==BANK_ID && write_lanes[0]),
            .cpu_addr(ram_a_addr), .cpu_data(write_data[7:0]), .cpu_q(cpu_q[bank][7:0]),
            .video_en(video_en), .video_addr(video_word_addr[14:0]), .video_q(video_q[bank][7:0]));
    end endgenerate
    assign dma_rdata=(cpu_bank<3) ? cpu_q[cpu_bank] : 16'hffff;
    assign hs_dout=hs_read_valid && hs_bank<3 ? (hs_odd ? cpu_q[hs_bank][7:0] : cpu_q[hs_bank][15:8]) : 8'hff;
    assign rom_req=cpu_valid && is_rom && !cpu_write;
    assign rom_word_addr=cpu_addr[19:1];
    // SRAM is available before write byte strobes. Actual write_ram still waits
    // for valid lanes and commits once; DMA/score ownership never grants a write.
    assign cpu_write_grant=!reset && !dma_en && !hs_access && is_ram && cpu_write;
    assign cpu_ready=cpu_valid && !hs_access && (rom_req?rom_ready:done);
    assign cpu_rdata=rom_req?rom_rdata:
                     (is_ram && !cpu_write && cpu_bank<3)?cpu_q[cpu_bank]:16'hffff;
    always_comb begin
        video_rdata=16'hffff;
        if(video_mapped && video_bank<3) begin
            video_rdata=video_q[video_bank];
            if(forward_lanes[1]) video_rdata[15:8]=forward_data[15:8];
            if(forward_lanes[0]) video_rdata[7:0]=forward_data[7:0];
        end
    end
`ifdef SIMULATION
    always @(posedge clk) if(!reset) assert(!(dma_en && cpu_valid)) else $fatal(1, "CPU RAM client must be idle during sprite DMA");
`endif
    always_ff @(posedge clk) begin
        hs_bank<=hs_addr[17:16];hs_odd<=hs_addr[0];
        hs_read_valid<=hs_access && hs_mapped;
        cpu_bank<=dma_en ? dma_word_addr[16:15] : cpu_addr[17:16];
        if(reset || !cpu_valid) done<=0;
        else if(accept && !hs_access) done<=1;
        if(video_en) begin
            video_bank<=video_word_addr[16:15];
            video_mapped<=video_word_addr<17'd98304;
            forward_lanes<=0;
            forward_data<=write_data;
            if((write_ram || hs_we) && write_addr[17:1]==video_word_addr)
                forward_lanes<=write_lanes;
        end
    end
endmodule
