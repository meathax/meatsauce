// SPDX-License-Identifier: GPL-3.0-or-later
// Pairs screen_rotate's adjacent32-bit pixels across source scanlines, then
// queues physical writes. Completed bank generations alone can be displayed.
module penguin_platform_framebuffer #(
    parameter integer MAX_SOURCE_WIDTH=320,FIFO_DEPTH=512,REGISTERED_GEOMETRY_EPOCH=0
)(
    input logic clk,reset,input logic[1:0] mode,
    input logic source_ce,source_de,source_vs,
    input logic in_we,input logic[28:0] in_addr,input logic[63:0] in_data,input logic[7:0] in_be,
    input logic raw_en,registered_geometry_epoch,input logic[11:0] raw_width,raw_height,input logic[13:0] raw_stride,input logic[31:0] raw_base,
    input logic display_vbl,output logic gated_vbl,
    output wire display_en,output wire[31:0] display_base,output wire[11:0] display_width,display_height,output wire[13:0] display_stride,
    output wire out_we,output wire[28:0] out_addr,output wire[63:0] out_data,output wire[7:0] out_be,input logic out_busy,
    output logic overflow,output logic[15:0] high_water,output logic[31:0] pixel_count,write_count,published_frames
);
    localparam integer PW=$clog2(FIFO_DEPTH),RW=$clog2(MAX_SOURCE_WIDTH);
    // Halfword pairing tags include the complete bank/word address. A source
    // xposition identifies the same rotated output row on the next scanline.
    (* ramstyle="M10K" *) logic[61:0] halves[0:MAX_SOURCE_WIDTH-1];
    logic[MAX_SOURCE_WIDTH-1:0] half_valid=0;logic[61:0] half_q;
    logic[RW:0] source_x=0;logic[RW-1:0] row=0;logic[28:0] pixel_addr;
    logic[31:0] pixel_data;logic pixel_high;
    typedef enum logic[2:0]{ACCEPT,PAIR,FLUSH_READ,FLUSH_CHECK,END_FRAME} stage_t;
    stage_t stage=ACCEPT;logic[RW:0] scan=0;
    logic[1:0] old_mode=0,frame_bank=0;logic[15:0] generation[0:2];
    logic[15:0] frame_generation=0;logic frame_active=0,accept_epoch=0;
    logic old_vs=0,old_de=0,old_vbl=0,source_vs_d=0;logic publication_arm=0,display_pending=0;wire enabled=mode==1||mode==2;
    logic[11:0] old_width=0,old_height=0;logic[13:0] old_stride=0;
    // Parallel equality boundaries keep late mode changes off geometry chains.
    (* keep *) wire mode_epoch_change=mode!=old_mode;
    wire geometry_epoch_change;
    generate if(REGISTERED_GEOMETRY_EPOCH)begin: registered_epoch
        assign geometry_epoch_change=registered_geometry_epoch;
    end else begin: compared_epoch
        (* keep *) wire width_epoch_change=raw_width!=old_width;
        (* keep *) wire height_epoch_change=raw_height!=old_height;
        (* keep *) wire stride_epoch_change=raw_stride!=old_stride;
        assign geometry_epoch_change=width_epoch_change||height_epoch_change||stride_epoch_change;
    end endgenerate
    wire epoch_change=mode_epoch_change||geometry_epoch_change;
    wire end_line=source_ce&&old_de&&!source_de;
    wire frame_edge=source_ce&&source_vs&&!old_vs;
    // Metadata travels with the end marker, never with a later OSD geometry.
    logic[11:0] width_done[0:2],height_done[0:2];logic[13:0] stride_done[0:2];
    logic[2:0] complete=0;logic[1:0] published_bank=0;logic published_valid=0;
    function automatic[1:0] next_bank(input[1:0] a,b);
        next_bank=1;
        if((a==0&&b==1)||(a==1&&b==0))next_bank=2;
        if((a==1&&b==2)||(a==2&&b==1))next_bank=0;
    endfunction
    wire[1:0] candidate=next_bank(raw_base[24:23],in_addr[21:20]);
    assign gated_vbl=publication_arm&&display_vbl&&!source_vs&&!source_vs_d&&!reset&&!epoch_change&&!overflow;
    assign display_en=enabled&&published_valid&&!overflow;
    assign display_base={raw_base[31:25],published_bank,23'd0};
    assign display_width=width_done[published_bank];assign display_height=height_done[published_bank];assign display_stride=stride_done[published_bank];
    //104bits: endmarker, bank, physicalword address, data/marker metadata, BE.
    (* ramstyle="M10K" *) logic[103:0] queue[0:FIFO_DEPTH-1];
    logic[PW-1:0] wp=0,rp=0;logic[PW:0] count=0;logic[103:0] queue_q,head,push_data;
    logic push=0;logic[1:0] pop_state=0;
    wire pop=(pop_state==2)&&!out_busy;
    wire room=count<FIFO_DEPTH-2;
    assign out_we=pop_state==2&&!head[103]&&!reset&&!epoch_change;
    assign out_addr=head[100:72];assign out_data=head[71:8];assign out_be=head[7:0];
    // Each valid entry uses its own bit; the wide indexed read remains only
    // in payload selection, outside the valid-vector feedback path.
    genvar valid_index;
    generate for(valid_index=0;valid_index<MAX_SOURCE_WIDTH;valid_index=valid_index+1)begin: valid_entry
        always_ff @(posedge clk)begin
            if(reset||epoch_change)half_valid[valid_index]<=0;
            else case(stage)
                PAIR:if(row==valid_index)begin
                    if(half_valid[valid_index])begin
                        if(!room)begin end else begin
                            if(half_q[61:33]==pixel_addr&&half_q[32]!=pixel_high)
                                half_valid[valid_index]<=0;
                        end
                    end else half_valid[valid_index]<=1;
                end
                FLUSH_CHECK:if(scan==valid_index)begin
                    if(half_valid[valid_index])begin
                        if(!room)begin end else half_valid[valid_index]<=0;
                    end
                end
                default:;
            endcase
        end
    end endgenerate
    always_ff @(posedge clk)begin
        half_q<=halves[stage==FLUSH_READ?scan[RW-1:0]:source_x[RW-1:0]];
        queue_q<=queue[rp];
        push<=0;publication_arm<=0;old_mode<=mode;old_vbl<=display_vbl;source_vs_d<=source_vs;
        old_width<=raw_width;old_height<=raw_height;old_stride<=raw_stride;
        if(source_ce)begin old_vs<=source_vs;old_de<=source_de;end
        if(reset||epoch_change)begin
            stage<=ACCEPT;source_x<=0;frame_active<=0;accept_epoch<=0;
            wp<=0;rp<=0;count<=0;pop_state<=0;push<=0;complete<=0;published_valid<=0;display_pending<=0;publication_arm<=0;
            for(integer b=0;b<3;b++)generation[b]<=0;
            if(reset)begin overflow<=0;high_water<=0;pixel_count<=0;write_count<=0;published_frames<=0;end
        end else begin
            case({push,pop})
                2'b10:count<=count+1'b1;
                2'b01:count<=count-1'b1;
                default:;
            endcase
            if(push)begin
                if(count==FIFO_DEPTH)overflow<=1;
                else begin queue[wp]<=push_data;wp<=wp+1'b1;end
            end
            if(count>high_water)high_water<=16'(count);
            case(pop_state)
                0:if(count!=0)pop_state<=1;
                1:begin head<=queue_q;pop_state<=2;end
                2:if(pop)begin
                    rp<=rp+1'b1;pop_state<=0;
                    if(head[103])begin
                        if(head[102:101]<3&&head[61:46]==generation[head[102:101]])begin
                            complete[head[102:101]]<=1;
                            width_done[head[102:101]]<=head[19:8];height_done[head[102:101]]<=head[31:20];stride_done[head[102:101]]<=head[45:32];
                        end
                    end else write_count<=write_count+1'b1;
                end
            endcase
            // FB_BASE changes only inside the actual HDMI vertical blank.
            // The combinational hazard mask follows immutable screen_rotate's
            // master-clock VS sampling; commit on its SAME gated-VBL edge.
            if(display_vbl&&!old_vbl)display_pending<=1;
            if(!display_vbl)display_pending<=0;
            if(display_pending&&display_vbl&&!publication_arm&&!source_vs&&!source_vs_d
               &&enabled&&complete[candidate]&&candidate!=in_addr[21:20]&&!overflow)publication_arm<=1;
            if(gated_vbl)begin
                published_bank<=candidate;published_valid<=1;display_pending<=0;
                published_frames<=published_frames+1'b1;
            end
            if(end_line)source_x<=0;
            if(frame_edge)begin
                accept_epoch<=enabled;
                if(frame_active)begin scan<=0;stage<=FLUSH_READ;end
            end
            if(in_we&&enabled&&accept_epoch&&raw_en)begin
                if(stage!=ACCEPT||source_x>=MAX_SOURCE_WIDTH)overflow<=1;
                else begin
                    row<=source_x[RW-1:0];pixel_addr<=in_addr;pixel_high<=in_be==8'hf0;
                    pixel_data<=in_be==8'hf0 ? in_data[63:32]:in_data[31:0];stage<=PAIR;
                    source_x<=source_x+1'b1;pixel_count<=pixel_count+1'b1;
                    if(in_be!=8'h0f&&in_be!=8'hf0)overflow<=1;
                    if(!frame_active)begin
                        frame_bank<=in_addr[21:20];frame_generation<=generation[in_addr[21:20]]+1'b1;
                        generation[in_addr[21:20]]<=generation[in_addr[21:20]]+1'b1;complete[in_addr[21:20]]<=0;frame_active<=1;
                    end
                end
            end
            case(stage)
                PAIR:begin
                    if(half_valid[row])begin
                        if(!room)overflow<=1;
                        else begin
                            push<=1;
                            if(half_q[61:33]==pixel_addr&&half_q[32]!=pixel_high)begin
                                push_data<={1'b0,frame_bank,pixel_addr,pixel_high?{pixel_data,half_q[31:0]}:{half_q[31:0],pixel_data},8'hff};
                            end else begin
                                push_data<={1'b0,frame_bank,half_q[61:33],{half_q[31:0],half_q[31:0]},half_q[32]?8'hf0:8'h0f};
                                halves[row]<={pixel_addr,pixel_high,pixel_data};
                            end
                        end
                    end else begin halves[row]<={pixel_addr,pixel_high,pixel_data};end
                    stage<=ACCEPT;
                end
                FLUSH_READ:stage<=FLUSH_CHECK;
                FLUSH_CHECK:begin
                    if(half_valid[scan])begin
                        if(!room)begin overflow<=1;end
                        else begin push<=1;push_data<={1'b0,frame_bank,half_q[61:33],{half_q[31:0],half_q[31:0]},half_q[32]?8'hf0:8'h0f};end
                    end
                    if(scan==MAX_SOURCE_WIDTH-1)stage<=END_FRAME;else begin scan<=scan+1'b1;stage<=FLUSH_READ;end
                end
                END_FRAME:begin
                    if(room)begin push<=1;push_data<={1'b1,frame_bank,29'd0,10'd0,frame_generation,raw_stride,raw_height,raw_width,8'd0};stage<=ACCEPT;frame_active<=0;end
                    else overflow<=1;
                end
                default:;
            endcase
        end
    end
endmodule
