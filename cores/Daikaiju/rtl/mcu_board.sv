// Taito A74 PC030CM host interface around the JTFRAME 68705P5-class core.
// Handshake polarity and latch edges follow MAME's taito68705_mcu_device.
module daikaiju_mcu_board (
    input  logic        clk_sys,
    input  logic        reset_n,
    input  logic        ce_osc_3mhz,
    input  logic        host_data_write,
    input  logic [7:0]  host_write_data,
    input  logic        host_data_read,
    input  logic [1:0]  coin_active,
    input  logic        rom_download_write,
    input  logic [10:0] rom_download_address,
    input  logic [15:0] rom_download_data,
    output logic [7:0]  host_data_read_value,
    output logic [7:0]  host_status,
    output logic [1:0]  host_flags_debug,
    output logic [7:0]  pa_input_debug,
    output logic [3:0]  pc_input_debug,
    output logic        host_irq_debug,
    output logic [12:0] mcu_address_debug,
    output logic [7:0]  mcu_pa_debug,
    output logic [7:0]  mcu_pb_debug,
    output logic [3:0]  mcu_pc_debug
);
    wire [7:0] mcu_rom_q;
    logic [10:0] mcu_rom_address;
    logic [7:0] host_latch = 8'hff;
    logic [7:0] mcu_latch = 8'hff;
    logic host_flag = 1'b0;
    logic mcu_flag = 1'b0;
    logic latch_driven = 1'b0;
    logic previous_pb1 = 1'b1;
    logic previous_pb2 = 1'b1;
    wire [7:0] pa_in = latch_driven ? host_latch : 8'hff;
    wire [3:0] pc_in = {2'b11, ~mcu_flag, host_flag};
    wire [7:0] mcu_pa_out, mcu_pb_out, mcu_dout;
    wire [3:0] mcu_pc_out;
    wire [12:0] mcu_addr;
    wire mcu_wr, mcu_tstop, mcu_rom_cs;

    a74_wide_rom #(.AW(11),.BYTES(2048)) mcu_rom_store(
        .clk(clk_sys),.write_enable(rom_download_write),.write_address(rom_download_address),
        .write_data(rom_download_data),.read_address(mcu_rom_address),.read_data(mcu_rom_q));

    always_ff @(posedge clk_sys) begin

        if (!reset_n) begin
            host_latch <= 8'hff;
            mcu_latch <= 8'hff;
            host_flag <= 1'b0;
            mcu_flag <= 1'b0;
            latch_driven <= 1'b0;
            previous_pb1 <= 1'b1;
            previous_pb2 <= 1'b1;
        end else begin
            previous_pb1 <= mcu_pb_out[1];
            previous_pb2 <= mcu_pb_out[2];
            latch_driven <= ~mcu_pb_out[1];

            // PB1 rising releases the host latch and acknowledges host data.
            if (mcu_pb_out[1] && !previous_pb1)
                host_flag <= 1'b0;

            // PB2 falling latches the MCU result and raises its semaphore.
            if (!mcu_pb_out[2] && previous_pb2) begin
                mcu_latch <= mcu_pa_out & (latch_driven ? host_latch : 8'hff);
                mcu_flag <= 1'b1;
            end

            // The host read clears the result semaphore, not the data latch.
            if (host_data_read) mcu_flag <= 1'b0;
            if (host_data_write) begin
                host_latch <= host_write_data;
                host_flag <= 1'b1;
            end
        end
    end

    jtframe_6805mcu #(.ROMW(11)) core (
        .clk(clk_sys), .rst(!reset_n), .cen(ce_osc_3mhz),
        .wr(mcu_wr), .addr(mcu_addr), .dout(mcu_dout),
        .irq(host_flag), .timer(1'b0),
        .pa_in(pa_in), .pa_out(mcu_pa_out),
        .pb_in(8'hff), .pb_out(mcu_pb_out),
        .pc_in(pc_in), .pc_out(mcu_pc_out),
        .rom_addr(mcu_rom_address), .rom_data(mcu_rom_q), .rom_cs(mcu_rom_cs)
    );

    assign host_data_read_value = mcu_latch;
    // The Daikaiju ROM polls E803 bit 4 before draining its sound-command
    // queue. MAME's daikaiju_mcu_status_r keeps this input pull-up asserted.
    assign host_status = {3'b000, 1'b1, coin_active[1], coin_active[0], ~mcu_flag, ~host_flag};
    assign host_flags_debug = {host_flag, mcu_flag};
    assign pa_input_debug = pa_in;
    assign pc_input_debug = pc_in;
    assign host_irq_debug = host_flag;
    assign mcu_address_debug = mcu_addr;
    assign mcu_pa_debug = mcu_pa_out;
    assign mcu_pb_debug = mcu_pb_out;
    assign mcu_pc_debug = mcu_pc_out;
endmodule
