// SPDX-License-Identifier: GPL-3.0-or-later
// Crystal RAM map to the staged ultraembedded 16-bit SDRAM controller.
// One owned word request, with two coherent 32-byte read lines per RAM region.
// Local line fills amortize shared arbitration/controller overhead for scanout.
module cs_sdram_backend #(parameter PHASED_CAPTURE=0, REGISTERED_IO=0) (
    input logic clk, reset, sdram_capture_clk,
    output logic initialized,
    input logic req_valid,
    output logic req_ready,
    input logic [3:0] req_target,
    input logic [31:0] req_offset, req_data,
    input logic [3:0] req_strobe,
    input logic req_write,
    output logic rsp_valid,
    output logic [31:0] rsp_data,
    output logic rsp_error,
    // 32-byte line burst port (GPU). Region 0 = texture/VRAM (target 2), 1 = frame RAM
    // (target 3). Accepted when idle, alternating fairly with the word request path; the
    // eight words stream back to back through the open row. burst_done pulses once, with
    // burst_rdata valid for reads. Zero-strobe write words are skipped.
    input logic burst_valid, burst_write, burst_region,
    input logic burst_urgent, // display line fetch: not alternated behind word requests (raster deadline)
    input logic [17:0] burst_line,
    input logic [7:0][31:0] burst_wdata,
    input logic [7:0][3:0] burst_wstrobe,
    output logic burst_ready, burst_done,
    output logic [7:0][31:0] burst_rdata,
    // Texture-region write snoop (registered): every accepted word write into texture/VRAM
    // (target 2), for the GPU read caches to stay coherent across packets.
    output logic texture_snoop_valid,
    output logic [17:0] texture_snoop_line,
    input logic [15:0] sdram_data_in,
    output logic sdram_clk, sdram_cke, sdram_cs_n,
    output logic sdram_ras_n, sdram_cas_n, sdram_we_n,
    output logic [1:0] sdram_dqm, sdram_ba,
    output logic [12:0] sdram_address,
    output logic [15:0] sdram_data_out,
    output logic sdram_data_oe
);
    logic busy, local_reply, local_error;
    logic controller_accept, controller_ack, controller_error;
    logic [31:0] controller_data, physical_address, controller_address;
    logic [15:0] sampled_dq;
    // Single master clock: DQ is registered on clk. The phase-shifted PLL output
    // (sdram_capture_clk) now only drives the forwarded SDRAM_CLK output cell, so it
    // is not a logic clock domain.
    wire capture_clock=clk;
    generate if(PHASED_CAPTURE || REGISTERED_IO) begin : capture
        // Freeze DQ in its measured window before the donor's clk-domain
        // sampling edge. Its original two registers/read queue remain intact.
        // Initialization completes thousands of edges before a first read.
        always_ff @(posedge capture_clock) sampled_dq<=sdram_data_in;
    end else begin : functional_capture
        always_comb sampled_dq=sdram_data_in;
    end endgenerate
    wire raw_clk, raw_cke, raw_cs_n, raw_ras_n, raw_cas_n, raw_we_n, raw_oe;
    wire [1:0] raw_dqm, raw_ba;
    wire [12:0] raw_address;
    wire [15:0] raw_data;
    // MiSTer SDRAM modules take the chips' byte masks from address lines A12/A11
    // (every MiSTer SDRAM controller ties {DQMH,DQML} to SDRAM_A[12:11] and carries
    // the mask there, e.g. MiSTer PSX rtl/sdram.sv). The donor controller only drives
    // its separate DQM outputs and leaves A12/A11 low on WRITE, so on hardware every
    // byte/halfword store wrote the whole 32-bit word (boot hang: the BIOS's byte-built
    // game filename read back empty). During both write data beats (raw_oe) A12/A11
    // carry the beat's mask; columns use A0-A9 only, so the column command is intact.
    // Otherwise the address is unchanged: READ columns keep A12/A11 low (DQM read
    // latency is satisfied because the donor never issues ACTIVE inside a read burst).
    wire [12:0] mister_address = raw_oe ? {raw_dqm[1], raw_dqm[0], raw_address[10:0]} : raw_address;
    wire [1:0] mister_dqm = mister_address[12:11];
    assign sdram_clk=REGISTERED_IO ? clk : raw_clk;
    generate if(REGISTERED_IO) begin : registered_pins
        // Prepare pins on the opposite edge before the forwarded rising clock.
        // Startup CKE/NOP is explicit; controller reset flows on the next edge.
        initial begin
            sdram_cke=0;sdram_cs_n=1;sdram_ras_n=1;sdram_cas_n=1;sdram_we_n=1;
            sdram_dqm=3;sdram_ba=0;sdram_address=0;sdram_data_out=0;sdram_data_oe=0;
        end
        // Launch on the master-clock rising edge: SDRAM_CLK is shifted +7.805 ns, so the
        // forwarded edge that samples these pins lands ~1.5 cycles later with positive
        // setup/hold (a falling-edge launch left only ~2 ns of setup in STA).
        always_ff @(posedge clk) begin
            sdram_cke<=raw_cke;sdram_cs_n<=raw_cs_n;sdram_ras_n<=raw_ras_n;
            sdram_cas_n<=raw_cas_n;sdram_we_n<=raw_we_n;
            sdram_ba<=raw_ba;sdram_address<=mister_address;sdram_dqm<=mister_dqm;
            sdram_data_out<=raw_data;sdram_data_oe<=raw_oe;
        end
    end else begin : legacy_pins
        always_comb begin
            sdram_cke=raw_cke;sdram_cs_n=raw_cs_n;sdram_ras_n=raw_ras_n;
            sdram_cas_n=raw_cas_n;sdram_we_n=raw_we_n;sdram_dqm=mister_dqm;
            sdram_ba=raw_ba;sdram_address=mister_address;
            sdram_data_out=raw_data;sdram_data_oe=raw_oe;
        end
    end endgenerate
    logic [2:0][1:0] cache_valid;
    logic [2:0] replacement;
    logic [19:0] cache_tag [0:2][0:1];
    logic [31:0] cache_data [0:2][0:1][0:7];
    logic filling, issued, fill_slot;
    logic [4:0] initialization_guard;
    logic [1:0] fill_way;
    // Line fills pipeline their eight reads like the GPU burst (fill_next = next word to issue,
    // fill_index = next word to arrive; issued = all eight issued): ~25 instead of ~64 clocks.
    logic [2:0] fill_index, fill_next, wanted_word;
    logic [31:0] fill_base, local_data;
    wire [1:0] cache_way=req_target[1:0]-2'd1;
    wire cache_hit0=mapped && cache_valid[cache_way][0] && cache_tag[cache_way][0]==physical_address[24:5];
    wire cache_hit1=mapped && cache_valid[cache_way][1] && cache_tag[cache_way][1]==physical_address[24:5];
    wire cache_hit=cache_hit0 || cache_hit1;
    wire hit_slot=!cache_hit0 && cache_hit1;
    // Word of each way selected by the offset only (early); the tag-compare result hit_slot picks the slot last,
    // so its 200+ fanout is one 2:1 level from local_data instead of three.
    wire [31:0] way_word0=cache_data[cache_way][0][req_offset[4:2]];
    wire [31:0] way_word1=cache_data[cache_way][1][req_offset[4:2]];
    wire victim=!cache_valid[cache_way][0] ? 1'b0 :
        (!cache_valid[cache_way][1] ? 1'b1 : replacement[cache_way]);
    wire mapped = req_target >= 1 && req_target <= 3 &&
        req_offset[31:23] == 0 && req_offset[1:0] == 0;
    wire empty_write = req_write && req_strobe == 0;
    always_ff @(posedge clk) begin
        texture_snoop_valid<=!reset && req_valid && req_ready && req_write && mapped && req_target==2;
        texture_snoop_line<=req_offset[22:5];
    end
    // Burst engine state.
    logic bursting, burst_is_write, burst_prefer;
    logic [3:0] burst_issue, burst_complete;
    logic [31:0] burst_base;
    logic [7:0][31:0] burst_data;
    logic [7:0][3:0] burst_strobe;
    // The donor commits to a request (ACTIVATE/PRECHARGE toward its row, read or write)
    // as soon as it is presented and issues the column command with whatever address is
    // presented at accept time. A presented word request must therefore stay until it is
    // accepted: a burst preempting it read the burst's column from the word request's row
    // (burst word 0 returned work-RAM data: hardware black screen).
    logic word_presented;
    wire burst_start = !reset && !busy && !word_presented && burst_valid && (burst_prefer || !req_valid || burst_urgent);
    assign burst_ready = burst_start;
    wire [2:0] burst_slot = burst_issue[2:0];
    wire burst_word_skip = bursting && burst_is_write && burst_issue!=4'd8 && burst_strobe[burst_slot]==4'b0;
    wire burst_issue_active = bursting && burst_issue!=4'd8 && !burst_word_skip;
    wire device_request = !reset && !bursting && !burst_start && ((req_valid && !busy && mapped && !empty_write && (req_write || !cache_hit)) || (busy && filling && !issued));
    always_comb begin
        physical_address = {9'b0,req_offset[22:0]};
        case (req_target)
            2: physical_address[24:23] = 2'b01;
            3: physical_address[24:23] = 2'b10;
            default: physical_address[24:23] = 2'b00;
        endcase
    end
    assign req_ready = !reset && !busy && !burst_start && (!mapped || empty_write || (!req_write && cache_hit) || controller_accept);
    // A starting burst presents its first word in the start cycle (one clock sooner to the
    // controller, which leaves IDLE for the row/command on presentation).
    assign controller_address=bursting ? burst_base+{27'b0,burst_slot,2'b00} :
        burst_start ? {7'b0,burst_region?2'b10:2'b01,burst_line,5'b0} :
        busy && filling ? fill_base+{27'b0,fill_next,2'b00} :
        (req_write ? physical_address : {physical_address[31:5],5'b0});
    // ADDR_W counts halfword address bits: 24 gives 32 MiB, 13 row bits,
    // four banks and 512 halfword columns. 86 MHz rounds the physical 85.90908
    // MHz upward; the donor's integer-nanosecond timing rounds conservatively.
    sdram_axi_core #(.SDRAM_MHZ(86), .SDRAM_ADDR_W(24),
        // Legacy inverted-clock diagnosis uses the donor's two input stages.
        // Registered pins add a full input stage and launch commands on the
        // opposite edge before an in-phase clock: acknowledge one edge later.
        .SDRAM_COL_W(9), .SDRAM_READ_LATENCY(REGISTERED_IO ? 5 : 3)) controller (
        .clk_i(clk), .rst_i(reset),
        .inport_wr_i(bursting ? (burst_is_write && burst_issue_active ? burst_strobe[burst_slot] : 4'b0) :
                     burst_start ? (burst_write ? burst_wstrobe[0] : 4'b0) :
                     (device_request && !busy && req_write ? req_strobe : 4'b0)),
        .inport_rd_i(bursting ? (!burst_is_write && burst_issue_active) : burst_start ? !burst_write :
                     (device_request && (busy || !req_write))),
        .inport_len_i(8'b0),
        .inport_addr_i(controller_address), .inport_write_data_i(bursting ? burst_data[burst_slot] : burst_start ? burst_wdata[0] : req_data),
        .inport_accept_o(controller_accept), .inport_ack_o(controller_ack),
        .inport_error_o(controller_error), .inport_read_data_o(controller_data),
        .sdram_data_input_i(sampled_dq), .sdram_clk_o(raw_clk),
        .sdram_cke_o(raw_cke), .sdram_cs_o(raw_cs_n),
        .sdram_ras_o(raw_ras_n), .sdram_cas_o(raw_cas_n),
        .sdram_we_o(raw_we_n), .sdram_dqm_o(raw_dqm),
        .sdram_addr_o(raw_address), .sdram_ba_o(raw_ba),
        .sdram_data_output_o(raw_data), .sdram_data_out_en_o(raw_oe)
    );
    // The pinned donor loads MRS ten cycles before leaving INIT. Observe the
    // actual physical command and wait sixteen cycles (including tMRD) before
    // releasing the board, independently of request target/empty-write bypass.
    always_ff @(posedge clk) begin
        if(reset) begin initialized<=0;initialization_guard<=0;end
        else if(!initialized) begin
            if(sdram_cke && !sdram_cs_n && !sdram_ras_n && !sdram_cas_n && !sdram_we_n)
                initialization_guard<=16;
            else if(initialization_guard!=0) begin
                initialization_guard<=initialization_guard-1'b1;
                if(initialization_guard==1) initialized<=1;
            end
        end
    end
    always_ff @(posedge clk) begin
        if (reset) begin
            busy<=0;local_reply<=0;local_error<=0;local_data<=0;
            filling<=0;issued<=0;fill_way<=0;fill_slot<=0;replacement<=0;fill_index<=0;fill_next<=0;wanted_word<=0;fill_base<=0;
            cache_valid<=0;rsp_valid<=0;rsp_data<=0;rsp_error<=0;
            word_presented<=0;bursting<=0;burst_is_write<=0;burst_prefer<=0;burst_issue<=0;burst_complete<=0;burst_done<=0;
        end else begin
            rsp_valid<=0;burst_done<=0;
            word_presented<=device_request && !controller_accept;
            if(req_valid && req_ready) burst_prefer<=1;
            if(burst_start) begin
                busy<=1;bursting<=1;burst_is_write<=burst_write;burst_prefer<=0;
                burst_issue<=controller_accept && (!burst_write || burst_wstrobe[0]!=4'b0) ? 4'd1 : 4'd0;
                burst_complete<=0;
                burst_base<={7'b0,burst_region?2'b10:2'b01,burst_line,5'b0};
                burst_data<=burst_wdata;burst_strobe<=burst_wstrobe;
                // Keep the word path's line caches coherent with burst writes.
                if(burst_write) for(int slot=0;slot<2;slot=slot+1)
                    if(cache_tag[burst_region?2:1][slot]=={burst_region?2'b10:2'b01,burst_line})
                        cache_valid[burst_region?2:1][slot]<=0;
            end
            if(bursting) begin
                if(burst_word_skip) begin burst_issue<=burst_issue+4'd1;burst_complete<=burst_complete+4'd1;end
                else if(burst_issue_active && controller_accept) burst_issue<=burst_issue+4'd1;
                if(controller_ack) begin
                    if(!burst_is_write) burst_rdata[burst_complete[2:0]]<=controller_data;
                    burst_complete<=burst_complete+4'd1+(burst_word_skip?4'd1:4'd0);
                end
                // Done on the edge that records the last word (not one clock later).
                if(burst_complete+(burst_word_skip?4'd1:4'd0)+(controller_ack?4'd1:4'd0)==4'd8) begin bursting<=0;busy<=0;burst_done<=1;end
            end
            if(req_valid && req_ready) begin
                busy<=1;local_error<=!mapped;
                local_reply<=!mapped || empty_write || (!req_write && cache_hit);
                local_data<=mapped && !req_write && cache_hit ? (hit_slot ? way_word1 : way_word0) : 32'b0;
                filling<=mapped && !req_write && !cache_hit;
                // A fill's first read (word 0) is accepted with the request.
                issued<=mapped && !empty_write && req_write;
                if(mapped && !req_write && !cache_hit) begin
                    fill_way<=cache_way;fill_slot<=victim;fill_index<=0;fill_next<=1;wanted_word<=req_offset[4:2];
                    fill_base<={physical_address[31:5],5'b0};cache_valid[cache_way][victim]<=0;
                end
                // Completed writes keep a matching cached line coherent. The
                // shared owner cannot read it before the physical write reply.
                if(mapped && !req_write && cache_hit) replacement[cache_way]<=!hit_slot;
                for(int slot=0;slot<2;slot=slot+1)
                    if(mapped && req_write && cache_valid[cache_way][slot] && cache_tag[cache_way][slot]==physical_address[24:5])
                        for(int b=0;b<4;b=b+1)
                            if(req_strobe[b]) cache_data[cache_way][slot][req_offset[4:2]][b*8+:8]<=req_data[b*8+:8];
            end
            if(busy && !bursting && filling && !issued && controller_accept) begin
                fill_next<=fill_next+1'b1;
                if(fill_next==7) issued<=1;
            end
            if(busy && local_reply) begin
                busy<=0;local_reply<=0;rsp_valid<=1;rsp_data<=local_data;rsp_error<=local_error;
            end else if(busy && !bursting && controller_ack) begin
                if(filling && !controller_error) begin
                    cache_data[fill_way][fill_slot][fill_index]<=controller_data;
                    if(fill_index==7) begin
                        cache_tag[fill_way][fill_slot]<=fill_base[24:5];cache_valid[fill_way][fill_slot]<=1;replacement[fill_way]<=!fill_slot;
                        busy<=0;filling<=0;rsp_valid<=1;rsp_error<=0;
                        rsp_data<=wanted_word==fill_index ? controller_data : cache_data[fill_way][fill_slot][wanted_word];
                    end else fill_index<=fill_index+1'b1;
                end else begin
                    busy<=0;filling<=0;issued<=0;rsp_valid<=1;
                    rsp_data<=controller_data;rsp_error<=controller_error;
                end
            end
        end
    end
endmodule
