/*  This file is part of JT6295.
    JT6295 program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT6295 program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT6295.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 6-1-2020 */

module jt6295_ctrl(
    input                  rst,
    input                  clk,
    input                  cen4,
    input                  cen1,
    // CPU
    input                  wrn,
    input      [ 7:0]      din,
    // Channel address
    output     [17:0]      start_addr,
    output     [17:0]      stop_addr,
    // Attenuation
    output     [ 3:0]      att,
    // ROM interface
    output     [ 9:0]      rom_addr,
    input      [ 7:0]      rom_data,
    input                  rom_ok,
    // flow control
    output reg [ 3:0]      start,
    output reg [ 3:0]      stop,
    input      [ 3:0]      busy,
    input      [ 3:0]      ack,
    input                  zero
);

reg  last_wrn;
wire negedge_wrn  = !wrn && last_wrn;

// new request
reg [6:0] phrase, cmd_phrase, req_phrase;
reg       push, pull;
reg [3:0] ch, new_att, req_att;
reg       cmd;

always @(posedge clk) begin
    last_wrn <= rst ? 1'b1 : wrn;
end

`ifdef JT6295_DUMP
integer fdump;
integer ticks=0;
initial begin
    fdump=$fopen("jt6295.log");
end
always @(posedge zero) ticks<=ticks+1;
always @(posedge clk ) begin
    if( negedge_wrn ) begin
        if( !cmd && !din[7] ) begin
            $fwrite(fdump,"@%0d - Mute %1X\n", ticks, din[6:3]);
        end
        if( cmd ) begin
            $fwrite(fdump,"@%0d - Start %1X, phrase %X, Att %X\n",
                ticks, din[7:4], phrase, din[3:0] );
        end
    end
end
`endif


// Bus interface
//
// Commands take effect in bus order. A voice counts as playing once a start is
// latched or the serializer reports busy, unless a later stop is pending. This
// mirrors the MSM6295 command semantics: starts on playing voices are ignored,
// stops end a playing voice, and a start after a stop re-arms the voice.
wire [3:0] playing   = (busy | start) & ~stop;
wire [3:0] accept    = din[7:4] & ~playing;
wire       cmd_stop  = negedge_wrn && !cmd && !din[7];
wire [3:0] stop_keep = cen4 ? (stop & (busy | start)) : stop;

wire       header_ok;      // a valid phrase header has just been read for req_ch
reg  [3:0] req_ch;

