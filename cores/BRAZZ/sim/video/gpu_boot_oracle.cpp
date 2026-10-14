// SPDX-License-Identifier: GPL-3.0-or-later
// Host-only comparison of a naturally captured RTL packet with pinned MAME.
#include "../obj_dir/gpu_reference/vr0_gpu_reference.hpp"
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
static void load(const std::string& path,GpuMemory& memory){
    std::ifstream f(path,std::ios::binary);
    f.read(reinterpret_cast<char*>(memory.bytes.data()),memory.bytes.size());
    if(f.gcount()!=int64_t(memory.bytes.size()))throw std::runtime_error("incomplete memory: "+path);
}
int main(int argc,char**argv){
    try{
        if(argc!=5)throw std::runtime_error("usage: oracle pre-directory output-directory packet-index draw-destination");
        std::string pre=argv[1],out=argv[2];
        GpuMemory texture,frame;load(pre+"/texture.bin",texture);load(pre+"/framebuffer.bin",frame);
        frame.record_writes=true;vr0video_device oracle(texture,frame);
        oracle.m_draw_dest=std::stoul(argv[4],nullptr,0);
        if(oracle.process_packet(std::stoul(argv[3],nullptr,0)*32)!=0)throw std::runtime_error("first packet is a flip");
        std::ofstream stores(out+"/mame_stores.txt");
        for(auto [address,value]:frame.writes)stores<<address<<' '<<value<<'\n';
        std::ofstream image(out+"/mame_framebuffer.bin",std::ios::binary);
        image.write(reinterpret_cast<const char*>(frame.bytes.data()),frame.bytes.size());
        if(!stores||!image)throw std::runtime_error("save oracle results");
        std::cout<<"MAME first natural RTL packet: "<<frame.writes.size()<<" pixel stores\n";
        return 0;
    }catch(const std::exception&e){std::cerr<<"FAIL boot GPU oracle: "<<e.what()<<'\n';return 1;}
}
