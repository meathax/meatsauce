// SPDX-License-Identifier: MIT
module fb100a_cpu (
    input  wire        clk_sys,
    input  wire        ce_cpu,
    input  wire        reset_n,
    input  wire        nmi_request,
    input  wire [7:0]  buttons,
    input  wire [7:0]  joys,
    input  wire [7:0]  dip1,
    input  wire [7:0]  dip2,
    input  wire [9:0]  video_scan_addr,
    input  wire [9:0]  tile_scan_addr,
    input  wire [13:0] graphics_scan_addr,
    input  wire [7:0]  prom_scan_index,
    input  wire        ioctl_write,
    input  wire [1:0]  ioctl_index,
    input  wire [14:0] ioctl_addr,
    input  wire [7:0]  ioctl_data,
    output wire [15:0] debug_address,
    output wire        debug_m1_n,
    output wire        debug_mreq_n,
    output wire        debug_rd_n,
    output wire        debug_wr_n,
    output wire [7:0]  debug_data_out,
    output wire        nmi_enabled,
    output wire [1:0]  color_bank,
    output wire [1:0]  character_bank,
    output wire        flip_x,
    output wire        flip_y,
    output wire        ay_select,
    output wire        ay_write,
    output wire [7:0]  ay_data,
    output reg  [7:0]  video_scan_data,
    output reg  [7:0]  tile_scan_data,
    output reg  [7:0]  graphics_scan_data,
    output reg  [3:0]  prom_scan_red,
    output reg  [3:0]  prom_scan_green,
    output reg  [3:0]  prom_scan_blue,
    output reg  [7:0]  background_color
);
    reg [7:0] program_rom [0:32767];
    reg [7:0] graphics_rom [0:12287];
    reg [7:0] color_prom [0:767];
    reg [7:0] work_ram [0:2047];
    reg [7:0] video_ram [0:1023];
    reg [7:0] tile_ram [0:1023];

    wire m1_n,mreq_n,iorq_n,rd_n,wr_n,rfsh_n,halt_n,busak_n;
    wire [15:0] cpu_address;
    wire [7:0] cpu_data_out;
    reg [7:0] read_data=0;
    reg read_valid=0;
    wire memory_read=(mreq_n==0 && rd_n==0 && iorq_n==1);
    wire memory_write=(mreq_n==0 && wr_n==0 && iorq_n==1);
    wire wait_n=~memory_read || read_valid;

    tv80s #(.Mode(0),.T2Write(0),.IOWait(1)) main_cpu (
        .reset_n(reset_n),.clk(clk_sys),.cen(ce_cpu),.wait_n(wait_n),
        .int_n(1'b1),.nmi_n(~nmi_pending),.busrq_n(1'b1),
        .m1_n(m1_n),.mreq_n(mreq_n),.iorq_n(iorq_n),.rd_n(rd_n),.wr_n(wr_n),
        .rfsh_n(rfsh_n),.halt_n(halt_n),.busak_n(busak_n),.A(cpu_address),
        .di(read_data),.dout(cpu_data_out)
    );

    reg [7:0] output_latch=0;
    reg nmi_pending=0;
    always @(posedge clk_sys) begin
        video_scan_data<=video_ram[video_scan_addr];
        tile_scan_data<=tile_ram[tile_scan_addr];
        graphics_scan_data<=graphics_rom[graphics_scan_addr];
        prom_scan_red<=color_prom[{2'b00,prom_scan_index}][3:0];
        prom_scan_green<=color_prom[{2'b01,prom_scan_index}][3:0];
        prom_scan_blue<=color_prom[{2'b10,prom_scan_index}][3:0];
        if (ioctl_write) begin
            case(ioctl_index)
                0: program_rom[ioctl_addr]<=ioctl_data;
                1: if (ioctl_addr<15'd12288) graphics_rom[ioctl_addr[13:0]]<=ioctl_data;
                2: if (ioctl_addr<15'd768) color_prom[ioctl_addr[9:0]]<=ioctl_data;
                default: begin end
            endcase
        end
        if (!reset_n) begin
            read_valid<=0;
            nmi_pending<=0;
            output_latch<=0;
            background_color<=0;
        end else if (memory_read) begin
            if (!read_valid) begin
                if (cpu_address<=16'h7fff) read_data<=program_rom[cpu_address[14:0]];
                else if (cpu_address>=16'hc000 && cpu_address<=16'hc7ff) read_data<=work_ram[cpu_address[10:0]];
                else if (cpu_address>=16'hc800 && cpu_address<=16'hcfff)
                    read_data<=(cpu_address==16'hc900) ? 8'h63 : 8'h00;
                else if (cpu_address>=16'hd000 && cpu_address<=16'hd3ff) read_data<=video_ram[cpu_address[9:0]];
                else if (cpu_address>=16'hd800 && cpu_address<=16'hdfff) read_data<=tile_ram[cpu_address[9:0]];
                else if (cpu_address==16'he800) read_data<=dip1;
                else if (cpu_address==16'he801) read_data<=dip2;
                else if (cpu_address==16'he802) read_data<=buttons;
                else if (cpu_address==16'he803) read_data<=joys;
                else read_data<=8'h00;
            end
            read_valid<=1;
        end else read_valid<=0;

        if (nmi_request && output_latch[1]) nmi_pending<=1;
        else if (m1_n==0 && ce_cpu) nmi_pending<=0;

        if (reset_n && memory_write) begin
            if (cpu_address>=16'hc000 && cpu_address<=16'hc7ff)
                work_ram[cpu_address[10:0]]<=cpu_data_out;
            else if (cpu_address>=16'hd000 && cpu_address<=16'hd03f)
                video_ram[cpu_address[9:0]]<=cpu_data_out;
            else if (cpu_address>=16'hd040 && cpu_address<=16'hd05f)
                video_ram[cpu_address[9:0]]<=cpu_data_out;
            else if (cpu_address>=16'hd060 && cpu_address<=16'hd3ff)
                video_ram[cpu_address[9:0]]<=cpu_data_out;
            else if (cpu_address>=16'hd800 && cpu_address<=16'hdfff)
                tile_ram[cpu_address[9:0]]<=cpu_data_out;
            else if (cpu_address>=16'hf000 && cpu_address<=16'hf7ff)
                output_latch[cpu_address[2:0]]<=cpu_data_out[0];
            else if (cpu_address==16'he000)
                background_color<=cpu_data_out;
        end
    end

    assign debug_address=cpu_address;
    assign debug_m1_n=m1_n;
    assign debug_mreq_n=mreq_n;
    assign debug_rd_n=rd_n;
    assign debug_wr_n=wr_n;
    assign debug_data_out=cpu_data_out;
    assign nmi_enabled=output_latch[1];
    assign color_bank={output_latch[4],output_latch[3]};
    assign character_bank={output_latch[5],output_latch[4]};
    assign flip_x=output_latch[6];
    assign flip_y=output_latch[7];
    assign ay_select=cpu_address[0];
    assign ay_write=(memory_write && cpu_address>=16'hf800 && cpu_address<=16'hf801);
    // TV80 data is stable for the complete registered write phase; feeding
    // it directly avoids a one-root-clock stale-byte race with the AY wrapper.
    assign ay_data=cpu_data_out;
endmodule
