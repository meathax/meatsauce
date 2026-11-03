// A74 video-board byte RAM, exposed on the main Z80 port and a synchronous
// scan port. The CPU windows follow the MAME A74 map exactly.
module a74_video_memory (
    input  logic        clk_sys,
    input  logic        cpu_read,
    input  logic        cpu_write,
    input  logic [15:0] cpu_address,
    input  logic [7:0]  cpu_write_data,
    output logic [7:0]  cpu_read_data,
    input  logic [13:0] hiscore_address,
    input  logic        hiscore_we,
    input  logic [7:0]  hiscore_write_data,
    output logic [7:0]  hiscore_read_data,
    input  logic [13:0] video_address,
    output logic [7:0]  video_data
);
    logic [7:0] ram [0:10239]; // c000-e7ff: VRAM, scroll RAM, object RAM
    logic [7:0] scan_ram [0:10239];
    wire [7:0] hiscore_cache_data;
    // Explicit FPGA power-on contents match MAME's zeroed shared RAM.
    // This is configuration initialization, not a RAM reset port.
    integer power_on_page, power_on_byte;
    initial begin
        // Each constant loop stays below Quartus17's 5000-iteration limit.
        for (power_on_page=0;power_on_page<32;power_on_page=power_on_page+1)
            for (power_on_byte=0;power_on_byte<320;power_on_byte=power_on_byte+1) begin
                ram[power_on_page*320+power_on_byte]=8'd0;
                scan_ram[power_on_page*320+power_on_byte]=8'd0;
            end
    end
    logic [13:0] cpu_index;
    assign cpu_index = cpu_address - 16'hc000;

    wire cpu_selected=cpu_address >= 16'hc000 && cpu_address <= 16'he7ff;
    wire write_enable=hiscore_we || (cpu_write && cpu_selected);
    wire [13:0] write_address=hiscore_we ? hiscore_address : cpu_index;
    wire [7:0] write_data=hiscore_we ? hiscore_write_data : cpu_write_data;
    logic [7:0] cpu_data_q;
    logic cpu_valid_q;
    // Restore owns the write port only after CPU BUSACK. Three coherent SDP
    // copies provide independent registered reads with the original old-data
    // collision semantics; no read port is implemented as a large flop mux.
    always_ff @(posedge clk_sys) begin
        if(write_enable) ram[write_address] <= write_data;
        cpu_data_q <= ram[cpu_index];
        cpu_valid_q <= cpu_read && cpu_selected;
    end
    always_ff @(posedge clk_sys) begin
        if(write_enable) scan_ram[write_address] <= write_data;
        video_data <= scan_ram[video_address];
    end
    a74_live_byte_cache #(.AW(14),.INIT_ZERO(1)) hiscore_store(
        .clk(clk_sys),.write_enable(write_enable),.write_address(write_address),.write_data(write_data),
        .read_address(hiscore_address),.read_data(hiscore_cache_data));
    always_ff @(posedge clk_sys) hiscore_read_data <= hiscore_cache_data;
    always_comb cpu_read_data=cpu_valid_q ? cpu_data_q : 8'hff;
    // synthesis translate_off
    always @(posedge clk_sys)
        if(hiscore_we && cpu_write && cpu_selected)
            $fatal(1,"hiscore restore overlaps a CPU video RAM write");
    // synthesis translate_on
endmodule
