#include "Vzero_crypt_top.h"
#include "verilated.h"
#include "crypt_compat.hpp"
#include "mame_crypt_reference.hpp"
#include <fstream>
#include <vector>
#include <iostream>
#include <stdexcept>
int main(int argc,char** argv) {
    Verilated::commandArgs(argc,argv);
    std::ifstream f("roms/regions/sprites.bin",std::ios::binary);
    std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(f)),{});
    if(bytes.size()!=0x800000)throw std::runtime_error("Expected exact target sprite region");
    std::vector<uint32_t> encrypted(bytes.size()/4);
    for(size_t i=0;i<encrypted.size();++i)encrypted[i]=bytes[4*i]|(uint32_t(bytes[4*i+1])<<8)|(uint32_t(bytes[4*i+2])<<16)|(uint32_t(bytes[4*i+3])<<24);
    auto reference=encrypted;
    zeroteam_decrypt_sprites(reference.data(),0x400000/4);
    Vzero_crypt_top top;
    uint64_t differences=0; size_t first_difference=encrypted.size();
    std::ofstream output("sim/results/rtl-decrypted-sprites.bin",std::ios::binary);
    for(size_t i=0;i<encrypted.size();++i) {
        top.clk=0; top.word_index=i; top.cipher_data=encrypted[i]; top.eval();
        top.clk=1; top.eval();
        uint32_t value=top.plain_data;
        if(value!=reference[i]){++differences;if(first_difference==encrypted.size())first_difference=i;}
        uint8_t row[4]={uint8_t(value),uint8_t(value>>8),uint8_t(value>>16),uint8_t(value>>24)};
        output.write(reinterpret_cast<char*>(row),4);
    }
    top.final();
    std::ofstream report("sim/results/cipher-diff.json");
    report<<"{\n  \"words_compared\": "<<encrypted.size()<<",\n  \"encrypted_words\": 1048576,\n  \"passthrough_words\": 1048576,\n  \"different_words\": "<<differences<<",\n  \"first_difference_index\": "<<first_difference<<"\n}\n";
    std::cout<<"RTL/MAME sprite cipher: "<<encrypted.size()<<" words, differences="<<differences<<"\n";
    return differences?1:0;
}
