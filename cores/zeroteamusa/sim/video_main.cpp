#include "Vzero_video_top.h"
#include "verilated.h"
#include <vector>
#include <fstream>
#include <array>
#include <iostream>
#include <stdexcept>

static std::vector<uint8_t> load(const char* name) {
    std::ifstream f(std::string("roms/regions/")+name+".bin",std::ios::binary);
    if(!f)throw std::runtime_error("Missing graphics region");
    return {(std::istreambuf_iterator<char>(f)),{}};
}
int main(int argc,char** argv) {
    Verilated::commandArgs(argc,argv);
    auto chars=load("chars"),tiles=load("tiles"),sprites=load("sprites");
    Vzero_video_top t; t.rom_valid=0; t.rom_data=0;
    bool flip=argc>1 && std::string(argv[1])=="--flip";
    t.flip=flip;
    bool pending=false,previous_request=false; uint64_t due=0,requests=0;
    // Sprite row port: two native LE32 halves, 3 and 5 clocks after the request.
    bool spending=false,sprevious=false; uint64_t sdue=0; uint32_t saddress=0;
    uint32_t address=0; uint8_t kind=0;
    std::vector<uint8_t> image(320*256*3);
    uint64_t pixels=0,frame_pixels=0,frames=0,pixel_count=0;
    uint64_t last_pixel=0;
    uint64_t last_frame=0,frame_period=0;
    bool regular_frames=true;
    bool regular=true;
    for(uint64_t c=0;c<60+4*512*282*12;++c) {
        t.reset=c<60; t.clk=0; t.eval(); t.rom_valid=0;
        if(!t.reset && t.rom_request && !previous_request) {
            if(pending)throw std::runtime_error("Overlapping graphics ROM transaction");
            pending=true; due=c+3; address=t.rom_address; kind=t.rom_kind; ++requests;
        }
        previous_request=t.rom_request;
        t.sprite_valid=0;
        if(!t.reset && t.sprite_request && !sprevious) {
            if(spending)throw std::runtime_error("Overlapping sprite ROM transaction");
            spending=true; sdue=c+3; saddress=t.sprite_address; ++requests;
        }
        sprevious=t.sprite_request;
        if(spending && (c==sdue || c==sdue+2)) {
            uint32_t o=saddress+(c==sdue?0:4);
            if(o+3>=sprites.size())throw std::runtime_error("Sprite ROM address outside region");
            t.sprite_data=uint32_t(sprites[o])|(uint32_t(sprites[o+1])<<8)|(uint32_t(sprites[o+2])<<16)|(uint32_t(sprites[o+3])<<24);
            t.sprite_half=c!=sdue; t.sprite_valid=t.sprite_request;
            if(c==sdue+2) spending=false;
        }
        if(pending && c==due) {
            const auto& bytes=kind==4?chars:(kind==3?sprites:tiles);
            if(address+3>=bytes.size())throw std::runtime_error("Graphics ROM address outside region");
            uint32_t first=uint32_t(bytes[address])|(uint32_t(bytes[address+1])<<8);
            uint32_t second=uint32_t(bytes[address+2])|(uint32_t(bytes[address+3])<<8);
            // Tile/char bridge emits {first_word,second_word}; sprite DDR emits native LE32.
            t.rom_data=kind==3 ? (first|(second<<16)) : ((first<<16)|second);
            t.rom_valid=1; pending=false;
        }
        t.eval();
        if(!t.reset && t.ce_pixel) {
            if(pixel_count && c-last_pixel!=12)regular=false;
            last_pixel=c; ++pixel_count;
        }
        t.clk=1; t.eval();
        if(!t.reset && t.pixel_strobe && t.pixel_display) {
            if(t.pixel_x==0 && t.pixel_y==0) {
                if(last_frame){ frame_period=c-last_frame; if(frame_period!=512*282*12)regular_frames=false; }
                last_frame=c; ++frames; pixels=frame_pixels; frame_pixels=0;
            }
            if(t.pixel_x>=320 || t.pixel_y>=256)throw std::runtime_error("Invalid output coordinate");
            size_t i=(t.pixel_y*320+t.pixel_x)*3;
            image[i]=t.r; image[i+1]=t.g; image[i+2]=t.b; ++frame_pixels;
        }
    }
    t.final();
    std::ofstream f(flip?"sim/results/rtl-logo-flip.ppm":"sim/results/rtl-logo.ppm",std::ios::binary);
    f<<"P6\n320 256\n255\n"; f.write(reinterpret_cast<char*>(image.data()),image.size());
    std::ofstream meta(flip?"sim/results/video-fixture-flip.json":"sim/results/video-fixture.json");
    meta<<"{\n  \"scope\": \"RTL rendering of captured early-boot buffers\",\n  \"pixel_period_system_clocks\": 12,\n  \"regular_pixel_period\": "<<(regular?"true":"false")
      <<",\n  \"pixels_per_frame\": "<<pixels<<",\n  \"frame_period_system_clocks\": "<<frame_period
      <<",\n  \"regular_frame_period\": "<<(regular_frames?"true":"false")
      <<",\n  \"rom_requests\": "<<requests<<",\n  \"frames\": "<<frames<<"\n}\n";
    std::cout<<"Rendered fixture: frames="<<frames<<" pixels/frame="<<pixels<<" regular /12="<<regular<<" ROM="<<requests<<"\n";
    return regular && regular_frames && frame_period==512*282*12 && pixels==320*256 ? 0:1;
}
