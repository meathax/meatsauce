// SPDX-License-Identifier: GPL-3.0-or-later
// A ROM request/address is held through acknowledgement, including pause.
// The backend must qualify acknowledgement for the held address. Reset cancels
// this client epoch; it does not authorize a stale reply for a different address.
module d8_cpu_rom_latch #(parameter integer P_ADDR_BITS=21)(
    input wire clk,rst_n,begin_cycle,need_rom,
    input wire [P_ADDR_BITS-1:0] address,
    input wire ack,input wire [7:0] data,
    output reg request,output reg [P_ADDR_BITS-1:0] request_address,
    output reg [7:0] held_data,output reg have_data,overrun
);
    always @(posedge clk)begin
        if(!rst_n)begin
            request<=0;request_address<=0;held_data<=0;have_data<=0;overrun<=0;
        end else begin
            if(begin_cycle)begin
                if(request)overrun<=1;
                else begin
                    request<=need_rom;request_address<=address;have_data<=0;
                end
            end
            if(request&&ack)begin request<=0;held_data<=data;have_data<=1;end
        end
    end
`ifdef SIMULATION
    always @(posedge clk)if(rst_n&&begin_cycle&&request)
        $fatal(1,"CPU_ROM_REQUEST_REPLACED");
`endif
endmodule
