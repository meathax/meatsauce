// SPDX-License-Identifier: GPL-3.0-or-later
// Reuse the existing real bus/RTL bench, without running its synthetic unit suite.
#define main unused_gpu_unit_main
#include "gpu.cpp"
#undef main
#include <fstream>
#include <map>
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    try{
        std::ifstream fixture("sim/obj_dir/gpu_game/fixture.txt");std::string texture_path,frame_path;
        std::getline(fixture,texture_path);std::getline(fixture,frame_path);
        unsigned capture_frame,first,end,control,display,bank1;
        fixture>>capture_frame>>first>>end>>control>>display>>bank1;
        check(bool(fixture),"missing staged fixture");check(first==0&&end==1&&display==0,"first-draw reset-state contract");
        Bench b;b.reset();b.record_writes=true;
        auto load=[&](const std::string&path,GpuMemory&memory){std::ifstream f(path,std::ios::binary);f.read(reinterpret_cast<char*>(memory.bytes.data()),memory.bytes.size());check(f.gcount()==int64_t(memory.bytes.size()),"complete native memory fixture");};
        load(texture_path,b.texture);load(frame_path,b.frame);
        GpuMemory oracle_texture=b.texture,expected=b.frame;
        expected.record_writes=true;
        vr0video_device oracle(oracle_texture,expected);
        b.reg(0x90,true,bank1,3);b.reg(0x8c,true,control,1);
        check(b.d.draw_address==0,"initial native draw destination");
        check(oracle.process_packet(first*32)==0,"first submission has no flip");
        check(!expected.writes.empty(),"real draw produces pixel stores");
        b.reg(0x80,true,end,3);
        for(unsigned cycle=0;cycle<3000000;++cycle){
            b.tick();check(!b.d.fault,"native game packet GPU fault");
            if(!b.d.busy&&b.d.queue_rear==end)break;
            if(cycle==2999999)throw std::runtime_error("real game packet timeout");
        }
        check(b.d.packets_completed==1,"one genuine game packet completed");
        // The burst renderer stores every opaque pixel; MAME skips stores of an unchanged value.
        // Memory must be identical, and every pixel MAME changes must be stored with its value.
        check(b.d.pixels_written>=expected.writes.size(),"native writes cover MAME's changed pixels");
        {std::map<u32,u16> stored;for(const auto& w:b.recorded_writes)stored[w.first]=w.second;
         for(const auto& w:expected.writes){auto i=stored.find(w.first);check(i!=stored.end()&&i->second==w.second,"MAME pixel store present with MAME data");}}
        check(b.frame.bytes==expected.bytes,"full 8MiB framebuffer matches unchanged MAME draw");
        check(b.texture.bytes==oracle_texture.bytes,"packet/texture RAM unchanged by renderer");
        auto save=[&](const char*path,const GpuMemory&memory){std::ofstream f(path,std::ios::binary);f.write(reinterpret_cast<const char*>(memory.bytes.data()),memory.bytes.size());check(bool(f),"save private framebuffer");};
        save("sim/obj_dir/gpu_game/rtl_frame_after.bin",b.frame);save("sim/obj_dir/gpu_game/mame_frame_after.bin",expected);
        std::cout<<"PASS native game first draw: capture frame="<<capture_frame<<" flags="<<std::hex<<b.texture.read_word(first*64)<<std::dec<<", "<<expected.writes.size()<<" exact pixel stores, full 8MiB framebuffer, "<<b.requests<<" bus requests / "<<b.clocks<<" clocks; coherent native fixture, no game boot claim\n";
        return 0;
    }catch(const std::exception&e){std::cerr<<"FAIL native GPU replay: "<<e.what()<<"\n";return 1;}
}
