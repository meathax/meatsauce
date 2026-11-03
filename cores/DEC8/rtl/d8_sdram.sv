// SPDX-License-Identifier: GPL-3.0-or-later
// PRIVATE common48 candidate. Not selected by the production QIP.
//
// Interface/layout follow the existing d8_sdram (1945k III donor lineage).
// CL3/BL2, single-location WRITE: CPU uses the first READ word; graphics
// consumes both words of one READ(c)+AP. Graphics ROM is mirrored
// in banks1/2 and jobs alternate banks. Program ROM is in bank0 (main CPU)
// and mirrored in bank3 (sub CPU); each CPU also has a direct-mapped
// program cache. Reads release the scheduler at READ. All scheduling/metadata use clk.
// The physical prototype ties i_capture_clk to clk (16 physical input FFs).
//
// Inverted forwarded SDRAM clock accepts a registered command at clk+T/2.
// READ at master R reaches the chip at R+T/2. CL3: the chip drives D0 after
// its READ+2 edge (tAC) and D0 is valid at its READ+3 edge, i.e. FPGA falling
// edge R+3.5T; D1 follows at R+4.5T. Capture R+3.5T, consume R+4T (and R+5T
// for the graphics tail). Hardware: one beat later returns word+1 and every
// game boots black (DEC8 V25/final RBF, 2026-10-21; HeavyUnit lesson 11137).
// Primary/device event models and all-corner fitted pin/consumer proof are
// mandatory before promotion. See docs/DEC8_CLOCK_PLAN_20261018.md.
module d8_sdram #(
    parameter bit P_SHORT_INIT=1'b0,
    parameter integer INIT_CYCLES=20000,
    parameter integer REFRESH_PERIOD=350,
    parameter integer CACHE_AW=10        // per-CPU program cache: 2^CACHE_AW words
)(
    input wire clk,i_capture_clk,rst_n,
    output reg o_ready,
    input wire i_dl_wr,
    input wire[23:0] i_dl_addr,
    input wire[7:0] i_dl_data,
    output wire o_dl_busy,
    input wire i_cpu_run,i_cpu_req,
    input wire[19:0] i_cpu_addr,
    output wire[7:0] o_cpu_data,
    output wire o_cpu_ok,
    input wire i_sub_req,
    input wire[19:0] i_sub_addr,
    output wire[7:0] o_sub_data,
    output wire o_sub_ok,
    input wire i_gfx_req,
    input wire[21:0] i_gfx_addr,
    output wire o_gfx_gnt,
    output reg o_gfx_rv,
    output reg[31:0] o_gfx_data,
    output reg[15:0] o_dbg_refreshes,o_dbg_ref_forced,
    output reg[7:0] o_dbg_cpu_maxlat,o_dbg_sub_maxlat,
    output reg[15:0] o_dbg_dl_words,
    output reg[12:0] SDRAM_A,
    output reg[1:0] SDRAM_BA,
    inout wire[15:0] SDRAM_DQ,
    output wire SDRAM_DQML,SDRAM_DQMH,
    output wire SDRAM_nCS,SDRAM_nRAS,SDRAM_nCAS,SDRAM_nWE,SDRAM_CKE
);
    localparam[3:0] NOP=4'b0111,ACT=4'b0011,READ=4'b0101,
                    WRITE=4'b0100,PALL=4'b0010,REF=4'b0001,MODE=4'b0000;
    localparam[12:0] MODE_CL3_BL2_SINGLE_WRITE=13'h231;
    localparam integer COLD_WAIT=P_SHORT_INIT?32:INIT_CYCLES;
    reg[3:0] command;
    assign {SDRAM_nCS,SDRAM_nRAS,SDRAM_nCAS,SDRAM_nWE}=command;
    assign SDRAM_CKE=1'b1;
    assign SDRAM_DQML=1'b0;
    assign SDRAM_DQMH=1'b0;
    reg[15:0] dq_out;
    (* preserve,dont_merge *) reg[15:0] dq_oe_io;
    genvar lane;
    generate for(lane=0;lane<16;lane=lane+1)begin:gen_dq_oe
        assign SDRAM_DQ[lane]=dq_oe_io[lane]?dq_out[lane]:1'bz;
    end endgenerate
    reg[15:0] dq_in;
    always @(negedge i_capture_clk)dq_in<=SDRAM_DQ;

    typedef enum logic[2:0] {J_NONE,J_CPU,J_SUB,J_GFX,J_WRITE,J_REFRESH} job_t;
    typedef enum logic[2:0] {R_NONE,R_CPU,R_SUB,R_GFX_HI,R_GFX_LO} ret_t;
    job_t job;
    reg[3:0] phase;
    reg[1:0] job_bank;
    reg[21:0] job_word;
    reg[15:0] job_data;
    reg[31:0] job_epoch,epoch;
    reg run_q,next_gfx_bank;
    reg[3:0] bank_wait[0:3];
    wire banks_free=(bank_wait[0]==0)&&(bank_wait[1]==0)&&
                    (bank_wait[2]==0)&&(bank_wait[3]==0);
    reg[15:0] refresh_age;
    wire refresh_due=refresh_age>=REFRESH_PERIOD;

    // A half-word does not assert busy: the following odd byte must enter.
    // A complete pending word remains held until both graphics copies finish.
    reg half_valid,dl_pending,dl_second;
    reg[22:0] half_word,dl_word;
    reg[7:0] half_data;
    reg[15:0] dl_data;
    reg dl_graphics;
    assign o_dl_busy=!o_ready||dl_pending;
    wire dl_accept=i_dl_wr&&!o_dl_busy;
    // Graphics words are written to banks 1 and 2, program words to banks 0
    // (main CPU) and 3 (sub CPU mirror), so both CPU clients and the graphics
    // jobs can overlap in different banks.
    wire[1:0] dl_bank=dl_graphics?(dl_second?2'd2:2'd1):(dl_second?2'd3:2'd0);

    reg cpu_valid,sub_valid;
    reg[18:0] cpu_word,sub_word;
    reg[15:0] cpu_data,sub_data;

    // Per-CPU direct-mapped program ROM caches (performance). Program ROM is
    // read-only while the core runs, so a line is only filled from an actual
    // SDRAM return for its tagged word and the whole cache is swept invalid
    // after reset or any download byte. A hit acknowledges the held request
    // one clock after it appears instead of after an SDRAM round trip.
    // Lookup reads the line for the held address every clock; a line written
    // on the previous clock is not trusted (mixed-port read-during-write).
    localparam integer CTAG=19-CACHE_AW;
    localparam integer CLINE=1+CTAG+16;
    reg[CLINE-1:0] cpu_cache[0:(1<<CACHE_AW)-1];
    reg[CLINE-1:0] sub_cache[0:(1<<CACHE_AW)-1];
    reg[CLINE-1:0] cpu_line,sub_line;
    reg cpu_look,sub_look,cache_clean;
    reg[18:0] cpu_look_word,sub_look_word;
    reg[CACHE_AW-1:0] clear_index;
    wire cpu_fill,sub_fill;
    reg cpu_fill_q,sub_fill_q;
    reg[CACHE_AW-1:0] cpu_fill_index_q,sub_fill_index_q;
    wire[CACHE_AW-1:0] cpu_index=i_cpu_addr[CACHE_AW:1];
    wire[CACHE_AW-1:0] sub_index=i_sub_addr[CACHE_AW:1];
    wire cpu_looked=cpu_look&&cpu_look_word==i_cpu_addr[19:1];
    wire sub_looked=sub_look&&sub_look_word==i_sub_addr[19:1];
    wire cpu_hit=cache_clean&&cpu_looked&&cpu_line[CLINE-1]&&
        cpu_line[CLINE-2:16]==i_cpu_addr[19:CACHE_AW+1]&&
        !(cpu_fill_q&&cpu_fill_index_q==cpu_index);
    wire sub_hit=cache_clean&&sub_looked&&sub_line[CLINE-1]&&
        sub_line[CLINE-2:16]==i_sub_addr[19:CACHE_AW+1]&&
        !(sub_fill_q&&sub_fill_index_q==sub_index);
    wire cpu_reg_hit=cpu_valid&&cpu_word==i_cpu_addr[19:1];
    wire sub_reg_hit=sub_valid&&sub_word==i_sub_addr[19:1];
    wire[15:0] cpu_word_data=cpu_reg_hit?cpu_data:cpu_line[15:0];
    wire[15:0] sub_word_data=sub_reg_hit?sub_data:sub_line[15:0];
    assign o_cpu_data=i_cpu_addr[0]?cpu_word_data[7:0]:cpu_word_data[15:8];
    assign o_sub_data=i_sub_addr[0]?sub_word_data[7:0]:sub_word_data[15:8];
    assign o_cpu_ok=o_ready&&i_cpu_run&&i_cpu_req&&(cpu_reg_hit||cpu_hit);
    assign o_sub_ok=o_ready&&i_cpu_run&&i_sub_req&&(sub_reg_hit||sub_hit);
    // A READ issued for the held word is in flight from its READ edge until
    // the consume edge publishes it. Jobs release the scheduler at READ, so
    // every stage is covered to prevent a duplicate job for the same word.
    wire cpu_returning=(ret_kind[0]==R_CPU||ret_kind[1]==R_CPU||ret_kind[2]==R_CPU||ret_kind[3]==R_CPU)&&
        cpu_return_word==i_cpu_addr[19:1];
    wire sub_returning=(ret_kind[0]==R_SUB||ret_kind[1]==R_SUB||ret_kind[2]==R_SUB||ret_kind[3]==R_SUB)&&
        sub_return_word==i_sub_addr[19:1];
    // want: the request is not yet satisfied (blocks graphics admission);
    // miss: the cache lookup for the held word completed without a hit.
    wire cpu_want=i_cpu_req&&!o_cpu_ok&&!cpu_returning&&!(job==J_CPU);
    wire sub_want=i_sub_req&&!o_sub_ok&&!sub_returning&&!(job==J_SUB);
    wire cpu_miss=cpu_want&&cpu_looked;
    wire sub_miss=sub_want&&sub_looked;
    wire game_admit=i_cpu_run&&run_q;
    wire[1:0] gfx_bank=next_gfx_bank?2'd2:2'd1;
    assign o_gfx_gnt=o_ready&&job==J_NONE&&!refresh_due&&!dl_pending&&
        game_admit&&!cpu_want&&!sub_want&&bank_wait[gfx_bank]==0;

    // READ metadata stays on the command master. The R+3.5 falling-edge input capture
    // (CL3 D0) is consumed at R+4 from ret_kind[3]. Earlier unconditionally captured words are ignored.
    ret_t ret_kind[0:4];
    reg[18:0] cpu_return_word,sub_return_word;
    reg[3:0] read_turnaround;
    reg[15:0] gfx_high;
    reg[7:0] cpu_age,sub_age;
    reg[15:0] cold_count;
    reg[2:0] init_step;
    reg[3:0] init_wait;

    // Fill from the same consume stage that publishes cpu_data/sub_data.
    wire session_change=run_q!=i_cpu_run||dl_accept;
    assign cpu_fill=o_ready&&i_cpu_run&&!session_change&&ret_kind[3]==R_CPU;
    assign sub_fill=o_ready&&i_cpu_run&&!session_change&&ret_kind[3]==R_SUB;
    wire[CLINE-1:0] cpu_fill_line={1'b1,cpu_return_word[18:CACHE_AW],dq_in};
    wire[CLINE-1:0] sub_fill_line={1'b1,sub_return_word[18:CACHE_AW],dq_in};
    always @(posedge clk)begin
        if(!cache_clean)cpu_cache[clear_index]<={CLINE{1'b0}};
        else if(cpu_fill)cpu_cache[cpu_return_word[CACHE_AW-1:0]]<=cpu_fill_line;
        cpu_line<=cpu_cache[cpu_index];
    end
    always @(posedge clk)begin
        if(!cache_clean)sub_cache[clear_index]<={CLINE{1'b0}};
        else if(sub_fill)sub_cache[sub_return_word[CACHE_AW-1:0]]<=sub_fill_line;
        sub_line<=sub_cache[sub_index];
    end
    always @(posedge clk)begin
        cpu_look<=i_cpu_req;cpu_look_word<=i_cpu_addr[19:1];
        sub_look<=i_sub_req;sub_look_word<=i_sub_addr[19:1];
        cpu_fill_q<=cpu_fill||!cache_clean;sub_fill_q<=sub_fill||!cache_clean;
        cpu_fill_index_q<=cache_clean?cpu_return_word[CACHE_AW-1:0]:clear_index;
        sub_fill_index_q<=cache_clean?sub_return_word[CACHE_AW-1:0]:clear_index;
        if(!rst_n||dl_accept)begin cache_clean<=0;clear_index<=0;end
        else if(!cache_clean)begin
            clear_index<=clear_index+1'd1;
            if(&clear_index)cache_clean<=1;
        end
    end

    function automatic[12:0] column(input[21:0] word_address,input bit ap);
        column={2'b00,ap,1'b0,word_address[8:0]};
    endfunction

    always @(posedge clk)begin
        command<=NOP;
        dq_oe_io<=16'd0;
        o_gfx_rv<=1'b0;
        ret_kind[0]<=ret_kind[0]==R_GFX_HI?R_GFX_LO:R_NONE;
        if(!rst_n)begin
            cpu_return_word<=0;sub_return_word<=0;read_turnaround<=0;
            o_ready<=0;command<=NOP;SDRAM_A<=0;SDRAM_BA<=0;
            dq_out<=0;dq_oe_io<=0;
            cold_count<=0;init_step<=0;init_wait<=0;
            job<=J_NONE;phase<=0;job_bank<=0;job_word<=0;job_data<=0;
            job_epoch<=0;epoch<=0;run_q<=0;next_gfx_bank<=0;
            refresh_age<=0;half_valid<=0;dl_pending<=0;dl_second<=0;
            half_word<=0;half_data<=0;dl_word<=0;dl_data<=0;dl_graphics<=0;
            cpu_valid<=0;sub_valid<=0;cpu_word<=0;sub_word<=0;cpu_data<=0;sub_data<=0;
            gfx_high<=0;o_gfx_data<=0;cpu_age<=0;sub_age<=0;
            o_dbg_refreshes<=0;o_dbg_ref_forced<=0;o_dbg_dl_words<=0;
            o_dbg_cpu_maxlat<=0;o_dbg_sub_maxlat<=0;
            for(integer k=0;k<4;k=k+1)bank_wait[k]<=0;
            for(integer k=0;k<5;k=k+1)begin
                ret_kind[k]<=R_NONE;
            end
        end else begin
            if(read_turnaround!=0)read_turnaround<=read_turnaround-4'd1;
            run_q<=i_cpu_run;
            if(run_q!=i_cpu_run)epoch<=epoch+32'd1;
            for(integer k=0;k<4;k=k+1)begin
                if(bank_wait[k]!=0)bank_wait[k]<=bank_wait[k]-4'd1;
            end
            for(integer k=1;k<5;k=k+1)begin
                ret_kind[k]<=ret_kind[k-1];
            end
            if(i_cpu_run)begin
                case(ret_kind[3])
                    // CL3: first capture READ+3.5, consume READ+4; BL2 tail consume READ+5.
                    // Dedicated per-client READ tags survive a new ACT before consumption.
                    R_CPU:begin cpu_valid<=1;cpu_word<=cpu_return_word;cpu_data<=dq_in;end
                    R_SUB:begin sub_valid<=1;sub_word<=sub_return_word;sub_data<=dq_in;end
                    R_GFX_HI:gfx_high<=dq_in;
                    R_GFX_LO:begin o_gfx_data<={gfx_high,dq_in};o_gfx_rv<=1;end
                    default:;
                endcase
            end
            if(!i_cpu_req)cpu_age<=0;else if(cpu_age!=8'hff)cpu_age<=cpu_age+8'd1;
            if(!i_sub_req)sub_age<=0;else if(sub_age!=8'hff)sub_age<=sub_age+8'd1;
            if(o_cpu_ok&&cpu_age>o_dbg_cpu_maxlat)o_dbg_cpu_maxlat<=cpu_age;
            if(o_sub_ok&&sub_age>o_dbg_sub_maxlat)o_dbg_sub_maxlat<=sub_age;
            // Invalidations dominate simultaneous old-epoch returns.
            if(run_q!=i_cpu_run||dl_accept)begin cpu_valid<=0;sub_valid<=0;end
            if(dl_accept)begin
                if(!i_dl_addr[0])begin
                    half_word<=i_dl_addr[23:1];half_data<=i_dl_data;half_valid<=1;
                end else begin
                    dl_word<=i_dl_addr[23:1];dl_data<={half_data,i_dl_data};
                    dl_pending<=1;dl_second<=0;half_valid<=0;
                    dl_graphics<=i_dl_addr>=24'h100000;
                end
            end
            if(!o_ready)begin
                if(cold_count<COLD_WAIT)cold_count<=cold_count+16'd1;
                else if(init_wait!=0)init_wait<=init_wait-4'd1;
                else case(init_step)
                    0:begin command<=PALL;SDRAM_A<=13'h400;init_wait<=2;init_step<=1;end
                    1:begin command<=REF;init_wait<=6;init_step<=2;end
                    2:begin command<=REF;init_wait<=6;init_step<=3;end
                    3:begin command<=MODE;SDRAM_BA<=0;SDRAM_A<=MODE_CL3_BL2_SINGLE_WRITE;init_wait<=1;init_step<=4;end
                    4:o_ready<=1;
                    default:;
                endcase
            end else begin
                refresh_age<=refresh_age+16'd1;
                if(job==J_NONE)begin
                    phase<=0;
                    if(refresh_due)begin
                        if(banks_free)begin
                            command<=REF;job<=J_REFRESH;phase<=1;refresh_age<=0;
                            o_dbg_refreshes<=o_dbg_refreshes+16'd1;
                            if(i_cpu_run)o_dbg_ref_forced<=o_dbg_ref_forced+16'd1;
                        end
                    end else if(dl_pending)begin
                        if(bank_wait[dl_bank]==0&&read_turnaround==0)begin
                            job<=J_WRITE;phase<=1;command<=ACT;
                            job_bank<=dl_bank;
                            SDRAM_BA<=dl_bank;
                            job_word<=dl_graphics?dl_word[21:0]-22'h080000:dl_word[21:0];
                            SDRAM_A<=dl_graphics?(dl_word[21:9]-13'h400):dl_word[21:9];
                            job_data<=dl_data;
                            bank_wait[dl_bank]<=5;
                        end
                    end else if(game_admit)begin
                        if(cpu_miss&&bank_wait[0]==0)begin
                            job<=J_CPU;phase<=1;command<=ACT;job_bank<=0;SDRAM_BA<=0;
                            job_word<={3'd0,i_cpu_addr[19:1]};SDRAM_A<={3'd0,i_cpu_addr[19:10]};
                            job_epoch<=epoch;bank_wait[0]<=5;
                        end else if(sub_miss&&bank_wait[3]==0)begin
                            job<=J_SUB;phase<=1;command<=ACT;job_bank<=3;SDRAM_BA<=3;
                            job_word<={3'd0,i_sub_addr[19:1]};SDRAM_A<={3'd0,i_sub_addr[19:10]};
                            job_epoch<=epoch;bank_wait[3]<=5;
                        end else if(o_gfx_gnt&&i_gfx_req)begin // exactly the granted request
                            job<=J_GFX;phase<=1;command<=ACT;job_bank<=gfx_bank;SDRAM_BA<=gfx_bank;
                            job_word<={1'b0,i_gfx_addr[21:1]};SDRAM_A<={1'b0,i_gfx_addr[21:10]};
                            job_epoch<=epoch;bank_wait[gfx_bank]<=5;next_gfx_bank<=!next_gfx_bank;
                        end
                    end
                end else begin
                    phase<=phase+4'd1;
                    if(job!=J_REFRESH&&phase==2)begin
                        SDRAM_BA<=job_bank;SDRAM_A<=column(job_word,1'b1);
                        if(job==J_WRITE)begin command<=WRITE;dq_out<=job_data;dq_oe_io<=16'hffff;end
                        else begin
                            command<=READ;read_turnaround<=6;
                            if(job_epoch==epoch&&i_cpu_run)begin
                                ret_kind[0]<=job==J_CPU?R_CPU:job==J_SUB?R_SUB:R_GFX_HI;
                                if(job==J_CPU)cpu_return_word<=job_word[18:0];
                                if(job==J_SUB)sub_return_word<=job_word[18:0];
                            end
                        end
                    end
                    // Reads (auto-precharge) release the command scheduler at READ;
                    // bank_wait keeps the same bank closed for its row cycle and
                    // the next READ is at least three clocks later (BL2 data bus).
                    if(((job==J_GFX||job==J_CPU||job==J_SUB)&&phase==2)||(job==J_REFRESH&&phase==3))job<=J_NONE;
                    if(job==J_WRITE&&phase==5)begin
                        job<=J_NONE;
                        if(!dl_second)dl_second<=1;
                        else begin dl_pending<=0;dl_second<=0;o_dbg_dl_words<=o_dbg_dl_words+16'd1;end
                    end
                end
            end
            // Clear all in-flight logical returns on a session transition.
            // This dominates shifts and READ admission above. Physical jobs
            // drain normally; job_epoch prevents their later READs re-tagging.
            if(run_q!=i_cpu_run||dl_accept)
                for(integer k=0;k<5;k=k+1)ret_kind[k]<=R_NONE;
        end
    end
`ifdef SIMULATION
    reg sim_cpu_pending=0,sim_sub_pending=0;
    reg[18:0] sim_cpu_tag,sim_sub_tag;
    always @(posedge clk)begin
        if(!rst_n||run_q!=i_cpu_run||dl_accept)begin sim_cpu_pending<=0;sim_sub_pending<=0;end
        else begin
            if(i_cpu_run&&ret_kind[3]==R_CPU)begin
                if(!sim_cpu_pending||cpu_return_word!==sim_cpu_tag)$fatal(1,"SDRAM48_CPU_RETURN_TAG_LIFETIME");
                sim_cpu_pending<=0;
            end
            if(i_cpu_run&&ret_kind[3]==R_SUB)begin
                if(!sim_sub_pending||sub_return_word!==sim_sub_tag)$fatal(1,"SDRAM48_SUB_RETURN_TAG_LIFETIME");
                sim_sub_pending<=0;
            end
            if(o_ready&&job==J_CPU&&phase==2&&job_epoch==epoch&&i_cpu_run)begin
                if(sim_cpu_pending&&ret_kind[3]!=R_CPU)$fatal(1,"SDRAM48_CPU_RETURN_TAG_REPLACED");
                sim_cpu_pending<=1;sim_cpu_tag<=job_word[18:0];
            end
            if(o_ready&&job==J_SUB&&phase==2&&job_epoch==epoch&&i_cpu_run)begin
                if(sim_sub_pending&&ret_kind[3]!=R_SUB)$fatal(1,"SDRAM48_SUB_RETURN_TAG_REPLACED");
                sim_sub_pending<=1;sim_sub_tag<=job_word[18:0];
            end
        end
    end
    always @(posedge clk)if(rst_n&&o_ready)begin

        if(refresh_age>380)$fatal(1,"SDRAM48_REFRESH_DEADLINE");
        if(i_dl_wr&&o_dl_busy)$fatal(1,"SDRAM48_DOWNLOAD_BACKPRESSURE_IGNORED");
        if(dl_accept&&i_dl_addr[0]&&(!half_valid||half_word!=i_dl_addr[23:1]))
            $fatal(1,"SDRAM48_DOWNLOAD_UNPAIRED_BYTE");
        if(dl_accept&&!i_dl_addr[0]&&half_valid)$fatal(1,"SDRAM48_DOWNLOAD_HIGH_BYTE_REPLACED");
        if(o_gfx_gnt&&i_gfx_req&&i_gfx_addr[1:0]!=0)$fatal(1,"SDRAM48_GRAPHICS_UNALIGNED");
        if(dl_accept&&i_cpu_run)$fatal(1,"SDRAM48_DOWNLOAD_DURING_EXECUTION");
    end
`endif
endmodule
