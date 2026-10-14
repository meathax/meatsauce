// SPDX-License-Identifier: GPL-3.0-or-later
// Hardware-correct palette/transparency behavior (vr0_gpu MAME_PALETTE_HACK=0, the shipped default).
// The RTL is checked against explicit expected pixels, and against the pinned MAME oracle only to
// prove that the two renderers differ in exactly the predicted pixels (MAME's 565-domain
// palette-collision nudge and 0xecda "no transparency" sentinel).
#define main gpu_matrix_main
#include "gpu.cpp"
#undef main
#include <fstream>
#include <sstream>

static const u16 BG=0x1234;
static u16 pixel(GpuMemory& m,unsigned x,unsigned y){return m.read_word(y*2048+x*2);}

struct HwCase {
    const char* name; bool fmt16; bool palette; bool set_trans; bool trans_en;
    u32 trans24; unsigned pal_off;
    u32 e[8]; u16 t16[8];
    int hw[8];          // -1 = destination unchanged (transparent)
    unsigned mame_diff; // bit x set => MAME pixel x differs from hardware-correct pixel
};

int main(int argc,char** argv){
    Verilated::commandArgs(argc,argv);
    try{
        Bench b; b.reset(); b.reg(0x8c,true,4|2,1); // render start + dither field 2 (game value 0x06 minus nothing else)
        for(unsigned i=0;i<b.frame.bytes.size();i+=2){b.frame.bytes[i]=BG&255;b.frame.bytes[i+1]=BG>>8;}
        GpuMemory expected; expected.bytes=b.frame.bytes; vr0video_device oracle(b.texture,expected);
        const unsigned font_off=0x6000;
        const u32 ecda_rgb=0x00e89ad0; // rgb565 == 0xecda (MAME NOTRANSCOLOR)
        check(RGB32TO16(ecda_rgb)==0xecda,"ecda fixture colour");
        HwCase cases[]={
          {"A 8bpp key 0x000000, 24-bit-opaque near blacks",false,true,true,true,0x000000,0x800,
           {0x00010101,0x00000000,0x00ff0000,0x01010101,0x00020202,ecda_rgb,0x00ff00ff,0x00ffffff},{},
           {0x0000,-1,0xf800,0x0000,0x0000,0xecda,0xf81f,0xffff},0x39},
          {"B 8bpp transparency disabled (cached palette)",false,true,false,false,0,0x800,
           {0},{},{0x0000,0x0000,0xf800,0x0000,0x0000,0xecda,0xf81f,0xffff},0x39},
          {"C 8bpp key 0xff00ff, 0xfe02fe/0xff00fe opaque",false,true,true,true,0xff00ff,0x801,
           {0x00ff00ff,0x00fe02fe,0x00ff0000,0x00ffffff,0x00010101,ecda_rgb,0x00000000,0x00ff00fe},{},
           {-1,0xf81f,0xf800,0xffff,0x0000,0xecda,0x0000,0xf81f},0xa2},
          {"D 16bpp transparency disabled, 0xecda texels drawn",true,false,false,false,0,0,
           {0},{0x0000,0xecda,0xf81f,0x0001,0xecda,0x1111,0xecdb,0xffff},
           {0x0000,0xecda,0xf81f,0x0001,0xecda,0x1111,0xecdb,0xffff},0x12},
          {"E 16bpp key 0xff00ff unchanged vs MAME",true,false,false,true,0,0,
           {0},{0x0000,0xecda,0xf81f,0x0001,0xecda,0x1111,0xecdb,0xffff},
           {0x0000,0xecda,-1,0x0001,0xecda,0x1111,0xecdb,0xffff},0x00},
        };
        unsigned k=0,diff_pixels=0;
        for(auto& c:cases){
            const unsigned dy=8*k++;
            if(c.palette) for(unsigned i=0;i<8;i++){
                u32 v=c.e[i]; if(&c==&cases[1]) continue; // case B reuses the cached palette
                for(unsigned j=0;j<4;j++) b.texture.bytes[(1024*c.pal_off+i*4+j)&0x7fffff]=v>>(8*j);
            }
            for(unsigned ty=0;ty<8;ty++)for(unsigned tx=0;tx<8;tx++){
                unsigned o=0x300000+(c.fmt16?(ty*8+tx)*2:(ty*8+tx));
                if(c.fmt16){b.texture.bytes[o]=c.t16[tx]&255;b.texture.bytes[o+1]=c.t16[tx]>>8;}
                else b.texture.bytes[o]=tx;
            }
            std::array<u16,32> p{};
            p[0]=0x100|8|0x4000|(c.palette?0x40:0)|(c.set_trans?0x2000:0)|(c.trans_en?4:0);
            p[1]=0;p[2]=dy;p[3]=7;p[4]=dy+7;
            p[23]=c.trans24&0xffff;p[24]=c.trans24>>16;
            p[26]=font_off;p[27]=c.pal_off<<3;p[28]=(c.fmt16?2:1)<<6;
            for(unsigned j=0;j<32;j++)b.texture.write_word(b.d.queue_rear*64+j*2,p[j]);
            oracle.m_draw_dest=b.d.draw_address;
            check(oracle.process_packet(b.d.queue_rear*32)==0,"hw case unexpected flip");
            b.submit(p);
            unsigned mask=0;
            for(unsigned y=0;y<8;y++)for(unsigned x=0;x<8;x++){
                u16 want=c.hw[x]<0?BG:u16(c.hw[x]);
                if(pixel(b.frame,x,dy+y)!=want)
                    throw std::runtime_error(std::string(c.name)+": RTL pixel x="+std::to_string(x)+" y="+std::to_string(y)+" got "+std::to_string(pixel(b.frame,x,dy+y))+" want "+std::to_string(want));
                ++checks;
                if(pixel(b.frame,x,dy+y)!=pixel(expected,x,dy+y)) mask|=1u<<x;
            }
            check(mask==c.mame_diff,std::string(c.name)+": RTL-vs-MAME differing pixel set 0x"+std::to_string(mask)+" != predicted");
            for(unsigned i=0;i<8;i++) if(mask>>i&1) diff_pixels+=8;
            std::cout<<"PASS GPU hw case "<<c.name<<": differs from MAME in mask 0x"<<std::hex<<mask<<std::dec<<"\n";
        }
        // Outside every fixture rectangle the two frames must remain identical.
        check(b.frame.bytes!=expected.bytes,"fixture produced no hardware/MAME difference");
        for(unsigned y=40;y<512;y++)for(unsigned x=0;x<1024;x++) if((y<64||y>=80)&&pixel(b.frame,x,y)!=pixel(expected,x,y))throw std::runtime_error("difference outside fixtures");

        // Real captured crysking palette (private, from scripts/mame_video_usage.lua), if present.
        std::ifstream pal("sim/obj_dir/crysking_palette/collision_palette.bin",std::ios::binary);
        std::ifstream meta("sim/obj_dir/crysking_palette/collision_palette.txt");
        if(pal&&meta){
            std::string line;std::getline(meta,line);auto pos=line.find("trans_color=");
            u32 key=std::stoul(line.substr(pos+12),nullptr,16);
            std::vector<char> raw(1024);pal.read(raw.data(),1024);
            const unsigned pal_off=0x802,dy=64;
            for(unsigned i=0;i<1024;i++)b.texture.bytes[1024*pal_off+i]=raw[i];
            for(unsigned i=0;i<256;i++)b.texture.bytes[0x300000+i]=i;
            std::array<u16,32> p{};
            p[0]=0x100|8|0x4000|0x40|0x2000|4;p[1]=0;p[2]=dy;p[3]=15;p[4]=dy+15;
            p[23]=key&0xffff;p[24]=key>>16;p[26]=font_off;p[27]=pal_off<<3;p[28]=(1<<6)|1|(1<<3);
            for(unsigned j=0;j<32;j++)b.texture.write_word(b.d.queue_rear*64+j*2,p[j]);
            oracle.m_draw_dest=b.d.draw_address;
            check(oracle.process_packet(b.d.queue_rear*32)==0,"real palette unexpected flip");
            b.submit(p);
            unsigned differing=0,collisions=0,skipped=0;
            for(unsigned i=0;i<256;i++){
                u32 e=0;for(unsigned j=0;j<4;j++)e|=u32(uint8_t(raw[i*4+j]))<<(8*j);
                u16 v=RGB32TO16(e),t=RGB32TO16(key);
                bool collision=v==t&&e!=key, same_key=v==t&&e==key;
                bool predicted_diff=collision||v==0xecda;
                u16 hw=pixel(b.frame,i&15,dy+(i>>4)),mame=pixel(expected,i&15,dy+(i>>4));
                if(same_key){check(hw==BG&&mame==BG,"true key entry must stay transparent in both");++skipped;}
                else {check(hw==v,"real palette: RTL pixel is the plain RGB565 entry");}
                check((hw!=mame)==predicted_diff,"real palette: RTL/MAME difference outside the predicted entries");
                differing+=hw!=mame;collisions+=collision;
            }
            std::cout<<"PASS GPU hw real crysking palette (key 0x"<<std::hex<<key<<std::dec<<"): "<<collisions<<" collision entries, "<<skipped<<" true-key entries skipped, "<<differing<<" pixels differ from MAME, all predicted\n";
        } else std::cout<<"SKIP GPU hw real crysking palette fixture (private file sim/obj_dir/crysking_palette/ absent)\n";
        std::cout<<"PASS GPU hardware palette/transparency: "<<checks<<" checks; "<<diff_pixels<<" synthetic pixels intentionally differ from MAME\n";
        return 0;
    }catch(const std::exception& e){std::cerr<<"FAIL GPU hw: "<<e.what()<<"\n";return 1;}
}
