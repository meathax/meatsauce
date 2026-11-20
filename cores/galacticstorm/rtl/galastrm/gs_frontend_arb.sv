// SPDX-License-Identifier: GPL-3.0-or-later
// Held-request 16-bit memory arbiter for main CPU, sound CPU and sampler.
// Physical layout follows plan.md; the actual SDRAM controller is separate.
module gs_frontend_arb #(parameter SAMPLE_LINES=0,LINE_WRITES=0)(
    input logic clk,reset,
    input logic main_req,main_write,input logic [23:0] main_addr,
    input logic [15:0] main_wdata,input logic [1:0] main_be,
    input wire main_write_line,input wire [63:0] main_wline,
    output logic main_ack,output logic [15:0] main_rdata,
    input logic sound_req,sound_write,input logic [23:0] sound_addr,
    input logic [15:0] sound_wdata,input logic [1:0] sound_be,
    output logic sound_ack,output logic [15:0] sound_rdata,
    input logic sample_req,input logic [22:3] sample_addr,
    output logic sample_busy,sample_valid,output logic [63:0] sample_line,
    output logic mem_req,mem_write,output logic [24:0] mem_addr,
    output logic [15:0] mem_wdata,output logic [1:0] mem_be,
    output wire mem_write_line,output wire [63:0] mem_wline,
    input logic mem_ack,input logic [15:0] mem_rdata,
    input wire [63:0] mem_rline
);
    typedef enum logic [1:0] {IDLE,BUSY,DROP,SAMPLE_GAP} phase_t;
    phase_t phase;
    logic [1:0] owner,next_owner,sample_word;
    logic pending_sample;
    logic [22:3] pending_addr;
    logic [63:0] line;
    logic [24:0] address;
    logic write_bus,write_line;
    logic [63:0] wline;
    logic [15:0] wdata;
    logic [1:0] be;
    logic [1:0] choice;
    logic available;
    wire [63:0] sample_rline;
    assign sample_rline={mem_rline[55:48],mem_rline[63:56],mem_rline[39:32],mem_rline[47:40],
                         mem_rline[23:16],mem_rline[31:24],mem_rline[7:0],mem_rline[15:8]};
    function automatic logic [24:0] main_physical(input logic [23:0] a);
        case(a[23:20])
            4'h0: main_physical={1'b0,a};
            4'h2: main_physical=25'h1400000+{8'd0,a[16:0]};
            4'h3: main_physical=25'h1420000+{11'd0,a[13:0]};
            4'h8: main_physical=25'h1430000+{9'd0,a[15:0]};
            4'hd: main_physical=25'h1440000+{9'd0,a[15:0]};
            default: main_physical=25'h1ffffff;
        endcase
    endfunction
    function automatic logic [24:0] sound_physical(input logic [23:0] a);
        if(a[23:20]==4'hc) sound_physical=25'h100000+{6'd0,a[18:0]};
        else sound_physical=25'h1450000+{9'd0,a[15:0]};
    endfunction
    always_comb begin
        choice=next_owner;available=0;
        case(next_owner)
            0: begin
                if(main_req) begin choice=0;available=1;end
                else if(sound_req) begin choice=1;available=1;end
                else if(pending_sample) begin choice=2;available=1;end
            end
            1: begin
                if(sound_req) begin choice=1;available=1;end
                else if(pending_sample) begin choice=2;available=1;end
                else if(main_req) begin choice=0;available=1;end
            end
            default: begin
                if(pending_sample) begin choice=2;available=1;end
                else if(main_req) begin choice=0;available=1;end
                else if(sound_req) begin choice=1;available=1;end
            end
        endcase
    end
    assign mem_req=phase==BUSY;
    assign mem_addr=address;
    assign mem_write=write_bus;
    assign mem_write_line=LINE_WRITES && write_line;
    assign mem_wline=LINE_WRITES ? wline : 64'b0;
    assign mem_wdata=wdata;
    assign mem_be=be;
    assign main_ack=phase==BUSY && owner==0 && mem_ack;
    assign sound_ack=phase==BUSY && owner==1 && mem_ack;
    assign main_rdata=mem_rdata;
    assign sound_rdata=mem_rdata;
    assign sample_busy=pending_sample || (phase!=IDLE && owner==2);
    always_ff @(posedge clk) begin
        sample_valid<=0;
        if(reset) begin
            phase<=IDLE;owner<=0;next_owner<=0;pending_sample<=0;
            pending_addr<=0;sample_word<=0;line<=0;sample_line<=0;
            address<=0;write_bus<=0;wdata<=0;be<=0;write_line<=0;wline<=0;
        end else begin
            if(sample_req && !sample_busy) begin pending_sample<=1;pending_addr<=sample_addr;end
            case(phase)
                IDLE: if(available) begin
                    phase<=BUSY;owner<=choice;write_line<=0;wline<=0;
                    if(choice==0) begin
                        address<=main_physical(main_addr);write_bus<=main_write;wdata<=main_wdata;be<=main_be;
                        write_line<=LINE_WRITES && main_write && main_write_line;
                        wline<=LINE_WRITES ? main_wline : 64'b0;
                    end else if(choice==1) begin
                        address<=sound_physical(sound_addr);write_bus<=sound_write;wdata<=sound_wdata;be<=sound_be;
                    end else begin
                        address<=25'h800000+{2'd0,pending_addr,3'b0};
                        write_bus<=0;wdata<=0;be<=3;sample_word<=0;pending_sample<=0;
                    end
                end
                BUSY: if(mem_ack) begin
                    if(owner==2 && SAMPLE_LINES) begin
                        // The aligned eight-byte sample line is already fetched
                        // by the SDRAM burst. Retire it in one held transaction.
                        sample_line<=sample_rline;sample_valid<=1;
                        phase<=IDLE;next_owner<=0;
                    end else if(owner==2) begin
                        // ES5505 line convention: byte k occupies bits 8k+:8.
                        line[16*sample_word +: 16]<={mem_rdata[7:0],mem_rdata[15:8]};
                        if(sample_word==3) begin
                            sample_line<={mem_rdata[7:0],mem_rdata[15:8],line[47:0]};
                            sample_valid<=1;phase<=IDLE;next_owner<=0;
                        end else begin
                            sample_word<=sample_word+1'b1;address<=address+25'd2;phase<=SAMPLE_GAP;
                        end
                    end else begin phase<=DROP;next_owner<=owner+1'b1;end
                end
                DROP: if((owner==0 && !main_req) || (owner==1 && !sound_req)) phase<=IDLE;
                SAMPLE_GAP: phase<=BUSY;
            endcase
        end
    end
endmodule
