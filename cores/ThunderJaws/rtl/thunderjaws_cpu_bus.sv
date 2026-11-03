// SPDX-License-Identifier: GPL-3.0-or-later
// Per-CPU frontend: decode the held descriptor, never the next live CPU tuple.
module thunderjaws_cpu_bus #(parameter EXTRA_CPU=0) (
    input wire clk_sys, init_reset, game_reset,
    input wire as_active,rw,uds_n,lds_n,
    input wire [2:0] fc, input wire [23:1] address,
    input wire [15:0] write_data,
    output wire dtack,vpa_n, output wire [15:0] read_data,
    output wire request_valid, input wire request_ready,
    output wire [23:1] request_address,
    output wire request_read, output wire [1:0] request_lanes,
    output wire [15:0] request_data, output wire [14:0] request_select,
    input wire response_valid, input wire [15:0] response_data
);
    thunderjaws_bus_bridge bridge (
        .clk_sys(clk_sys),.init_reset(init_reset),.game_reset(game_reset),
        .as_active(as_active),.rw(rw),.uds_n(uds_n),.lds_n(lds_n),.fc(fc),
        .address(address),.write_data(write_data),.dtack(dtack),.vpa_n(vpa_n),.read_data(read_data),
        .request_valid(request_valid),.request_ready(request_ready),.request_address(request_address),
        .request_read(request_read),.request_lanes(request_lanes),.request_data(request_data),
        .response_valid(response_valid),.response_data(response_data)
    );
    // IACK is consumed by the bridge's VPA path, so every posted request is a
    // normal mapped cycle. A zero select is an unmapped access; the backend
    // must still complete it with board-appropriate open-bus/no-write behavior.
    thunderjaws_address_decode #(.EXTRA_CPU(EXTRA_CPU)) decoder (
        .as_active(request_valid),.rw(request_read),
        .uds_n(!request_lanes[1]),.lds_n(!request_lanes[0]),.fc(3'b001),
        .address(request_address),.select(request_select)
    );
endmodule
