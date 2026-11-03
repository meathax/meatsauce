// SPDX-License-Identifier: GPL-3.0-or-later
// Native chip sample strobes -> coherent four-channel 48k packets.
// MAME0.289 LOFI polynomial; YM2151 pairs are averaged before interpolation.
// One shared coefficient ROM/four multipliers; all transfers use clk edges.
module madmotor_audio_resampler #(
    parameter integer SYS_HZ=48000000
)(
    input tri0 bandit,
    input wire clk,reset,source_reset,output_ce,
    input wire [3:0] source_ce,
    input wire signed [15:0] source_data [4],
    output reg signed [20:0] sample_data [4], // signed17 headroom plus4 fractional bits
    output reg sample_valid
);
    localparam [31:0] OPM_STEP=(64'd4294967296*21477272)/(64'd384*SYS_HZ*2);
    localparam [31:0] OKI1_STEP=(64'd4294967296*1023924)/(64'd132*SYS_HZ);
    localparam [31:0] OKI2_STEP=(64'd4294967296*2047848)/(64'd132*SYS_HZ);
    reg [3:0] source_previous;
    wire [3:0] source_event=source_ce&~source_previous&{4{!source_reset&&!reset}};
    reg signed [16:0] history [4][4]; // Q1, oldest first
    reg signed [15:0] first_sample [4];
    reg [3:0] pair_pending;
    reg [31:0] phase [4];
    wire [3:0] group_event;
    wire signed [16:0] group_value [4];
    always @(posedge clk) begin
        if(reset||source_reset)source_previous<=0;
        else source_previous<=source_ce;
    end
    genvar channel;
    generate for(channel=0;channel<4;channel=channel+1)begin: sources
        wire [31:0] STEP=bandit ? (channel<2 ? 32'((64'd4294967296*3000000)/(64'd144*SYS_HZ)) : 32'((64'd4294967296*1000000)/(64'd132*SYS_HZ))) : (channel<2 ? OPM_STEP : channel==2 ? OKI1_STEP : OKI2_STEP);
        assign group_event[channel]=source_event[channel]&&((channel>=2)||pair_pending[channel]);
        assign group_value[channel]=channel<2 ?
            $signed({source_data[channel][15],source_data[channel]})+$signed({first_sample[channel][15],first_sample[channel]}) :
            $signed({source_data[channel],1'b0});
        always @(posedge clk)begin
            if(reset||source_reset)begin
                phase[channel]<=0;pair_pending[channel]<=0;first_sample[channel]<=0;
                for(integer tap=0;tap<4;tap=tap+1)history[channel][tap]<=0;
            end else begin
                // The stored phase describes the next capture edge. A newly
                // available group is bypassed into a simultaneous snapshot.
                if(phase[channel]>32'hffffffff-STEP)phase[channel]<=32'hffffffff;
                else phase[channel]<=phase[channel]+STEP;
                if(source_event[channel]&&channel<2)begin
                    if(!pair_pending[channel])first_sample[channel]<=source_data[channel];
                    pair_pending[channel]<=!pair_pending[channel];
                end
                if(group_event[channel])begin
                    for(integer tap=0;tap<3;tap=tap+1)history[channel][tap]<=history[channel][tap+1];
                    history[channel][3]<=group_value[channel];phase[channel]<=STEP;
                end
            end
        end
    end endgenerate

    reg [11:0] rom_address;
    wire [71:0] rom_data;
    madmotor_lofi_rom coefficient_rom(.clk(clk),.address(rom_address),.data(rom_data));
    reg signed [16:0] snapshot [4][4],quad [4];
    reg [11:0] snapshot_phase [4];
    reg signed [34:0] products [4];
    reg signed [35:0] pair0,pair1;
    reg signed [36:0] total;
    wire [36:0] magnitude=total[36] ? (~$unsigned(total)+37'd1) : $unsigned(total);
    wire [36:0] rounded=(magnitude+37'd4096)>>13; // Q1 * Q16 -> Q4, retain sub-DAC precision
    reg signed [20:0] result [4];
    reg [1:0] selected;
    reg muted;
    localparam IDLE=0,LOAD=1,ROM_WAIT=2,MULTIPLY=3,SUM=4,ADD=5,ROUND=6,PUBLISH=7;
    reg [2:0] state;
    always @(posedge clk)begin
        if(reset)begin
            state<=IDLE;sample_valid<=0;selected<=0;muted<=0;rom_address<=0;
            for(integer c=0;c<4;c=c+1)sample_data[c]<=0;
        end else begin
            sample_valid<=0;
            if(source_reset)muted<=1;
`ifdef VERILATOR
            if(output_ce&&state!=IDLE)$fatal(1,"resampler packet overrun");
`endif
            case(state)
                IDLE:if(output_ce)begin
                    for(integer c=0;c<4;c=c+1)begin
                        for(integer k=0;k<3;k=k+1)snapshot[c][k]<=group_event[c] ? history[c][k+1] : history[c][k];
                        snapshot[c][3]<=group_event[c] ? group_value[c] : history[c][3];
                        snapshot_phase[c]<=group_event[c] ? 12'd0 : phase[c][31:20];
                    end
                    selected<=0;muted<=source_reset;state<=LOAD;
                end
                LOAD:begin
                    for(integer k=0;k<4;k=k+1)quad[k]<=snapshot[selected][k];
                    rom_address<=snapshot_phase[selected];state<=ROM_WAIT;
                end
                ROM_WAIT:state<=MULTIPLY;
                MULTIPLY:begin
                    for(integer k=0;k<4;k=k+1)products[k]<=$signed(quad[k])*$signed(rom_data[k*18+:18]);
                    state<=SUM;
                end
                SUM:begin
                    pair0<=$signed({products[0][34],products[0]})+$signed({products[1][34],products[1]});
                    pair1<=$signed({products[2][34],products[2]})+$signed({products[3][34],products[3]});
                    state<=ADD;
                end
                ADD:begin total<=$signed({pair0[35],pair0})+$signed({pair1[35],pair1});state<=ROUND;end
                ROUND:begin
`ifdef VERILATOR
                    assert(rounded<=37'd1048575)else $fatal(1,"resampler headroom overflow");
`endif
                    result[selected]<=total[36] ? -$signed(rounded[20:0]) : $signed(rounded[20:0]);
                    if(selected==3)state<=PUBLISH;
                    else begin selected<=selected+1'b1;state<=LOAD;end
                end
                PUBLISH:begin
                    for(integer c=0;c<4;c=c+1)sample_data[c]<=(muted||source_reset) ? 21'sd0 : result[c];
                    sample_valid<=1;state<=IDLE;
                end
            endcase
        end
    end
endmodule

// Exact packing of the existing 4096 Q16 tuples. Their sum is65536;
// c0/c3 are nonpositive magnitudes<=4204 and c1 is unsigned<=65536.
// The original full image remains the sole initializer/runtime input.
module madmotor_lofi_rom(input wire clk,input wire [11:0] address,output wire [71:0] data);
    function automatic [42:0] compress(input [71:0] full);
        reg [17:0] magnitude0,magnitude3;
        begin
            magnitude0=-full[17:0];magnitude3=-full[71:54];
            compress={magnitude3[12:0],full[34:18],magnitude0[12:0]};
        end
    endfunction
    function automatic [71:0] expand(input [42:0] packed_data);
        reg signed [17:0] c0,c1,c2,c3;
        begin
            c0=-$signed({5'd0,packed_data[12:0]});
            c1=$signed({1'b0,packed_data[29:13]});
            c3=-$signed({5'd0,packed_data[42:30]});
            c2=18'sd65536-c0-c1-c3;
            expand={c3,c2,c1,c0};
        end
    endfunction
    (* ramstyle = "M10K" *) reg [42:0] coefficients[0:4095];
    reg [71:0] initial_image[0:4095]; // elaboration input only, no runtime reads
    integer index;
    initial begin
        $readmemh("madmotor_lofi_coeff.hex",initial_image);
        for(index=0;index<4096;index=index+1)begin
            coefficients[index]=compress(initial_image[index]);
`ifdef VERILATOR
            if(expand(coefficients[index])!==initial_image[index])$fatal(1,"Coefficient packing loss at%0d",index);
`endif
        end
    end
    reg [42:0] packed_data;
    always @(posedge clk)packed_data<=coefficients[address];
    assign data=expand(packed_data);
endmodule
