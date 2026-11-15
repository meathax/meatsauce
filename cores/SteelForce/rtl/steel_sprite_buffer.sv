// Exact MAME0.289 buffered sprite command semantics, including clear's rearm.
// Command completion stalls its CPU bus write until an atomic buffer swap.
// DMA borrows RAM port A while CPU waits; renderer continues on port B.
// Physical PCB DMA duration is undocumented; this is the explicit reference model.
// The completed buffer becomes visible at the next frame display latch (vblank start, with
// scroll and palette), never mid-frame: MAME draws the whole frame from one buffer state.
module steel_sprite_buffer(
    input wire clk, reset, command_valid,
    input wire [15:0] command,
    output reg command_done,
    output wire busy,
    output wire dma_en,
    output wire [16:0] dma_word_addr,
    input wire [15:0] dma_rdata,
    input wire sprite_en,
    input wire [7:0] sprite_index,
    output wire [63:0] sprite_data,
    output reg which,
    output wire active_bank,
    input wire display_latch, render_busy
);
    localparam IDLE=0,COPY=1,DRAIN=2,CLEAR=3;
    reg [1:0] state;
    reg front=0; // power-up selector; soft reset retains the existing display buffer
    reg [9:0] read_index,write_index;
    reg pipeline_valid,swap_pending,latch_pending;
    wire write_enable=(state==COPY && pipeline_valid) || state==DRAIN || state==CLEAR;
    wire [15:0] write_data=state==CLEAR ? 16'b0 : dma_rdata;
    assign busy=state!=IDLE;
    assign active_bank=front;
    assign dma_en=state==COPY;
    assign dma_word_addr=17'h04000+{7'b0,read_index};
    genvar field;
    generate for(field=0;field<4;field=field+1) begin: fields
        localparam [1:0] FIELD_ID=field;
        wire selected=write_enable && write_index[1:0]==FIELD_ID;
        wire [15:0] unused;
        steel_dpram8 #(.AW(9)) hi_bank(
            .clk(clk),.cpu_we(selected),.cpu_addr({!front,write_index[9:2]}),
            .cpu_data(write_data[15:8]),.cpu_q(unused[15:8]),
            .video_en(sprite_en),.video_addr({front,sprite_index}),.video_q(sprite_data[field*16+8+:8]));
        steel_dpram8 #(.AW(9)) lo_bank(
            .clk(clk),.cpu_we(selected),.cpu_addr({!front,write_index[9:2]}),
            .cpu_data(write_data[7:0]),.cpu_q(unused[7:0]),
            .video_en(sprite_en),.video_addr({front,sprite_index}),.video_q(sprite_data[field*16+:8]));
    end endgenerate
    always_ff @(posedge clk) begin
        command_done<=0;
        if(reset) begin state<=IDLE;which<=0;pipeline_valid<=0;read_index<=0;write_index<=0;swap_pending<=0;latch_pending<=0;end
        else begin
        if(display_latch) latch_pending<=1;
        else if(latch_pending && state==IDLE && !command_valid && !render_busy) begin
            latch_pending<=0;
            if(swap_pending) begin front<=!front;swap_pending<=0;end
        end
        case(state)
            IDLE: if(command_valid) begin
                read_index<=0;write_index<=0;pipeline_valid<=0;
                if(!which) begin which<=1;command_done<=1;end
                else if(command[3:0]==0) begin which<=1;state<=CLEAR;end
                else begin
                    which<=0;
                    if(command[3:0]==4'hd) command_done<=1;
                    else state<=COPY;
                end
            end
            COPY: begin
                pipeline_valid<=1;
                if(pipeline_valid) write_index<=write_index+1'b1;
                if(read_index==1023) state<=DRAIN;
                else read_index<=read_index+1'b1;
            end
            DRAIN: begin swap_pending<=1;state<=IDLE;command_done<=1;pipeline_valid<=0;end
            CLEAR: begin
                if(write_index==1023) begin swap_pending<=1;state<=IDLE;command_done<=1;end
                else write_index<=write_index+1'b1;
            end
            default: state<=IDLE;
        endcase
        end
    end
`ifdef SIMULATION
    always @(posedge clk) if(!reset) assert(!(busy && command_valid)) else $fatal(1,"Overlapping sprite commands");
`endif
endmodule
