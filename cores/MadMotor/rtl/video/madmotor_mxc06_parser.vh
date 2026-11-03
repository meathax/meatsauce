// Mad Motor multi-column descriptor parser, adapted from jtcop_obj_draw.
// Each column owns its code word; only the parent owns X/Y/flip/color/flash.
reg [2:0] columns_left;
reg first_column, parent_draw;
wire [10:0] parent_next = {1'b0,tbl_addr} +
    (tbl_dout[15] ? (11'd4 << tbl_dout[10:9]) : 11'd4);
wire [10:0] column_next = {1'b0,tbl_addr} +
    (columns_left==1 ? 11'd3 : 11'd4);

always @(posedge clk, posedge rst) begin
    if(rst) begin
        tbl_addr<=0; cen2<=0; parse_busy<=0; draw<=0; frame<=0;
        nsize<=0; msize<=0; HSl<=0; LVl<=0;
        columns_left<=0; first_column<=1; parent_draw<=0;
        hflip<=0; vflip<=0; veff<=0; xpos<=0; pal<=0; id<=0;
    end else if(chip_cen) begin
        HSl<=HS; LVl<=LVBL; cen2<=~cen2; draw<=0;
        if(!LVBL && LVl) frame<=~frame;
        if(HSl && !HS) begin
            tbl_addr<=0; parse_busy<=1; cen2<=0;
            first_column<=1; columns_left<=0;
        end
        if(parse_busy && !draw_busy && !draw && cen2) begin
            case(tbl_addr[1:0])
                0: begin
                    {vflip,hflip}<=tbl_dout[14:13];
                    msize<=tbl_dout[12:11];
                    veff<=vrf-ypos;
                    nsize<=0; // One column per draw transaction.
                    columns_left<=nsize_aux[2:0];
                    first_column<=1;
                    if(!inzone || !tbl_dout[15]) begin
                        // Invisible enabled parents still consume all columns.
                        tbl_addr<=parent_next[9:0];
                        if(parent_next[10]) parse_busy<=0;
                    end else tbl_addr<=tbl_addr+10'd1;
                end
                1: begin
                    id<=id_eff;
                    if(first_column) tbl_addr<=tbl_addr+10'd1;
                    else begin
                        xpos<=xpos-9'd16;
                        draw<=parent_draw;
                        columns_left<=columns_left-1'b1;
                        tbl_addr<=column_next[9:0];
                        if(column_next[10]) parse_busy<=0;
                    end
                end
                2: begin
                    xpos<=9'd240-tbl_dout[8:0];
                    pal<=tbl_dout[15:12];
                    parent_draw<=~tbl_dout[11] | frame;
                    draw<=~tbl_dout[11] | frame;
                    first_column<=0;
                    if(columns_left==0) begin
                        tbl_addr<=tbl_addr+10'd2;
                        if(&tbl_addr[9:2]) parse_busy<=0;
                    end else tbl_addr<=tbl_addr+10'd3;
                end
                default: parse_busy<=0;
            endcase
            if(line_cnt>=48) parse_busy<=0;
        end
    end
end