// A stop is consumed when the serializer applies it; a valid start that follows it
// re-arms the voice and supersedes the stop. An invalid phrase leaves the stop pending.
always @(posedge clk) begin
    if( rst ) begin
        stop <= 4'd0;
    end else begin
        stop <= (cmd_stop ? (stop_keep | (din[6:3] & playing)) : stop_keep) & ~(header_ok ? req_ch : 4'd0);
    end
end

always @(posedge clk) begin
    if( rst ) begin
        cmd      <= 1'b0;
        ch       <= 4'd0;
        pull     <= 1'b0;
        phrase   <= 7'd0;
        cmd_phrase <= 7'd0;
        new_att  <= 0;
    end else begin
        if( push ) pull <= 1'b0;
        if( negedge_wrn  ) begin // new write
            if( cmd ) begin // 2nd byte
                cmd     <= 1'b0;
                // A fully occupied mask is a no-op: it must not run the header
                // sequence or touch the latched request of an earlier command.
                if( |accept ) begin
                    ch         <= accept;
                    new_att    <= din[3:0];
                    cmd_phrase <= phrase;
                    pull       <= 1'b1;
                end
            end
            else if( din[7] ) begin // channel start
                phrase <= din[6:0];
                cmd    <= 1'b1; // wait for second byte
            end
        end
    end
end

reg [17:0] new_start;
reg [17:8] new_stop;
reg [ 2:0] st, addr_lsb;
reg        wrom;

assign rom_addr = { req_phrase, addr_lsb };

// Request phrase address
//
// Each voice owns its header registers. A start request stays latched until the
// serializer acknowledges it in that voice's slot, so a later command can never
// overwrite or cancel an earlier voice's pending start. The slot mirror below
// advances exactly like jt6295_serial.ch (same reset value, same cen4).
reg [17:0] sa0, sa1, sa2, sa3, ea0, ea1, ea2, ea3;
reg [ 3:0] at0, at1, at2, at3;
reg [ 3:0] slot;
wire       header_done = st==3'd6 && !wrom && rom_ok;
wire [17:0] new_stop_full = {new_stop[17:8], rom_data};
wire       header_valid = new_start < new_stop_full;
assign     header_ok = header_done && header_valid;

always @(posedge clk, posedge rst) begin
    if( rst )
        slot <= 4'b1;
    else if( cen4 )
        slot <= { slot[2:0], slot[3] };
end

assign start_addr = ({18{slot[0]}} & sa0) | ({18{slot[1]}} & sa1) |
                    ({18{slot[2]}} & sa2) | ({18{slot[3]}} & sa3);
assign stop_addr  = ({18{slot[0]}} & ea0) | ({18{slot[1]}} & ea1) |
                    ({18{slot[2]}} & ea2) | ({18{slot[3]}} & ea3);
assign att        = ({ 4{slot[0]}} & at0) | ({ 4{slot[1]}} & at1) |
                    ({ 4{slot[2]}} & at2) | ({ 4{slot[3]}} & at3);

always @(posedge clk) begin
    if( rst ) begin
        sa0 <= 0; sa1 <= 0; sa2 <= 0; sa3 <= 0;
        ea0 <= 0; ea1 <= 0; ea2 <= 0; ea3 <= 0;
        at0 <= 0; at1 <= 0; at2 <= 0; at3 <= 0;
    end else if( header_ok ) begin
        // MAME/6295 phrase convention requires start < stop;
        // the stop byte is inclusive once a valid voice starts.
        if( req_ch[0] ) begin sa0 <= new_start; ea0 <= new_stop_full; at0 <= req_att; end
        if( req_ch[1] ) begin sa1 <= new_start; ea1 <= new_stop_full; at1 <= req_att; end
        if( req_ch[2] ) begin sa2 <= new_start; ea2 <= new_stop_full; at2 <= req_att; end
        if( req_ch[3] ) begin sa3 <= new_start; ea3 <= new_stop_full; at3 <= req_att; end
    end
end

// Pending starts are set once per header and cleared only by the serializer's
// acknowledge, regardless of what the header sequencer is doing.
always @(posedge clk) begin
    if( rst )
        start <= 4'd0;
    else
        start <= (start & ~ack) | (header_ok ? req_ch : 4'd0);
end

always @(posedge clk) begin
    if( rst ) begin
        st         <= 7;
        addr_lsb   <= 0;
        push       <= 0;
        req_phrase <= 7'd0;
        req_ch     <= 4'd0;
        req_att    <= 4'd0;
    end else begin
        if( st!=7 ) begin
            wrom <= 0;
            if( !wrom && rom_ok ) begin
                st       <= st+3'd1;
                addr_lsb <= st;
                wrom     <= 1;
            end
        end
        case( st )
            7: begin
                addr_lsb <= 0;
                if(pull) begin
                    // Snapshot the request so later bus writes cannot disturb the header read.
                    req_phrase <= cmd_phrase;
                    req_ch     <= ch;
                    req_att    <= new_att;
                    st       <= 0;
                    wrom     <= 1;
                    push     <= 1;
                end
            end
            0:;
            1: new_start[17:16] <= rom_data[1:0];
            2: new_start[15: 8] <= rom_data;
            3: new_start[ 7: 0] <= rom_data;
            4: new_stop [17:16] <= rom_data[1:0];
            5: new_stop [15: 8] <= rom_data;
            6: push <= 0;
        endcase
    end
end

endmodule