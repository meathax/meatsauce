#include "Valpha68kn_board.h"
#include "verilated.h"
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <vector>
#include <stdexcept>

int main(int argc,char** argv) {
    if(argc<4) { std::cerr<<"usage: alpha68kn_cpu_sim download.bin frames output_directory\n";return 2; }
    Verilated::commandArgs(argc,argv);
    std::ifstream image(argv[1],std::ios::binary);
    std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(image)),{});
    if(bytes.size()!=0xa0000 || bytes[0]!='A' || bytes[5]>1) {
        std::cerr<<"Kyros/Japan loader image required; Stingray is not implemented yet\n";return 2;
    }
    unsigned frames=std::stoul(argv[2]);
    std::filesystem::path output(argv[3]);std::filesystem::create_directories(output);
    std::ofstream events(output/"bus.csv"), summary(output/"frames.csv");
    events<<"tick,address,transaction,iack,rw,uds_n,lds_n,data_out,data_in\n";
    summary<<"frame,main_address,sound_address,main_transactions,work_writes,strip_writes,mcu_transactions,irq1_acks,irq2_acks,unmapped\n";
    Valpha68kn_board board;
    board.clk=0;board.reset=1;board.downloading=1;board.load_wr=0;
    board.sound_io_read_data=0xff; // CPU-only harness has no sound-chip participant.
    board.controls=0;board.dips=0x8e;board.coins_n=3;board.debug_word_addr=0;
    board.debug_rom_kind=0;board.debug_rom_addr=0;
    auto tick=[&](){board.clk=0;board.eval();board.clk=1;board.eval();};
    for(unsigned i=0;i<256;i++) tick();
    for(unsigned i=0;i<bytes.size();i+=2) {
        board.load_wr=1;board.load_addr=i;board.load_data=bytes[i]|(bytes[i+1]<<8);tick();
    }
    board.load_wr=0;board.downloading=0;
    for(unsigned i=0;i<4096;i++) tick();
    // Verify each physically distinct on-chip ROM slot against the canonical
    // download before running CPUs; the SDRAM path has its own pin-level bench.
    struct Slot {unsigned kind,base,size;bool word_address;};
    const Slot slots[]={{1,0x100,0x20000,true},{2,0x20100,0x10000,true},
        {3,0x30100,0x100,false},{4,0x30200,0x100,false},{5,0x30300,0x100,false},
        {6,0x30400,0x200,false},{7,0x31000,0x2000,false},{8,0x33000,0x1000,false}};
    unsigned checked_words=0;
    for(const auto& slot:slots) for(unsigned offset=0;offset<slot.size;offset+=2) {
        board.debug_rom_kind=slot.kind;
        board.debug_rom_addr=slot.word_address ? offset/2 : offset;
        tick();
        uint16_t expected=(uint16_t(bytes[slot.base+offset])<<8)|bytes[slot.base+offset+1];
        if(board.debug_rom_data!=expected) {
            std::cerr<<"loader mismatch kind="<<slot.kind<<" offset="<<offset<<'\n';
            return 3;
        }
        checked_words++;
    }
    board.debug_rom_kind=0;
    std::cout<<"onchip_loader_words="<<checked_words<<'\n';
    board.reset=0;
    uint32_t previous=0;unsigned sampled=0,extra_samples=0;
    for(uint64_t cycle=0;cycle<uint64_t(frames)*384*264*8;cycle++) {
        unsigned frame=cycle/(384*264*8);
        if(cycle%(384*264*8)==0) {
            if(frame==120) board.coins_n=2;
            if(frame==126) board.coins_n=3;
            if(frame==160) board.controls=0x80;
            if(frame==166) board.controls=0;
        }
        auto address=board.debug_main_addr;
        auto attrs=board.debug_main_attrs;
        auto dataout=board.debug_main_dout;
        tick();
        if(board.main_transactions!=previous) {
            previous=board.main_transactions;
            bool selected=(address>=0x020000 && address<0x021000)
                || (address>=0x080000 && address<0x080200)
                || (address>=0x01fc00 && address<0x01ff00);
            if(sampled++<4096 || (selected && extra_samples++<2048))
                events<<cycle<<','<<address<<','<<previous<<','<<((attrs>>3)&1)<<','
                    <<((attrs>>2)&1)<<','<<((attrs>>1)&1)<<','<<(attrs&1)<<','
                    <<dataout<<','<<board.debug_main_din<<'\n';
        }
        if(cycle%(384*264*8)==384*264*8-1) {
            summary<<frame<<','<<board.debug_main_addr<<','<<board.debug_sound_addr<<','
                <<board.main_transactions<<','<<board.work_writes<<','<<board.strip_writes<<','
                <<board.mcu_transactions<<','<<board.irq1_acks<<','<<board.irq2_acks<<','<<board.unmapped_accesses<<'\n';
            summary.flush();
        }
    }
    std::cout<<"frames="<<frames<<" main_transactions="<<board.main_transactions
        <<" mcu="<<board.mcu_transactions<<" strip_writes="<<board.strip_writes
        <<" irq1="<<board.irq1_acks<<" irq2="<<board.irq2_acks<<" unmapped="<<board.unmapped_accesses<<'\n';
    bool ran=board.main_transactions>10;
    // Hold CPUs in reset for a stable RAM walk; reset never clears gameplay RAM.
    board.reset=1;tick();
    std::ofstream work(output/"work.bin",std::ios::binary),strip(output/"sprites.bin",std::ios::binary);
    for(unsigned i=0;i<4096;i++) {
        board.debug_word_addr=i;tick();uint16_t w=board.debug_work_data,s=board.debug_strip_data;
        if(i<2048) {work.put(w>>8);work.put(w&255);}strip.put(s>>8);strip.put(s&255);
    }
    board.final();
    return ran ? 0 : 1;
}
