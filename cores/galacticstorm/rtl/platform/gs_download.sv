// SPDX-License-Identifier: BSD-3-Clause
// Wide HPS ROM/default-EEPROM download endpoint. The wrapper supplies the
// physical memory port and a held CPU-domain EEPROM-write handshake.
module gs_download #(parameter ROM_BYTES=25'h1000000)(
    input wire clk,cold_reset,
    input wire ioctl_download,ioctl_wr,
    input wire [15:0] ioctl_index,
    input wire [26:0] ioctl_addr,
    input wire [15:0] ioctl_dout,
    output wire ioctl_wait,
    output wire mem_req,mem_write,
    output wire [24:0] mem_addr,
    output wire [15:0] mem_wdata,
    output wire [1:0] mem_bytes,
    input wire mem_ack,
    output wire nv_req,
    output wire [5:0] nv_addr,
    output wire [15:0] nv_data,
    input wire nv_ack,
    output reg rom_loaded,eeprom_loaded,
    output wire ready,fault
);
    localparam IDLE=0,SEND=1,RETIRE=2;
    reg [1:0] state;
    reg previous_download;
    reg [15:0] active_index;
    reg target_eeprom;
    reg [24:0] saved_address,rom_count;
    reg [7:0] eeprom_count;
    reg [15:0] saved_data;
    reg rom_ended,eeprom_ended,bad_rom,bad_eeprom;
    wire new_file=ioctl_download && (!previous_download || ioctl_index!=active_index);
    wire new_rom=new_file && ioctl_index==0;
    wire eeprom_index=ioctl_index==1 || ioctl_index==254;
    wire new_eeprom=new_file && eeprom_index;
    wire supported=ioctl_index==0 || eeprom_index;
    wire [24:0] expected_address=ioctl_index==0 ? (new_rom ? 25'b0 : rom_count) :
        (new_eeprom ? 25'b0 : {17'b0,eeprom_count});
    wire invalid_word=|ioctl_addr[26:25] || ioctl_addr[0] || ioctl_addr!={2'b0,expected_address} ||
        (ioctl_index==0 ? ioctl_addr>=ROM_BYTES : ioctl_addr>=128);
    wire session_bad=ioctl_index==0 ? (!new_rom && bad_rom) : (!new_eeprom && bad_eeprom);
    // Include the current registered HPS strobe as lookahead. The endpoint
    // consumes that strobe next edge; HPS must not emit another word meanwhile.
    assign ioctl_wait=state!=IDLE || (ioctl_download && ioctl_wr && supported);
    assign mem_req=state==SEND && !target_eeprom;
    assign mem_write=1;
    assign mem_addr=saved_address;
    assign mem_wdata=saved_data;
    assign mem_bytes=2'b11;
    assign nv_req=state==SEND && target_eeprom;
    assign nv_addr=saved_address[6:1];
    assign nv_data=saved_data;
    assign ready=rom_loaded && eeprom_loaded && !fault;
    assign fault=bad_rom || bad_eeprom;
    always @(posedge clk) begin
        previous_download<=ioctl_download;
        case(state)
        SEND: if(target_eeprom ? nv_ack : mem_ack)state<=RETIRE;
        // Both backends require a low request before the next transaction.
        RETIRE: state<=IDLE;
        endcase
        if(previous_download && (!ioctl_download || ioctl_index!=active_index))begin
            if(active_index==0)rom_ended<=1;
            if(active_index==1 || active_index==254)eeprom_ended<=1;
        end
        // EOF alone is insufficient: the last accepted write must retire.
        if(rom_ended && !(state!=IDLE && !target_eeprom))begin
            rom_loaded<=rom_count==ROM_BYTES && !bad_rom;
            if(rom_count!=ROM_BYTES)bad_rom<=1;
        end
        if(eeprom_ended && !(state!=IDLE && target_eeprom))begin
            eeprom_loaded<=eeprom_count==128 && !bad_eeprom;
            if(eeprom_count!=128)bad_eeprom<=1;
        end
        if(new_file)active_index<=ioctl_index;
        if(new_rom)begin
            rom_count<=0;rom_ended<=0;rom_loaded<=0;bad_rom<=0;
            // Every MRA ROM upload is followed by its default EEPROM stream.
            eeprom_count<=0;eeprom_ended<=0;eeprom_loaded<=0;bad_eeprom<=0;
        end
        if(new_eeprom)begin eeprom_count<=0;eeprom_ended<=0;eeprom_loaded<=0;bad_eeprom<=0;end
        if(ioctl_download && ioctl_wr && supported)begin
            if(state!=IDLE || invalid_word)begin
                if(ioctl_index==0)bad_rom<=1;else bad_eeprom<=1;
            end else if(!session_bad)begin
                saved_address<=ioctl_addr[24:0];saved_data<=ioctl_dout;
                target_eeprom<=eeprom_index;state<=SEND;
                if(ioctl_index==0)rom_count<=expected_address+25'd2;
                else eeprom_count<=expected_address[7:0]+8'd2;
            end
        end
        if(cold_reset)begin
            state<=IDLE;previous_download<=0;active_index<=0;target_eeprom<=0;
            saved_address<=0;saved_data<=0;rom_count<=0;eeprom_count<=0;
            rom_ended<=0;eeprom_ended<=0;bad_rom<=0;bad_eeprom<=0;
            rom_loaded<=0;eeprom_loaded<=0;
        end
    end
endmodule
