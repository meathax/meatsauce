// Coherent sample boundary between OTIS, ESP and final volume stage.
// Serial routing follows the existing F3 software reference pending PCB proof.
module rf_es5510_audio(
    input wire clk,reset,halt,sample_valid,
    input wire window_neg,              // rf_esp_mem window profile (per game)
    input wire [7:0][19:0] sample_data,
    input wire host_we,input wire [7:0] host_addr,host_wdata,
    output wire [7:0] host_rdata,
    output reg mix_valid,
    output reg signed [22:0] mix_l,mix_r,
    output wire ram_req,ram_write,
    output wire [15:0] ram_addr,ram_data,
    input wire ram_ack,input wire [15:0] ram_q,
    output wire fault,
    output wire host_wait               // hold the sound CPU's next ESP access
);
    wire [127:0] serial_out;
    wire [127:0] serial_in={32'd0,sample_data[6][19:4],sample_data[7][19:4],
        sample_data[4][19:4],sample_data[5][19:4],sample_data[2][19:4],sample_data[3][19:4]};
    wire [23:0] raw_addr;
    wire raw_req,raw_write,io,done,busy,core_fault;
    wire [15:0] raw_wdata,mem_q,dbase_word;
    wire [16:0] ring_words;
    wire mem_ack,ram_exec;
    wire [7:0] ram_pc,dil_pc;
    wire dil_use;
    reg io_fault;
    reg signed [19:0] aux_l,aux_r;
    // delay RAM: an 8K on-chip window, DDR only for the far taps (rf_esp_mem)
    rf_esp_mem mem(.clk(clk),.reset(reset),.window_neg(window_neg),
        .dbase(dbase_word),.ring(ring_words),.exec(ram_exec),.pc(ram_pc),.dil_use(dil_use),.dil_pc(dil_pc),
        .c_req(raw_req && !io),.c_write(raw_write),.c_addr(raw_addr[23:8]),.c_wdata(raw_wdata),
        .c_ack(mem_ack),.c_rdata(mem_q),
        .f_req(ram_req),.f_write(ram_write),.f_addr(ram_addr),.f_data(ram_data),
        .f_ack(ram_ack),.f_q(ram_q));
    assign fault=core_fault|io_fault;
    rf_es5510_core dsp(.clk(clk),.reset(reset),.host_we(host_we),.host_addr(host_addr),
        .host_wdata(host_wdata),.host_rdata(host_rdata),.sample_start(sample_valid),.halt(halt),
        .serial_in(serial_in),.serial_out(serial_out),.busy(busy),.done(done),.fault(core_fault),.pc(),
        .ram_req(raw_req),.ram_write(raw_write),.ram_io(io),.ram_addr(raw_addr),.ram_wdata(raw_wdata),
        .ram_ack(io?raw_req:mem_ack),.ram_rdata(io?16'd0:mem_q),
        .dbase_word(dbase_word),.ring_words(ring_words),.ram_exec(ram_exec),.ram_pc(ram_pc),
        .host_wait(host_wait),.dil_use(dil_use),.dil_pc(dil_pc));
    always @(posedge clk)begin
        mix_valid<=0;
        if(reset)begin aux_l<=0;aux_r<=0;mix_l<=0;mix_r<=0;io_fault<=0;end
        else begin
            if(raw_req && io)io_fault<=1;
            if(sample_valid && !busy)begin
                aux_l<=sample_data[0];aux_r<=sample_data[1];
            end
            if(done)begin
                mix_l<=$signed(aux_l)+23'($signed({serial_out[127:112],4'd0}));
                mix_r<=$signed(aux_r)+23'($signed({serial_out[111:96],4'd0}));mix_valid<=1;
            end else if(sample_valid && halt && !busy)begin
                mix_l<=23'($signed(sample_data[0]))+23'($signed({serial_out[127:112],4'd0}));
                mix_r<=23'($signed(sample_data[1]))+23'($signed({serial_out[111:96],4'd0}));mix_valid<=1;
            end
        end
    end
endmodule
