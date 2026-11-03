// SPDX-License-Identifier: GPL-3.0-or-later
// Canonical19MiB stream: program1MiB, materialized graphics16MiB, samples2MiB.
// Work RAM is cleared after download. Never release CPU after a short/gapped image.
module penguin_rom_loader(
    input logic clk,reset,phase_reset,download,wr,
    input logic [26:0] addr,input logic [7:0] data,
    output logic wait_request,ready,error,
    output logic ddr_wr,output logic [25:0] ddr_addr,
    output logic [7:0] ddr_data,input logic ddr_wait,ddr_idle,
    output logic [24:0] gfx_addr,
    (* altera_attribute = "-name ALLOW_SYNCH_CTRL_USAGE OFF" *) output logic [63:0] gfx_data,
    output logic gfx_req,input logic gfx_ack,input logic memory_ready
);
    localparam logic [26:0] PROGRAM_END=27'h0100000,GFX_END=27'h1100000,IMAGE_END=27'h1300000;
    localparam logic [25:0] WORK_END=26'h1350000;
    logic download_d=0,seen=0,clearing=0,finishing=0;
    logic [26:0] next_addr=0;
    logic [25:0] clear_addr=0;
    logic [63:0] pack=0;
    wire is_gfx=addr>=PROGRAM_END && addr<GFX_END;
    wire gfx_busy=gfx_req!=gfx_ack;
    // Registered producer: the eighth byte can assert downstream wait one
    // cycle after receipt, so stall until the current DDR byte is delivered.
    assign wait_request=!memory_ready || gfx_busy || clearing || finishing || (!is_gfx && (ddr_wait || ddr_wr));
    always_ff @(posedge clk)begin
        ddr_wr<=0;
        if(reset)begin
            download_d<=0;seen<=0;clearing<=0;finishing<=0;next_addr<=0;
            gfx_req<=0;gfx_addr<=0;pack<=0;ready<=0;error<=0;
            ddr_addr<=0;ddr_data<=0;clear_addr<=IMAGE_END;
        end else begin
            download_d<=download;
            if(download && !download_d)begin
                seen<=0;next_addr<=0;ready<=0;error<=0;pack<=0;
                // A new image owns readiness; abandon the old clear/completion
                // sequence while its already-issued transport writes drain.
                clearing<=0;finishing<=0;
            end
            if(download && wr && !wait_request)begin
                seen<=1;
                if(addr!=(download_d?next_addr:27'd0) || addr>=IMAGE_END)error<=1;
                next_addr<=addr+1'b1;
                if(is_gfx)begin
                    // Graphics source bytes are big-endian within each16-bit word.
                    pack[{addr[2:1],4'b0000}+(addr[0]?0:8)+:8]<=data;
                    if(addr[2:0]==7)begin
                        gfx_addr<=addr-PROGRAM_END-7;
                        // Last byte belongs in LOW byte of finalword, notbits63:56.

                        gfx_req<=~gfx_req;
                    end
                end else begin
                    ddr_wr<=1;ddr_addr<=addr[25:0];ddr_data<=data;
                end
            end
            if(!download && download_d)begin
                ready<=0;
                if(!seen || next_addr!=IMAGE_END || error)error<=1;
                else begin clearing<=1;clear_addr<=IMAGE_END;end
            end
            if(clearing && !download && !ddr_wait && !ddr_wr && !gfx_busy)begin
                ddr_wr<=1;ddr_addr<=clear_addr;ddr_data<=0;
                if(clear_addr==WORK_END-1)begin clearing<=0;finishing<=1;end
                else clear_addr<=clear_addr+1'b1;
            end
            if(finishing && !download && !ddr_wr && ddr_idle && !gfx_busy)begin finishing<=0;ready<=!error;end
            if(phase_reset)begin
                gfx_req<=0;gfx_addr<=0;pack<=0;ddr_wr<=0;
                // A soft reset preserves the loaded image; a requested new
                // download restarts its byte stream after transport resync.
                if(download)begin download_d<=0;seen<=0;next_addr<=0;ready<=0;error<=0;clearing<=0;finishing<=0;end
            end
        end
    end
// BEGIN GFX_CAPTURE_PARALLEL: procedural-if truth and reset priority.
    wire gfx_capture_reset = (reset === 1'b1) || (phase_reset === 1'b1);
    wire gfx_capture_commit = !gfx_capture_reset &&
        ((download && wr && !wait_request && is_gfx && (addr[2:0]==7)) === 1'b1);
    always_ff @(posedge clk) begin
        unique case (1'b1)
            gfx_capture_reset: gfx_data <= 64'd0;
            gfx_capture_commit: gfx_data <= {pack[63:56],data,pack[47:0]};
            default: gfx_data <= gfx_data;
        endcase
    end
// END GFX_CAPTURE_PARALLEL
endmodule
