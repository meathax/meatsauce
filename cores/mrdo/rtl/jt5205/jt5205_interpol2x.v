/*  This file is part of JT5205.
    JT5205 program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 30-12-2019 */

module jt5205_interpol2x(
    input                      rst,
    input                      clk,
    (* direct_enable *) input  cen_mid,
    input      signed [11:0]   din,
    output reg signed [11:0]   dout
);

reg signed [11:0] last;

always @(posedge clk, posedge rst) begin
    if(rst) begin
        last <= 12'd0;
        dout <= 12'd0;
    end else if(cen_mid) begin
        last <= din;
        dout <= (last>>>1)+(din>>>1);
    end
end

endmodule
