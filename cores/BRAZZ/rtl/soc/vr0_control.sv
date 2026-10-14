// SPDX-License-Identifier: GPL-3.0-or-later
// VRender0 system identification, interrupt controller and four real timers.
// Platform-configuration writes are retained separately: MiSTer supplies the
// fixed board clocks and memory wiring. Unknown active devices report an error.
module vr0_control (
    input logic clk, reset,
    input logic req_valid,
    output logic req_ready,
    input logic [22:0] req_address,
    input logic [31:0] req_data,
    input logic [3:0] req_strobe,
    input logic req_write,
    output logic rsp_valid,
    output logic [31:0] rsp_data,
    output logic rsp_error,
    input logic [31:0] interrupt_events,
    output logic irq,
    output logic [7:0] irq_vector,
    output logic [31:0] interrupt_enable, interrupt_status,
    output logic [3:0] timer_active,
    output logic [3:0][31:0] timer_control,
    output logic [3:0][15:0] timer_count,
    output logic [31:0] pll_control, pll_program
);
    logic [2:0] vector_high, next_vector_high;
    logic [31:0] byte_mask, next_enable, next_status, events;
    logic [3:0][25:0] timer_remaining;
    logic [3:0][31:0] next_timer_control;
    logic [3:0][15:0] next_timer_count;
    logic [3:0][25:0] next_timer_remaining;
    logic [3:0][31:0] timer_merged;
    logic [3:0] next_timer_active;
    logic [31:0] platform_registers [0:12];
    logic [31:0] read_data, merged;
    logic address_known;
    integer platform_index, timer_index;
    logic timer_register;
    // UART0/1 at 0x01801000/0x01801020 (MAME vr0uart; urachamu uses UART0). TX done: interrupts 15/18.
    wire uart_register = req_address[22:6] == 17'h00040;
    logic [1:0][31:0] uart_read;
    logic [1:0] uart_tx_done;
    vr0_uart uart0 (.clk, .reset, .sel(req_valid && uart_register && !req_address[5]),
        .write(req_write), .offset(req_address[4:0]), .data(req_data), .strobe(req_strobe),
        .read_data(uart_read[0]), .tx_done(uart_tx_done[0]));
    vr0_uart uart1 (.clk, .reset, .sel(req_valid && uart_register && req_address[5]),
        .write(req_write), .offset(req_address[4:0]), .data(req_data), .strobe(req_strobe),
        .read_data(uart_read[1]), .tx_done(uart_tx_done[1]));
    function automatic logic [25:0] period(input logic [31:0] control, input logic [15:0] count);
        logic [8:0] prescale;
        logic [16:0] reload;
        begin
            prescale = {1'b0,control[15:8]} + 9'd1;
            reload = {1'b0,count} + 17'd1;
            period = 26'(prescale * reload) << 1;
        end
    endfunction
    always_comb begin
        req_ready = 1;
        byte_mask = {{8{req_strobe[3]}},{8{req_strobe[2]}},{8{req_strobe[1]}},{8{req_strobe[0]}}};
        next_enable = interrupt_enable;
        next_status = interrupt_status;
        next_vector_high = vector_high;
        next_timer_control = timer_control;
        next_timer_count = timer_count;
        next_timer_remaining = timer_remaining;
        next_timer_active = timer_active;
        events = interrupt_events;
        if (uart_tx_done[0]) events[15] = 1;
        if (uart_tx_done[1]) events[18] = 1;
        timer_register = req_address[22:5] == 18'h000a0 && req_address[1:0] == 0;
        for (int i=0;i<4;i=i+1) begin
            timer_merged[i] = (timer_control[i] & ~byte_mask) | (req_data & byte_mask);
            if (timer_active[i]) begin
                if (timer_remaining[i] == 0) begin
                    case (i)
                        0: events[0] = 1;
                        1: events[1] = 1;
                        2: events[9] = 1;
                        3: events[10] = 1;
                    endcase
                    if (timer_control[i][1]) next_timer_remaining[i] = period(timer_control[i],timer_count[i]) - 1'b1;
                    else begin next_timer_active[i] = 0; next_timer_control[i][0] = 0; end
                end else next_timer_remaining[i] = timer_remaining[i] - 1'b1;
            end
            // Constant-index arithmetic keeps address selection after each
            // timer's own reload calculation rather than before its multiplier.
            // Preserve write priority over expiry and the existing timer edges.
            if (timer_register && req_address[4:3] == 2'(i) && req_valid && req_write) begin
                if (req_address[2]) next_timer_count[i] =
                    (timer_count[i] & ~byte_mask[15:0]) | (req_data[15:0] & byte_mask[15:0]);
                else begin
                    next_timer_control[i] = timer_merged[i];
                    if (timer_merged[i][0] != timer_control[i][0]) begin
                        next_timer_active[i] = timer_merged[i][0];
                        if (timer_merged[i][0]) next_timer_remaining[i] = period(timer_merged[i],timer_count[i]) - 1'b1;
                    end
                end
            end
        end
        platform_index = -1;
        case (req_address)
            23'h000008: platform_index = 0;
            23'h000018: platform_index = 1;
            23'h00001c: platform_index = 2;
            23'h000400: platform_index = 3;
            23'h000408: platform_index = 4;
            23'h002000: platform_index = 5;
            23'h002408: platform_index = 6;
            23'h00240c: platform_index = 7;
            23'h002410: platform_index = 8;
            23'h002414: platform_index = 9;
            23'h004000: platform_index = 10;
            23'h004004: platform_index = 11;
            default: begin end
        endcase
        timer_index = int'(req_address[4:3]);
        // MAME's unmapped/nop SoC reads return zero (verified against the pinned
        // oracle in scripts/mame/control_probe.lua), not all ones.
        read_data = 32'h00000000;
        address_known = 0;
        merged = 0;
        if (platform_index >= 0) begin
            // MAME leaves these platform controls unmapped. Capture written
            // values for wiring/clock diagnostics; unmapped reads return zero.
            address_known = 1;
        end else if (uart_register) begin
            address_known = 1;
            read_data = uart_read[req_address[5]];
        end else if (timer_register) begin
            address_known = 1;
            if (req_address[2]) read_data = {16'h0000,timer_count[timer_index]};
            else read_data = timer_control[timer_index];
        end else case (req_address)
            23'h000000: begin address_known = !req_write; read_data = 32'h00000a00; end
            23'h000004: begin address_known = !req_write; read_data = 32'h00000041; end
            23'h000010,23'h000014: address_known = 1; // MAME watchdog noprw.
            // Pinned MAME has no handler at the first interrupt-controller
            // word. Native boot taps observe zero reads; writes have no
            // effect. This is a specific compatibility hole, not IRQ state.
            23'h000c00: begin address_known = 1; read_data = 0; end
            23'h000c04: begin
                address_known = 1; read_data = {21'b0,vector_high,8'b0};
                if (req_valid && req_write) begin
                    if (req_strobe[0]) next_status = next_status & ~(32'b1 << req_data[4:0]);
                    if (req_strobe[1]) next_vector_high = req_data[10:8];
                end
            end
            23'h000c08: begin
                address_known = 1; read_data = interrupt_enable;
                if (req_valid && req_write) begin
                    next_enable = (interrupt_enable & ~byte_mask) | (req_data & byte_mask);
                    next_status = next_status & next_enable;
                end
            end
            23'h000c0c: begin
                address_known = 1; read_data = interrupt_status;
                // MAME models INTST writes as having no effect. Software
                // acknowledges through INTVEC or disables the source in INTEN.
            end
            default: begin end
        endcase
        // A new event survives a simultaneous software acknowledge. Disabled
        // sources do not latch events, matching int_req in the reference.
        next_status = next_status | (events & next_enable);
        irq = interrupt_status != 0;
        irq_vector = 0;
        for (int i=31;i>=0;i=i-1) if (interrupt_status[i]) irq_vector = {vector_high,5'(i)};
        pll_control = platform_registers[10];
        pll_program = platform_registers[11];
    end
    always_ff @(posedge clk) begin
        if (reset) begin
            interrupt_enable <= 0; interrupt_status <= 0; vector_high <= 0;
            timer_active <= 0; timer_count <= 0; timer_remaining <= 0;
            for (int i=0;i<4;i=i+1) timer_control[i] <= 32'h0000ff00;
            for (int i=0;i<13;i=i+1) platform_registers[i] <= 0;
            rsp_valid <= 0; rsp_data <= 0; rsp_error <= 0;
        end else begin
            interrupt_enable <= next_enable; interrupt_status <= next_status; vector_high <= next_vector_high;
            timer_control <= next_timer_control; timer_count <= next_timer_count;
            timer_remaining <= next_timer_remaining; timer_active <= next_timer_active;
            rsp_valid <= req_valid;
            if (req_valid) begin
                rsp_data <= read_data; rsp_error <= !address_known;
                if (req_write && platform_index >= 0)
                    platform_registers[platform_index] <= (platform_registers[platform_index] & ~byte_mask) | (req_data & byte_mask);
            end
        end
    end
endmodule
