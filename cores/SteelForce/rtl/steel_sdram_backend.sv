// Registered single-owner adapter around the Cave-derived SDRAM sequencer.
// Read addresses are 8-byte aligned. Writes are aligned 16-bit words with strobes.
// Payload is captured before presentation and cannot be preempted mid-transaction.
module steel_sdram_backend(
    input wire clk,reset,
    input wire request,write,
    input wire [24:0] address,
    input wire [15:0] write_data,
    input wire [1:0] write_strobes,
    output reg accepted,acknowledged,protocol_error,
    output wire ready,busy,
    output reg [63:0] read_data,
    output wire [12:0] sdram_address,
    output wire [1:0] sdram_bank,sdram_dqm,
    output wire sdram_cs_n,sdram_ras_n,sdram_cas_n,sdram_we_n,
    output wire sdram_drive,
    output wire [15:0] sdram_data_out,
    input wire [15:0] sdram_data_in
);
    localparam IDLE=0,PRESENT=1,RUN=2,WAIT_DROP=3;
    reg [1:0] state;
    reg chip_read,chip_write,transaction_write;
    reg [24:0] chip_address;
    reg [15:0] chip_data;
    reg [1:0] chip_strobes;
    reg [2:0] beat;
    wire chip_accept,chip_done,chip_valid,chip_initialized;
    wire [15:0] chip_result;
    wire oe_n;
    assign ready=chip_initialized && state==IDLE;
    assign busy=state!=IDLE;
    assign sdram_drive=!oe_n;
    steel_sdram_chip chip(.clock(clk),.reset(reset),
        .io_mem_rd(chip_read),.io_mem_wr(chip_write),.io_mem_addr(chip_address),
        .io_mem_din(chip_data),.io_mem_strobes(chip_strobes),.io_mem_dout(chip_result),
        .io_mem_wait_n(),.io_mem_accept(chip_accept),.io_init_done(chip_initialized),
        .io_mem_valid(chip_valid),.io_mem_burstDone(chip_done),
        .io_sdram_cs_n(sdram_cs_n),.io_sdram_ras_n(sdram_ras_n),.io_sdram_cas_n(sdram_cas_n),
        .io_sdram_we_n(sdram_we_n),.io_sdram_oe_n(oe_n),.io_sdram_bank(sdram_bank),
        .io_sdram_addr(sdram_address),.io_sdram_dqm(sdram_dqm),
        .io_sdram_din(sdram_data_out),.io_sdram_dout(sdram_data_in));
    always @(posedge clk) begin
        if(reset)begin
            state<=IDLE;chip_read<=0;chip_write<=0;transaction_write<=0;chip_address<=0;
            chip_data<=0;chip_strobes<=0;beat<=0;read_data<=0;
            accepted<=0;acknowledged<=0;protocol_error<=0;
        end else begin
            accepted<=0;acknowledged<=0;
            case(state)
                IDLE:if(request && chip_initialized)begin
                    accepted<=1;beat<=0;transaction_write<=write;
                    if((!write && |address[2:0]) || (write && address[0]) ||
                        (write && write_strobes==0))begin
                        protocol_error<=1;acknowledged<=1;state<=WAIT_DROP;
                    end else begin
                        chip_address<=address;chip_data<=write_data;chip_strobes<=write_strobes;
                        chip_read<=!write;chip_write<=write;state<=PRESENT;
                    end
                end
                PRESENT:if(chip_accept)begin chip_read<=0;chip_write<=0;state<=RUN;end
                RUN:begin
                    if(chip_valid)begin
                        if(!transaction_write && beat<4)begin
                            read_data[beat*16+:16]<=chip_result;beat<=beat+1'b1;
                        end else protocol_error<=1;
                    end
                    if(chip_done)begin
                        // Four beats must have arrived by completion. CL2's
                        // last beat precedes the retained completion edge.
                        if((!transaction_write && (chip_valid ? beat!=3 : beat!=4)) ||
                            (transaction_write && chip_valid))protocol_error<=1;
                        acknowledged<=1;state<=WAIT_DROP;
                    end
                end
                WAIT_DROP:if(!request)state<=IDLE;
            endcase
        end
    end
endmodule
