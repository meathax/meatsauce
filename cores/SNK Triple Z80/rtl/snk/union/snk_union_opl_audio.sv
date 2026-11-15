// Psycho sound bus/latch glue. CPU, ROM and RAM remain in the shared board.
module snk_union_opl_audio (
    input wire [7:0] profile_id,
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
    wire is_late=profile_id==8'd11||profile_id==8'd12||profile_id==8'd13||profile_id==8'd16||profile_id==8'd19||profile_id==8'd14||profile_id==8'd18;
    // TNK3-class (6 aso,7 tnk3,8 athena,9 fitegolf,10 countryc): ym1 present; athena also uses the Y8950 FM block as 2nd YM3526.
    wire is_tnk=profile_id>=8'd6&&profile_id<=8'd10;
    wire valid=is_late||is_tnk||profile_id==8'd15||profile_id==8'd20||profile_id==8'd17;
    wire ym1_present=is_late||is_tnk||profile_id==8'd15;
    wire ym2_present=!is_tnk||profile_id==8'd8;
    wire latch_cs=valid&&cpu_mem&&cpu_addr==16'he000;
    wire ym1_cs=valid&&ym1_present&&cpu_mem&&(cpu_addr==16'he800||cpu_addr==16'hec00);
    wire ym2_cs=valid&&cpu_mem&&(cpu_addr==16'hf000||cpu_addr==16'hf400);
    wire status_cs=valid&&cpu_mem&&cpu_addr==16'hf800;
    wire status_write = status_cs && cpu_wr;
    reg status_write_l, ym1_irq_l, ym2_irq_l;
    reg [7:0] command;
    reg [3:0] status;
    wire [7:0] ym1_dout, ym2_dout;
    wire signed [15:0] ym1_raw;

    assign cpu_data_cs = cpu_rd && (latch_cs || (ym1_cs&&cpu_addr==16'he800) || (ym2_cs&&cpu_addr==16'hf000) || status_cs);
    assign cpu_irq_n = !valid || ~|(status & (ym1_present ? 4'b1011:4'b1010));
    assign cmd_busy = valid&&status[2];
    assign sound_status = status;
    always @* begin
        cpu_dout = 8'hff;
        if (latch_cs) cpu_dout = command;
        else if (ym1_cs&&cpu_addr==16'he800) cpu_dout = ym1_dout;
        else if (ym2_cs&&cpu_addr==16'hf000) cpu_dout = ym2_dout;
        else if (status_cs) cpu_dout = {4'd0, status};
    end
    always @(posedge clk) begin
        if (rst||!valid) begin
            command <= 0; status <= 0; status_write_l <= 0;
            ym1_irq_l <= 1; ym2_irq_l <= 1;
        end else begin
            status_write_l <= status_write;
            ym1_irq_l <= ym3526_irq_n;
            ym2_irq_l <= y8950_irq_n;
            if (valid&&cmd_wr) begin command <= cmd_data; status[3:2] <= 2'b11; end
            if (ym1_present&&!ym3526_irq_n && ym1_irq_l) status[0] <= 1;
            if (!y8950_irq_n && ym2_irq_l) status[1] <= 1;
            if (status_write && !status_write_l) begin
                if (!cpu_din[4]) status[0] <= 0;
                if (!cpu_din[5]) status[1] <= 0;
                if (!cpu_din[6]) begin
                    status[2] <= 0;
                    // ASO/TNK3 busy-clear reads also clear the physical latch.
                    // Their IRQ handler reads it again to distinguish timer IRQs.
                    if (profile_id==8'd6 || profile_id==8'd7) command <= 0;
                end
                if (!cpu_din[7]) status[3] <= 0;
            end
        end
    end
    snk_late_jtopl u_ym3526 (
        .opl2_mode(profile_id==8'd16||profile_id==8'd9||profile_id==8'd10), // chopper, fitegolf/countryc YM3812
        .rst(rst||!ym1_present), .clk(clk), .cen(ce_opl), .din(cpu_din), .addr(cpu_addr[10]),
        .cs_n(~ym1_cs), .wr_n(~cpu_wr), .dout(ym1_dout), .irq_n(ym3526_irq_n),
        .snd(ym1_raw), .sample(ym3526_sample)
    );
    psychos_y8950 u_y8950 (
        .rst(rst||!valid), .clk(clk), .cen(ce_opl), .din(cpu_din), .addr(cpu_addr[10]),
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
    assign ym3526_pcm = ym1_present ? fp_dac(ym1_raw):16'sd0;
endmodule
