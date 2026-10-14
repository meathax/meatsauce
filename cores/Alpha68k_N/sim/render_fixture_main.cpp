#include "Valpha68kn_render_fixture.h"
#include "verilated.h"
#include "sdram_model.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>

std::vector<uint8_t> read(const std::filesystem::path& path) {
    std::ifstream f(path,std::ios::binary);
    if(!f) throw std::runtime_error("cannot read "+path.string());
    return {(std::istreambuf_iterator<char>(f)),{}};
}
int main(int argc,char** argv) {
    try {
        if(argc<6) throw std::runtime_error("usage: render_fixture download.bin sprites.bin background output flip [oracle.rgb]");
        Verilated::commandArgs(argc,argv);
        auto image=read(argv[1]),ram=read(argv[2]);
        if(image.size()!=0xa0000 || ram.size()!=8192) throw std::runtime_error("invalid fixture size");
        bool sting=image[5]==2,flip=std::stoul(argv[5])!=0;
        unsigned background=std::stoul(argv[3])&255;
        std::filesystem::path output(argv[4]);std::filesystem::create_directories(output);
        std::vector<uint8_t> expected(256*224*3),actual(expected.size());
        auto palette=[&](unsigned index) {
            return ((image[0x30100+index]&15)*17<<16) |
                ((image[0x30200+index]&15)*17<<8) | (image[0x30300+index]&15)*17;
        };
        auto put=[&](std::vector<uint8_t>& rgb,unsigned x,unsigned y,uint32_t value) {
            unsigned p=((y-16)*256+x)*3;rgb[p]=value>>16;rgb[p+1]=value>>8;rgb[p+2]=value;
        };
        for(unsigned y=16;y<240;y++) for(unsigned x=0;x<256;x++) put(expected,x,y,palette(background));
        auto word=[&](unsigned address) {return (unsigned(ram[address*2])<<8)|ram[address*2+1];};
        const unsigned groups[]={2,3,1},offsets[]={0x800,0xc00,0x400};
        const unsigned xbits[]={67,66,65,64,3,2,1,0};
        unsigned banks=0,boundary_codes=0,color_ff_tiles=0;
        // Direct transcription of the pinned MAME strip loops/layouts/readbit,
        // independent of the RTL's row selection and physical address mapping.
        for(unsigned g=0;g<3;g++) for(unsigned off=0;off<0x400;off+=0x20) {
            unsigned pos=word(off+groups[g]);
            int mx=pos&255,my=(-(pos>>8))&255;
            if(sting && mx>248) mx-=256;
            if(flip) my=249-my;
            for(unsigned i=0;i<32;i++) {
                unsigned data=word(off+offsets[g]+i);
                if(data!=(sting?0x40:0x20)) {
                    unsigned bank=(data>>10)&3,tile=data&0x3ff,color;
                    if(sting) color=((data>>7)&0x18)|((data>>13)&7);
                    else {
                        color=image[0x31000+((data>>1)&0x1000)+(data&0xffc)+((data>>14)&3)];
                        bank+=((data>>13)&4);tile+=((data>>3)&0x400);
                    }
                    if(my<=239 && my+7>=16) {
                        banks|=1u<<bank;
                        boundary_codes|=tile==0?1:tile==1023?2:tile==1024?4:tile==2047?8:0;
                        if(color==255) color_ff_tiles++;
                    }
                    unsigned base=sting ? (bank&2?0x10000:0) : (bank/2)*0x18000;
                    unsigned plane[]={bank&1?0u:4u,0,0};
                    unsigned other=sting ? (bank==1?0x28000:bank==3?0x10000:0x8000) :
                        (bank&1?0x10000:0x8000);
                    plane[1]=other*8;plane[2]=other*8+4;
                    bool fy=((data>>12)&1)^flip;
                    if(color!=255 || !sting) for(unsigned iy=0;iy<8;iy++) {
                        int y=my+iy;if(y<16 || y>=240) continue;
                        for(unsigned ix=0;ix<8;ix++) {
                            int x=mx+ix;if(x<0 || x>=256) continue;
                            unsigned pen=0;
                            for(unsigned p=0;p<3;p++) {
                                unsigned bit=base*8+tile*128+plane[p]+(fy?7-iy:iy)*8+xbits[flip?7-ix:ix];
                                if(image[0x40000+bit/8]&(0x80>>(bit%8))) pen|=1u<<(2-p);
                            }
                            if(pen) {
                                unsigned index=(color%32)*8+pen;
                                unsigned indirect=((image[0x30500+index]&15)<<4)|(image[0x30400+index]&15);
                                put(expected,x,y,palette(indirect));
                            }
                        }
                    }
                }
                my=(my+(flip?-8:8))&255;
            }
        }
        Valpha68kn_render_fixture top;
        Sdram device;
        top.clk=0;top.reset=1;top.load_wr=0;top.strip_wr=0;top.line_start=0;
        top.refresh=0;top.flip=flip;top.stingray=sting;top.background=background;
        top.load_addr=0;top.load_data=0;top.strip_write_addr=0;top.strip_din=0;
        top.line_y=0;top.video_y=0;top.video_x=0;top.sdram_dq=0;
        top.eval();for(unsigned i=0;i<2;i++) {top.clk=1;top.eval();top.clk=0;top.eval();}
        uint64_t ticks=0;
        auto tick=[&]() {
            top.clk=0;top.eval();device.sample(top);
            top.sdram_dq=device.dq;top.refresh=(ticks%3072)==3071;top.eval();
            top.clk=1;top.eval();++ticks;
        };
        for(unsigned i=0;i<10000;i++) tick();
        top.reset=0;
        for(unsigned i=0;!top.initialized;i++) {
            if(i>30000) throw std::runtime_error("SDRAM initialization timeout");
            tick();
        }
        for(unsigned i=0;i<4096;i++) {
            top.strip_wr=1;top.strip_write_addr=i;top.strip_din=word(i);tick();
        }
        top.strip_wr=0;
        for(unsigned a=0;a<image.size();a+=2) {
            top.load_wr=0;unsigned wait=0;
            while(top.load_wait) {tick();if(++wait>10000) throw std::runtime_error("loader wait timeout");}
            top.load_wr=1;top.load_addr=a;top.load_data=image[a]|(image[a+1]<<8);tick();
        }
        top.load_wr=0;
        for(unsigned i=0;top.load_busy;i++) {
            if(i>10000) throw std::runtime_error("loader drain timeout");tick();
        }
        uint64_t render_reads=device.reads;
        for(unsigned y=15;y<240;y++) for(unsigned cycle=0;cycle<3072;cycle++) {
            top.line_start=cycle==0;top.line_y=y;top.video_y=y;top.video_x=(cycle/8)&255;
            tick();
            if(y>=16 && cycle%8==3 && cycle/8<256) put(actual,cycle/8,y,top.rgb);
        }
        unsigned mismatches=0,first=0;
        for(unsigned p=0;p<actual.size();p+=3) if(actual[p]!=expected[p] ||
            actual[p+1]!=expected[p+1] || actual[p+2]!=expected[p+2]) {
            if(!mismatches) first=p/3;mismatches++;
        }
        unsigned oracle_mismatches=0;
        bool oracle_compared=argc>6 && std::string(argv[6])!="-";
        if(oracle_compared) {
            auto oracle=read(argv[6]);
            if(oracle.size()!=expected.size()) throw std::runtime_error("oracle RGB dimensions differ");
            for(unsigned p=0;p<oracle.size();p+=3) if(oracle[p]!=expected[p] ||
                oracle[p+1]!=expected[p+1] || oracle[p+2]!=expected[p+2]) oracle_mismatches++;
        }
        std::ofstream(output/"actual.rgb",std::ios::binary).write(reinterpret_cast<char*>(actual.data()),actual.size());
        std::ofstream(output/"expected.rgb",std::ios::binary).write(reinterpret_cast<char*>(expected.data()),expected.size());
        bool pass=mismatches==0 && oracle_mismatches==0 && top.deadline_misses==0 && top.row_overflows==0 && top.completed_lines==225 && top.worst_line_cycles<3072;
        std::cout<<"{\"scope\":\"isolated strip/palette/SDRAM fixture; no CPU acceptance\""
            <<",\"profile\":"<<unsigned(image[5])<<",\"flip\":"<<(flip?"true":"false")
            <<",\"pixels\":57344,\"pixel_mismatches\":"<<mismatches
            <<",\"first_x\":"<<first%256<<",\"first_y\":"<<first/256+16
            <<",\"oracle_compared\":"<<(oracle_compared?"true":"false")
            <<",\"oracle_mismatches\":"<<oracle_mismatches
            <<",\"worst_line_cycles\":"<<top.worst_line_cycles
            <<",\"completed_lines\":"<<top.completed_lines
            <<",\"deadline_misses\":"<<top.deadline_misses
            <<",\"row_overflows\":"<<top.row_overflows
            <<",\"banks_mask\":"<<banks<<",\"boundary_codes_mask\":"<<boundary_codes
            <<",\"color_ff_tiles\":"<<color_ff_tiles
            <<",\"read_pairs\":"<<device.reads-render_reads
            <<",\"result\":\""<<(pass?"pass":"fail")<<"\"}\n";
        top.final();return pass?0:1;
    } catch(const std::exception& e) {std::cerr<<e.what()<<'\n';return 2;}
}
