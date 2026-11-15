// Psycho sound bus/latch glue. CPU, ROM and RAM remain in the shared board.
module snk_late_audio (
    input wire opl2_mode,
    input wire clk, rst, ce_opl,
    input wire [15:0] cpu_addr,
    input wire [7:0] cpu_din,
    input wire cpu_mem, cpu_rd, cpu_wr,
    output reg [7:0] cpu_dout,
    output wire cpu_data_cs, cpu_irq_n,
    input wire [7:0] cmd_data,
    input wire cmd_wr,
    output wire cmd_busy,
    output wire [3:0] sound_status,
    output wire [20:0] sample_addr,
    output wire sample_req,
    input wire [7:0] sample_data,
    input wire sample_ack,
    output wire signed [15:0] ym3526_pcm, y8950_pcm,
    output wire ym3526_sample, y8950_sample,
    output wire ym3526_irq_n, y8950_irq_n,
    output wire signed [15:0] adpcm_pcm,
    output wire adpcm_valid,
    output wire [2:0] adpcm_status
);
    wire latch_cs = cpu_mem && cpu_addr[15:11] == 5'b11100;
    wire ym1_cs = cpu_mem && cpu_addr[15:11] == 5'b11101;
    wire ym2_cs = cpu_mem && cpu_addr[15:11] == 5'b11110;
    wire status_cs = cpu_mem && cpu_addr[15:11] == 5'b11111;
    wire status_write = status_cs && cpu_wr;
    reg status_write_l, ym1_irq_l, ym2_irq_l;
    reg [7:0] command;
    reg [3:0] status;
    wire [7:0] ym1_dout, ym2_dout;
    wire signed [15:0] ym1_raw;

    assign cpu_data_cs = cpu_rd && (latch_cs || ym1_cs || ym2_cs || status_cs);
    assign cpu_irq_n = ~|(status & 4'b1011);
    assign cmd_busy = status[2];
    assign sound_status = status;
    always @* begin
        cpu_dout = 8'hff;
        if (latch_cs) cpu_dout = command;
        else if (ym1_cs) cpu_dout = ym1_dout;
        else if (ym2_cs) cpu_dout = ym2_dout;
        else if (status_cs) cpu_dout = {4'd0, status};
    end
    always @(posedge clk) begin
        if (rst) begin
            command <= 0; status <= 0; status_write_l <= 0;
            ym1_irq_l <= 1; ym2_irq_l <= 1;
        end else begin
            status_write_l <= status_write;
            ym1_irq_l <= ym3526_irq_n;
            ym2_irq_l <= y8950_irq_n;
            if (cmd_wr) begin command <= cmd_data; status[3:2] <= 2'b11; end
            if (!ym3526_irq_n && ym1_irq_l) status[0] <= 1;
            if (!y8950_irq_n && ym2_irq_l) status[1] <= 1;
            if (status_write && !status_write_l) begin
                if (!cpu_din[4]) status[0] <= 0;
                if (!cpu_din[5]) status[1] <= 0;
                if (!cpu_din[6]) status[2] <= 0;
                if (!cpu_din[7]) status[3] <= 0;
            end
        end
    end
    snk_late_jtopl u_ym3526 (
        .opl2_mode(opl2_mode),
        .rst(rst), .clk(clk), .cen(ce_opl), .din(cpu_din), .addr(cpu_addr[10]),
        .cs_n(~ym1_cs), .wr_n(~cpu_wr), .dout(ym1_dout), .irq_n(ym3526_irq_n),
        .snd(ym1_raw), .sample(ym3526_sample)
    );
    psychos_y8950 u_y8950 (
        .rst(rst), .clk(clk), .cen(ce_opl), .din(cpu_din), .addr(cpu_addr[10]),
        .cs_n(~ym2_cs), .wr_n(~cpu_wr), .dout(ym2_dout), .irq_n(y8950_irq_n),
        .rom_addr(sample_addr), .rom_cs(sample_req), .rom_data(sample_data),
        .rom_ok(sample_ack), .snd(y8950_pcm), .sample(y8950_sample),
        .pcm_raw(adpcm_pcm), .pcm_valid(adpcm_valid), .adpcm_status(adpcm_status)
    );
    function automatic signed [15:0] fp_dac(input signed [15:0] value);
        reg [14:0] magnitude;
        reg [3:0] drop;
        integer bit_index;
        begin
            magnitude = value[14:0] ^ {15{value[15]}};
            drop = 0;
            for (bit_index=9; bit_index<15; bit_index=bit_index+1)
                if (magnitude[bit_index]) drop = bit_index[3:0]-4'd8;
            fp_dac = value & ~((16'd1 << drop)-16'd1);
        end
    endfunction
    assign ym3526_pcm = fp_dac(ym1_raw);
endmodule
