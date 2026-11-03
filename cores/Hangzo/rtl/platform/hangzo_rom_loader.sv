// SPDX-License-Identifier: GPL-3.0-or-later
// One clk domain. Strict byte-stream -> acknowledged whole-word write bridge.
// reset is the memory/system reset, NEVER the download-held game reset.
module hangzo_rom_loader #(
    parameter [24:0] ROM_BYTES = 25'h0c00000
)(
    input wire clk, reset, memory_ready,
    input wire ioctl_download, ioctl_wr,
    input wire [15:0] ioctl_index,
    input wire [26:0] ioctl_address,
    input wire [7:0] ioctl_data,
    output wire ioctl_wait,
    output reg memory_request,
    output reg [23:1] memory_word_address,
    output reg [15:0] memory_write_data,
    input wire memory_ack,
    output reg rom_valid, fault,
    output wire busy, accepted_byte,
    output reg [24:0] bytes_received,
    output reg [23:0] words_written
);
    localparam [1:0] IDLE=2'd0, RECEIVE=2'd1, DRAIN=2'd2;
    reg [1:0] state;
    reg have_even;
    reg [7:0] even_data;
    wire rom_active = ioctl_download && ioctl_index==16'd0;
    assign busy = state!=IDLE || rom_active;
    // A held old ack cannot acknowledge a later word. Wait for its release.
    assign ioctl_wait = rom_active &&
        (state!=RECEIVE || !memory_ready || memory_request || memory_ack || fault);
    assign accepted_byte = rom_active && ioctl_wr && !ioctl_wait;

    always @(posedge clk) begin
        if(reset) begin
            state<=IDLE;have_even<=0;even_data<=0;
            memory_request<=0;memory_word_address<=0;memory_write_data<=0;
            rom_valid<=0;fault<=0;bytes_received<=0;words_written<=0;
        end else begin
            if(memory_request && memory_ack) begin
                memory_request<=0;
                words_written<=words_written+24'd1;
            end
            case(state)
                IDLE: if(rom_active) begin
                    state<=RECEIVE;have_even<=0;bytes_received<=0;
                    words_written<=0;rom_valid<=0;fault<=0;
                end
                RECEIVE: begin
                    if(!rom_active) begin
                        state<=DRAIN;
                        if(ioctl_download)fault<=1; // index switched mid-download
                    end else if(accepted_byte) begin
                        if(ioctl_address!={2'b00,bytes_received} ||
                           bytes_received>=ROM_BYTES) begin
                            fault<=1;
                        end else begin
                            bytes_received<=bytes_received+25'd1;
                            if(!ioctl_address[0]) begin
                                even_data<=ioctl_data;have_even<=1;
                            end else if(have_even) begin
                                // Address+0 occupies low8; CPU endian swap is
                                // the later reader's responsibility.
                                memory_write_data<={ioctl_data,even_data};
                                memory_word_address<=ioctl_address[23:1];
                                memory_request<=1;have_even<=0;
                            end else fault<=1;
                        end
                    end
                end
                DRAIN: begin
                    if(rom_active)fault<=1; // cannot overlap a new session
                    if(!memory_request && !rom_active) begin
                        state<=IDLE;
                        if(!fault && !have_even && bytes_received==ROM_BYTES &&
                           words_written==ROM_BYTES[24:1])rom_valid<=1;
                        else begin fault<=1;rom_valid<=0;end
                    end
                end
                default: begin state<=IDLE;fault<=1;rom_valid<=0;end
            endcase
        end
    end
`ifdef SIMULATION
    initial begin
        if(ROM_BYTES==0 || ROM_BYTES[0] || ROM_BYTES>25'h1000000)
            $fatal(1,"ROM_BYTES must be an even nonzero byte length <=16MiB");
    end
`endif
endmodule
