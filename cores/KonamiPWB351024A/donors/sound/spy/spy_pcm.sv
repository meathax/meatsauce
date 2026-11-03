// K007232 donor playback with either the preserved byte cache or physical
// SPY ROM block prefetch. Both modes use the same divider/channel/gain kernel.
module spy_pcm #(parameter BLOCK_ROM=0)(
    input logic clk, reset, pause, cen,
    input logic cs, wr,
    input logic [3:0] addr,
    input logic [7:0] din,
    input logic [1:0] bank_a, bank_b,
    output logic rom_req,
    output logic [18:0] rom_addr,
    input logic [7:0] rom_data,
    input logic [31:0] rom_block,
    input logic rom_ok,
    output wire signed [10:0] snda, sndb
);
    wire [16:0] a_addr, b_addr;
    wire a_cs, b_cs;
    wire a_stride,b_stride;
    wire [18:0] a_key = {bank_a,a_addr};
    wire [18:0] b_key = {bank_b,b_addr};
    logic a_valid, b_valid, pending, target;
    logic [18:0] a_tag, b_tag, request_tag;
    logic [7:0] a_data, b_data;
    wire a_ready, b_ready;
    assign rom_req = pending;
    assign rom_addr = request_tag;
    // The local channel adaptation checks readiness at the sample deadline.
    // Short ROM latency must not stop the chip divider and lower pitch.
    spy_pcm_chip #(.REG12A(1)) u_pcm(
        .rst(reset), .clk(clk), .cen(cen && !pause), .pause(pause),
        .addr(addr), .dacs(cs && !pause), .wr_n(!wr), .din(din),
        .cen_q(), .cen_e(), .a_stride(a_stride), .b_stride(b_stride), .swap_gains(1'b0),
        .roma_addr(a_addr), .roma_dout(a_data), .roma_cs(a_cs), .roma_ok(a_ready),
        .romb_addr(b_addr), .romb_dout(b_data), .romb_cs(b_cs), .romb_ok(b_ready),
        .snda(snda), .sndb(sndb), .snd(), .debug_bus(8'd0), .st_dout()
    );
    generate if(BLOCK_ROM)begin: prefetch
        spy_pcm_prefetch u_cache(.clk(clk),.reset(reset),.pause(pause),
            .a_addr(a_addr),.b_addr(b_addr),.a_cs(a_cs),.b_cs(b_cs),.bank_a(bank_a[0]),.bank_b(bank_b[0]),
            .a_stride(a_stride),.b_stride(b_stride),
            .a_data(a_data),.b_data(b_data),.a_ready(a_ready),.b_ready(b_ready),
            .pending(pending),.target(target),.request_tag(request_tag),.rom_data(rom_block),.rom_ok(rom_ok));
    end else begin: byte_cache
    assign a_ready = !a_cs || (a_valid && a_tag == a_key);
    assign b_ready = !b_cs || (b_valid && b_tag == b_key);
    always_ff @(posedge clk) begin
        if (reset) begin
            a_valid <= 0; b_valid <= 0; pending <= 0; target <= 0;
            a_tag <= 0; b_tag <= 0; request_tag <= 0;
            a_data <= 8'h40; b_data <= 8'h40;
        end else begin
            if (pending && rom_ok) begin
                pending <= 0;
                if (!target) begin
                    a_data <= rom_data; a_tag <= request_tag; a_valid <= 1;
                end else begin
                    b_data <= rom_data; b_tag <= request_tag; b_valid <= 1;
                end
            end else if (!pending && !pause) begin
                if (!a_ready) begin
                    request_tag <= a_key; target <= 0; pending <= 1;
                end else if (!b_ready) begin
                    request_tag <= b_key; target <= 1; pending <= 1;
                end
            end
        end
    end
    end endgenerate
endmodule
