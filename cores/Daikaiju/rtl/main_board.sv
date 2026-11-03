module daikaiju_main_board (
    input  logic        clk_sys,
    input  logic        reset_n,
    input  logic        ce_6mhz,
    input  logic        pause_req,
    output logic        pause_ack,
    input  logic        irq_vblank,
    input  logic        sound_command_ack,
    input  logic [7:0]  mcu_data_in,
    input  logic        rom_write,
    input  logic [16:0] rom_write_address,
    input  logic [15:0] rom_write_data,
    input  logic [15:0] hiscore_mem_address,
    input  logic        hiscore_mem_write,
    input  logic [7:0]  hiscore_mem_write_data,
    output logic [7:0]  hiscore_mem_read_data,
    output logic        hiscore_cpu_write,
    output logic [15:0] hiscore_cpu_address,
    output logic [7:0]  hiscore_cpu_write_data,
    input  logic [7:0]  dip_a,
    input  logic [7:0]  dip_b,
    input  logic [7:0]  player1,
    input  logic [7:0]  player2,
    input  logic [7:0]  starts_service,
    input  logic [7:0]  service_tilt,
    input  logic [7:0]  mcu_status,
    output logic [7:0]  sound_command,
    output logic        sound_command_pending,
    output logic [7:0]  mcu_data_out,
    output logic        mcu_data_read,
    output logic        mcu_data_write,
    output logic [7:0]  mcu_data_write_data,
    input  logic [13:0] video_scan_address,
    output logic [7:0]  video_scan_data,
    output logic [7:0]  work_address_debug,
    output logic [15:0] cpu_address_debug,
    output logic        cpu_m1_n_debug,
    output logic [2:0]  rom_bank_debug,
    output logic        flip_debug
);
    wire [7:0] rom_data_q;
    wire [16:0] program_read_address;
    a74_wide_rom #(.AW(17),.BYTES(98304)) program_rom_store(
        .clk(clk_sys),.write_enable(rom_write),.write_address(rom_write_address),
        .write_data(rom_write_data),.read_address(program_read_address),.read_data(rom_data_q));
    logic rom_data_valid = 1'b0;
    logic [7:0] input_data_q = 8'hff;
    logic [7:0] video_data_q;
    logic [7:0] hiscore_work_data_q, hiscore_video_data_q;
    logic hiscore_video_selected_q;
    logic [12:0] ram_dout_unused;
    logic [7:0] ram_dout;
    logic [7:0] cpu_dout;
    logic [15:0] cpu_address;
    logic cpu_cen, m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n;
    typedef enum logic [1:0] {PAUSE_RUN, PAUSE_WAIT_BUSACK, PAUSE_HELD, PAUSE_RESUME} pause_state_t;
    pause_state_t pause_state = PAUSE_RUN;
    logic busrq_n;
    logic irq_pending = 1'b0;
    logic [2:0] rom_bank = '0;
    logic flip_screen = 1'b0;
    logic [7:0] p1_default = 8'hff;

    assign program_read_address=(cpu_address<16'h8000)?{1'b0,cpu_address}:
        17'h8000+{1'b0,rom_bank,cpu_address[12:0]};
    wire work_ram_selected = (cpu_address >= 16'ha000) && (cpu_address <= 16'hbfff);
    wire rom_selected = cpu_address < 16'ha000;
    wire video_ram_selected = (cpu_address >= 16'hc000) && (cpu_address <= 16'he7ff);
    wire hiscore_work_selected = (hiscore_mem_address >= 16'ha000) && (hiscore_mem_address <= 16'hbfff);
    wire hiscore_video_selected = (hiscore_mem_address >= 16'hc000) && (hiscore_mem_address <= 16'he7ff);
    wire mem_read = !mreq_n && !rd_n;
    wire mem_write = cpu_cen && !mreq_n && !wr_n;

    assign busrq_n = (pause_state == PAUSE_RUN) || (pause_state == PAUSE_RESUME);
    assign pause_ack = (pause_state == PAUSE_HELD) || (pause_state == PAUSE_RESUME);

    // A pause request is not a bus-cycle boundary. Continue nominal and
    // recovery CEs until the Z80 itself asserts BUSACK, then hold BUSRQ through
    // pause and release it only when the request clears.
    always_ff @(posedge clk_sys) begin
        if (!reset_n) begin
            pause_state <= PAUSE_RUN;
        end else begin
            case (pause_state)
                PAUSE_RUN: if (pause_req) pause_state <= PAUSE_WAIT_BUSACK;
                PAUSE_WAIT_BUSACK: begin
                    if (!pause_req) begin
                        if (busak_n) pause_state <= PAUSE_RUN;
                        else pause_state <= PAUSE_RESUME;
                    end else if (!busak_n) begin
                        pause_state <= PAUSE_HELD;
                    end
                end
                PAUSE_HELD: if (!pause_req) pause_state <= PAUSE_RESUME;
                PAUSE_RESUME: begin
                    if (pause_req) begin
                        if (busak_n) pause_state <= PAUSE_WAIT_BUSACK;
                        else pause_state <= PAUSE_HELD;
                    end else if (busak_n) begin
                        pause_state <= PAUSE_RUN;
                    end
                end
                default: pause_state <= PAUSE_RUN;
            endcase
        end
    end

    a74_video_memory video_memory (
        .clk_sys(clk_sys),
        .cpu_read(mem_read && video_ram_selected),
        .cpu_write(mem_write && video_ram_selected),
        .cpu_address(cpu_address), .cpu_write_data(cpu_dout),
        .cpu_read_data(video_data_q),
        .hiscore_address(hiscore_video_selected ? hiscore_mem_address[13:0] : 14'd0),
        .hiscore_we(hiscore_mem_write && hiscore_video_selected),
        .hiscore_write_data(hiscore_mem_write_data), .hiscore_read_data(hiscore_video_data_q),
        .video_address(video_scan_address), .video_data(video_scan_data)
    );

    jtframe_sysz80 #(.RAM_AW(13), .RECOVERY(1)) main_z80 (
        .rst_n(reset_n), .clk(clk_sys), .cen(ce_6mhz), .cpu_cen(cpu_cen),
        .int_n(!irq_pending), .nmi_n(1'b1), .busrq_n(busrq_n),
        .m1_n(m1_n), .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n),
        .rfsh_n(rfsh_n), .halt_n(halt_n), .busak_n(busak_n), .A(cpu_address),
        .cpu_din(rom_selected ? rom_data_q : (work_ram_selected ? ram_dout :
                 (video_ram_selected ? video_data_q :
                 ((cpu_address == 16'hee00) ? mcu_data_in : input_data_q)))),
        .cpu_dout(cpu_dout), .ram_dout(ram_dout), .ram_cs(work_ram_selected),
        .rom_cs(rom_selected), .rom_ok(rom_data_valid),
        .prog_addr(hiscore_mem_address[12:0]), .prog_data(hiscore_mem_write_data),
        .prog_din(hiscore_work_data_q),
        .prog_we(hiscore_mem_write && hiscore_work_selected)
    );

    always_ff @(posedge clk_sys)
        hiscore_video_selected_q <= hiscore_video_selected;

    always_comb begin
        hiscore_mem_read_data = hiscore_video_selected_q ? hiscore_video_data_q : hiscore_work_data_q;
        hiscore_cpu_write = reset_n && mem_write && (work_ram_selected || video_ram_selected);
        hiscore_cpu_address = cpu_address;
        hiscore_cpu_write_data = cpu_dout;
    end

    always_ff @(posedge clk_sys) begin
        if (!reset_n) begin
            rom_data_valid <= 1'b0;
        end else if (rom_selected) begin
            rom_data_valid <= 1'b1;
        end else begin
            rom_data_valid <= 1'b0;
        end
        if (mem_read && !rom_selected) begin
            case (cpu_address)
                16'he800: input_data_q <= dip_a;
                16'he801: input_data_q <= dip_b;
                16'he803: input_data_q <= mcu_status;
                16'he804: input_data_q <= player1;
                16'he805: input_data_q <= player2;
                16'he806: input_data_q <= starts_service;
                16'he807: input_data_q <= service_tilt;
                default:  input_data_q <= 8'hff;
            endcase
        end

        if (!reset_n) begin
            rom_bank <= '0;
            flip_screen <= 1'b0;
            sound_command <= '0;
            sound_command_pending <= 1'b0;
            irq_pending <= 1'b0;
        end else begin
            if (irq_vblank) irq_pending <= 1'b1;
            if (!iorq_n && !m1_n) irq_pending <= 1'b0;
            if (mem_write) begin
                if (cpu_address == 16'hea00) begin
                    rom_bank <= cpu_dout[2:0];
                    flip_screen <= cpu_dout[4];
                end
                if (cpu_address == 16'hec00) begin
                    sound_command <= cpu_dout;
                    sound_command_pending <= 1'b1;
                end
            end
            if (sound_command_ack) sound_command_pending <= 1'b0;
        end
    end

    assign mcu_data_write = mem_write && (cpu_address == 16'hee00);
    assign mcu_data_read = mem_read && (cpu_address == 16'hee00);
    assign mcu_data_write_data = cpu_dout;
    assign mcu_data_out = mcu_data_in;
    assign work_address_debug = cpu_address[7:0];
    assign cpu_address_debug = cpu_address;
    assign cpu_m1_n_debug = m1_n;
    assign rom_bank_debug = rom_bank;
    assign flip_debug = flip_screen;
endmodule
