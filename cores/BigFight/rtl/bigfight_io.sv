module bigfight_io (
    input  logic        clk,
    input  logic        reset,
    input  logic        cold_start,
    input  logic        req,
    input  logic        wr,
    input  logic [23:1] address,
    input  logic        uds_n,
    input  logic        lds_n,
    input  logic [15:0] din,
    input  logic [7:0]  service_i,
    input  logic [7:0]  p1_i,
    input  logic [7:0]  p2_i,
    input  logic [7:0]  p3_i,
    input  logic [7:0]  p4_i,
    input  logic [7:0]  dsw1_i,
    input  logic [7:0]  dsw2_i,
    input  logic [7:0]  dsw3_i,
    output logic        selected,
    output logic [15:0] dout,
    output logic        slave_halt_o
);

    logic [39:0] io1_ports_i;
    logic [39:0] io2_ports_i;
    logic [7:0] io1_dout;
    logic [7:0] io2_dout;
    logic [39:0] io1_port_values;
    logic [39:0] io1_port_masks;
    logic [39:0] io2_port_values;
    logic [39:0] io2_port_masks;
    logic io1_write_cb_strobe;
    logic [2:0] io1_write_cb_port;
    logic io2_write_cb_strobe;
    logic [2:0] io2_write_cb_port;

    wire io1_select = address[23:4] == 20'h0b900;
    wire io2_select = address[23:4] == 20'h0ba00;
    // MAME maps an 8-bit handler with a 16-bit chip-select width. Its 68000
    // byte-write path presents the byte on both data halves and selects the
    // addressed lane, so either lane can invoke the handler. The CXD consumes
    // the low byte of din after that bus normalization.
    wire io1_write_accept = io1_select && req && wr && (!uds_n || !lds_n);
    wire io2_write_accept = io2_select && req && wr && (!uds_n || !lds_n);
    wire io1_cs = io1_select && (!wr || (req && (!uds_n || !lds_n)));
    wire io2_cs = io2_select && (!wr || (req && (!uds_n || !lds_n)));
    wire io2_porte_write = io2_write_accept && (address[3:1] == 3'd4);

    // CXD1095 ports are ordered A in bits 7:0 through E in bits 39:32.
    // Unwired ports return zero through the MAME model's absent input callback.
    always_comb begin
        io1_ports_i = {dsw3_i, p2_i, p1_i, service_i, 8'h00};
        io2_ports_i = {8'h00, p4_i, p3_i, dsw2_i, dsw1_i};
    end

    bigfight_cxd1095 io1 (
        .clk(clk),
        .reset(reset),
        .cold_start(cold_start),
        .cs(io1_cs),
        .wr(wr),
        .address(address[3:1]),
        .din(din[7:0]),
        .ports_i(io1_ports_i),
        .dout(io1_dout),
        .port_values_o(io1_port_values),
        .port_masks_o(io1_port_masks),
        .write_cb_strobe_o(io1_write_cb_strobe),
        .write_cb_port_o(io1_write_cb_port)
    );

    bigfight_cxd1095 io2 (
        .clk(clk),
        .reset(reset),
        .cold_start(cold_start),
        .cs(io2_cs),
        .wr(wr),
        .address(address[3:1]),
        .din(din[7:0]),
        .ports_i(io2_ports_i),
        .dout(io2_dout),
        .port_values_o(io2_port_values),
        .port_masks_o(io2_port_masks),
        .write_cb_strobe_o(io2_write_cb_strobe),
        .write_cb_port_o(io2_write_cb_port)
    );

    // MAME's unmapped value for this address space is zero. Only lanes selected
    // for a read are driven: the high lane is unconnected and reads zero, while
    // the CXD1095 drives the low lane. With no lane selected, keep the inactive
    // adapter value at all ones.
    always_comb begin
        selected = io1_select || io2_select;
        dout = 16'hffff;
        if (selected && !wr && (!uds_n || !lds_n)) begin
            dout[15:8] = 8'h00;
            dout[7:0] = 8'h00;
            if (!lds_n) begin
                if (io1_select)
                    dout[7:0] = io1_dout;
                else if (io2_select)
                    dout[7:0] = io2_dout;
            end
        end
    end

    // MAME calls the E output callback only for a data-port write. Its callback
    // data is the written latch masked by the current output direction. The
    // direction register itself does not alter the slave HALT line.
    always_ff @(posedge clk) begin
        if (reset || cold_start)
            slave_halt_o <= 1'b0;
        else if (io2_porte_write)
            slave_halt_o <= din[2] && io2_port_masks[34];
    end

endmodule
