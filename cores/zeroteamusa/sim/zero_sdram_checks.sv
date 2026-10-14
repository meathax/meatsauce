// Pin-level controller probe. Synthetic SDRAM contents are test data only.
module zero_sdram_checks (
    input wire clk, clk_forward, init,
    input wire [23:0] address,
    input wire [15:0] write_data, model_dq,
    input wire [1:0] selected, write_mask,
    input wire [3:0] request,
    input wire [1:0] length,
    output wire beat,
    output wire [3:0] acknowledge,
    output wire [15:0] read_data, pin_write_data,
    output wire ready,
    output wire [2:0] command,
    output wire [12:0] pin_address,
    output wire [1:0] bank, dqm
);
    wire [15:0] dq;
    // Poison outside the memory's valid window; disconnect for FPGA writes.
    assign dq = dut.sdram_dq_oe ? 16'bz : model_dq;
    assign pin_write_data = dut.sdram_dq_out;
    wire nras, ncas, nwe;
    assign command = {nras,ncas,nwe};
    sdram dut (
        .clk(clk),.init(init),.prio_mode(2'b01),.ready(ready),
        .SDRAM_DQ(dq),.SDRAM_A(pin_address),.SDRAM_BA(bank),
        .SDRAM_DQML(dqm[0]),.SDRAM_DQMH(dqm[1]),
        .SDRAM_nRAS(nras),.SDRAM_nCAS(ncas),.SDRAM_nWE(nwe),
        .addr0(address),.din0(write_data),
        .wrl0(selected==0 && write_mask[0]),.wrh0(selected==0 && write_mask[1]),
        .req0(request[0]),.ack0(acknowledge[0]),.dout0(read_data),
        .rd_len0(length),.beat0(beat),
        .addr1(address),.din1(write_data),
        .wrl1(selected==1 && write_mask[0]),.wrh1(selected==1 && write_mask[1]),
        .req1(request[1]),.ack1(acknowledge[1]),
        .addr2(address),.din2(write_data),
        .wrl2(selected==2 && write_mask[0]),.wrh2(selected==2 && write_mask[1]),
        .req2(request[2]),.ack2(acknowledge[2]),
        .addr3(address),.din3(write_data),
        .wrl3(selected==3 && write_mask[0]),.wrh3(selected==3 && write_mask[1]),
        .req3(request[3]),.ack3(acknowledge[3])
    );
endmodule
