/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 29-3-2025 */

module jtosman_header(
    input            clk,
                     header, prog_we,
    
    output reg       jm=0,
    output reg       cr=0,
    output reg       md=0,
    output reg       mdp=0,
    output reg       cn=0,
    output reg       hv=0,
    input      [3:0] prog_addr,
    input      [7:0] prog_data
);

always @(posedge clk) begin
    if( header && prog_addr[3:0]==0 && prog_we )
        jm <= prog_data[0];
    if( header && prog_addr[3:0]==0 && prog_we )
        cr <= prog_data[1];
    if( header && prog_addr[3:0]==0 && prog_we )
        md <= prog_data[2];
    if( header && prog_addr[3:0]==0 && prog_we )
        mdp <= prog_data[3];
    if( header && prog_addr[3:0]==0 && prog_we )
        cn <= prog_data[4];
    if( header && prog_addr[3:0]==0 && prog_we )
        hv <= prog_data[5];
end

endmodule
