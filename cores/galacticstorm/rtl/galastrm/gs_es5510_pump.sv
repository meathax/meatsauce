// SPDX-License-Identifier: BSD-3-Clause
// Native esqpump run_once scheduling and serial routing. Input lanes use MAME
// stream order AUX L/R, FX1 L/R, FX2 L/R, DRY L/R after upstream gain/scaling.
// The engine register bank instead orders serial words R/L within each pair.
module gs_es5510_pump(
    input wire clk,cold_reset,reset,pause,esp_halted,
    input wire host_req,host_write,input wire [7:0] host_addr,host_wdata,
    output wire host_ack,output wire [7:0] host_rdata,
    input wire sample_req,input wire [127:0] sample_input,
    output reg sample_ack,output reg output_valid,
    output reg signed [15:0] processed_l,processed_r,aux_l,aux_r,
    output wire dram_req,dram_write,output wire [19:0] dram_addr,
    output wire [15:0] dram_wdata,input wire dram_ack,input wire [15:0] dram_rdata,
    output wire clear_req,input wire clear_ack,
    output wire fault,output wire busy,output reg [15:0] sample_cycles,
    output reg [15:0] max_sample_cycles,
    input wire [7:0] inspect_reg,output wire [31:0] inspect_data
);
    localparam [2:0] IDLE=0,LOAD=1,START=2,WAKE=3,RUN=4,WAIT=5,OUTPUT=6;
    reg [2:0] state=IDLE;
    reg seen=0,skip_sample=0;
    reg [127:0] inputs;
    wire ready,serial_ready,done,halted;
    wire [127:0] serial_output;
    wire [127:0] serial_input={serial_output[127:96],
        inputs[111:96],inputs[127:112],inputs[79:64],inputs[95:80],
        inputs[47:32],inputs[63:48]};
    wire continue_step=state==WAIT && done && !halted && ready;
    wire step=ready && (state==START || state==RUN || continue_step);
    wire halt_asserted=state!=START && state!=WAKE;
    assign busy=state!=IDLE;
    gs_es5510 device(
        .clk(clk),.cold_reset(cold_reset),.reset(reset),
        .host_req(host_req),.host_write(host_write),.host_addr(host_addr),.host_wdata(host_wdata),
        .host_ack(host_ack),.host_rdata(host_rdata),
        .step(step),.halt_asserted(halt_asserted),.ready(ready),.serial_ready(serial_ready),.done(done),.halted(halted),.fault(fault),
        .serial_we(state==LOAD && serial_ready),.serial_input(serial_input),.serial_output(serial_output),
        .dram_req(dram_req),.dram_write(dram_write),.dram_addr(dram_addr),.dram_wdata(dram_wdata),
        .dram_ack(dram_ack),.dram_rdata(dram_rdata),.clear_req(clear_req),.clear_ack(clear_ack),
        .inspect_reg(inspect_reg),.inspect_data(inspect_data),
        .pc(),.debug_ccr(),.debug_cmr(),.debug_accumulator(),.debug_dol(),.debug_dol_count(),
        .debug_dil(),.debug_dbase(),.debug_dlength(),.debug_memshift());
    always @(posedge clk)begin
        sample_ack<=0;output_valid<=0;
        if(!sample_req)seen<=0;
        if(state!=IDLE && sample_cycles!=16'hffff)sample_cycles<=sample_cycles+1'b1;
        case(state)
            IDLE:if(sample_req && !seen && !pause && (esp_halted ? serial_ready:ready))begin
                inputs<=sample_input;skip_sample<=esp_halted;seen<=1;sample_ack<=1;
                sample_cycles<=0;state<=LOAD;
            end
            LOAD:if(skip_sample ? serial_ready:ready)state<=skip_sample ? OUTPUT:START;
            START:if(ready)state<=WAKE;
            WAKE:if(done)state<=RUN;
            RUN:if(ready)state<=WAIT;
            WAIT:if(done)state<=halted ? OUTPUT:(continue_step ? WAIT:RUN);
            OUTPUT:begin
                processed_l<=serial_output[127:112];processed_r<=serial_output[111:96];
                aux_l<=inputs[15:0];aux_r<=inputs[31:16];output_valid<=1;
                if(sample_cycles>max_sample_cycles)max_sample_cycles<=sample_cycles;
                state<=IDLE;
            end
            default:state<=IDLE;
        endcase
        if(reset || cold_reset)begin
            state<=IDLE;seen<=0;sample_ack<=0;output_valid<=0;
            sample_cycles<=0;max_sample_cycles<=0;inputs<=0;skip_sample<=0;
            processed_l<=0;processed_r<=0;aux_l<=0;aux_r<=0;
        end
    end
endmodule
