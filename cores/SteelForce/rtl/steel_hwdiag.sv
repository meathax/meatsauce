// SPDX-License-Identifier: GPL-3.0-or-later
// Hardware diagnostic (STEEL_HWDIAG builds only): records what the CPU and GFX
// actually receive from the SDRAM/cache fabric and returns it through the
// index-2 NVRAM upload in place of the save file. Not part of release builds.
// Layout (180 bytes):
//   0-3   "SFD1"
//   4-5   CPU reset releases (BE)        6-7  VS rising edges (BE)
//   8     flags {image_valid,boot_hold,storage_error,nv_error,download_active,persist_hold,board_reset,pause}
//   9     first-trace entries captured
//   10-109  first 20 CPU ROM transactions after the first release: word address (3 B BE), data (2 B BE)
//   110-149 last 8 CPU ROM transactions (ring, frozen when the OSD opens)
//   150     ring write pointer
//   151-172 first 2 GFX transactions: address (3 B BE), data (8 B BE)
//   173-176 longest CPU request-to-ready wait in clocks (BE)
//   177     gfx entries captured   178-179 "OK"
module steel_hwdiag(
    input wire clk,reset,board_reset,osd_status,
    input wire [7:0] flags,
    input wire rom_req,rom_ready,
    input wire [18:0] rom_word_addr,
    input wire [15:0] rom_data,
    input wire gfx_req,gfx_ready,
    input wire [22:0] gfx_addr,
    input wire [63:0] gfx_data,
    input wire vs,
    input wire [26:0] ioctl_addr,
    output reg [7:0] dout,
    output reg upload_req=0,
    input wire ioctl_upload
);
    reg [7:0] mem[0:179];
    reg [15:0] releases=0,frames=0;
    reg [4:0] first_n=0;
    reg [2:0] ring_ptr=0;
    reg [1:0] gfx_n=0;
    reg [31:0] wait_now=0,wait_max=0;
    reg reset_last=1,vs_last=0,osd_last=0,frozen=0,started=0;
    reg rom_hit_last=0,gfx_hit_last=0;
    reg [18:0] rom_addr_last=0;
    reg [22:0] gfx_addr_last=0;
    wire rom_hit=rom_req && rom_ready;
    wire rom_event=rom_hit && (!rom_hit_last || rom_word_addr!=rom_addr_last);
    wire gfx_hit=gfx_req && gfx_ready;
    wire gfx_event=gfx_hit && (!gfx_hit_last || gfx_addr!=gfx_addr_last);
    integer i;
    initial for(i=0;i<180;i=i+1)mem[i]=8'h00;
    always @(posedge clk)begin
        dout<=ioctl_addr<180 ? mem[ioctl_addr[7:0]] : 8'hff;
        reset_last<=board_reset;vs_last<=vs;osd_last<=osd_status;
        rom_hit_last<=rom_hit;rom_addr_last<=rom_word_addr;
        gfx_hit_last<=gfx_hit;gfx_addr_last<=gfx_addr;
        if(reset)begin
            releases<=0;frames<=0;first_n<=0;ring_ptr<=0;gfx_n<=0;
            wait_now<=0;wait_max<=0;frozen<=0;started<=0;upload_req<=0;
        end else begin
            if(reset_last && !board_reset)begin releases<=releases+1'b1;started<=1;end
            if(vs && !vs_last)frames<=frames+1'b1;
            if(osd_status && !osd_last)begin frozen<=1;upload_req<=1;end
            if(ioctl_upload)upload_req<=0;
            if(!osd_status && osd_last)frozen<=0;
            if(rom_req && !rom_ready)wait_now<=wait_now+1;
            else begin
                if(wait_now>wait_max)wait_max<=wait_now;
                wait_now<=0;
            end
            if(started && rom_event)begin
                if(first_n<20)begin
                    mem[10+first_n*5]<={5'b0,rom_word_addr[18:16]};
                    mem[11+first_n*5]<=rom_word_addr[15:8];
                    mem[12+first_n*5]<=rom_word_addr[7:0];
                    mem[13+first_n*5]<=rom_data[15:8];
                    mem[14+first_n*5]<=rom_data[7:0];
                    first_n<=first_n+1'b1;
                end
                if(!frozen)begin
                    mem[110+ring_ptr*5]<={5'b0,rom_word_addr[18:16]};
                    mem[111+ring_ptr*5]<=rom_word_addr[15:8];
                    mem[112+ring_ptr*5]<=rom_word_addr[7:0];
                    mem[113+ring_ptr*5]<=rom_data[15:8];
                    mem[114+ring_ptr*5]<=rom_data[7:0];
                    ring_ptr<=ring_ptr+1'b1;
                end
            end
            if(started && gfx_event && gfx_n<2)begin
                mem[151+gfx_n*11]<={1'b0,gfx_addr[22:16]};
                mem[152+gfx_n*11]<=gfx_addr[15:8];
                mem[153+gfx_n*11]<=gfx_addr[7:0];
                mem[154+gfx_n*11]<=gfx_data[63:56];
                mem[155+gfx_n*11]<=gfx_data[55:48];
                mem[156+gfx_n*11]<=gfx_data[47:40];
                mem[157+gfx_n*11]<=gfx_data[39:32];
                mem[158+gfx_n*11]<=gfx_data[31:24];
                mem[159+gfx_n*11]<=gfx_data[23:16];
                mem[160+gfx_n*11]<=gfx_data[15:8];
                mem[161+gfx_n*11]<=gfx_data[7:0];
                gfx_n<=gfx_n+1'b1;
            end
            if(!frozen)begin
                mem[0]<="S";mem[1]<="F";mem[2]<="D";mem[3]<="1";
                mem[4]<=releases[15:8];mem[5]<=releases[7:0];
                mem[6]<=frames[15:8];mem[7]<=frames[7:0];
                mem[8]<=flags;mem[9]<={3'b0,first_n};
                mem[150]<={5'b0,ring_ptr};
                mem[173]<=wait_max[31:24];mem[174]<=wait_max[23:16];
                mem[175]<=wait_max[15:8];mem[176]<=wait_max[7:0];
                mem[177]<={6'b0,gfx_n};mem[178]<="O";mem[179]<="K";
            end
        end
    end
endmodule
