#include "Valpha68kn_framework_video.h"
#include "verilated.h"
#include <cstdint>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>

int main(int argc,char** argv) {
    if(argc!=3) return 2;
    std::ifstream file(argv[1],std::ios::binary);
    const std::vector<uint8_t> image{std::istreambuf_iterator<char>(file),{}};
    if(image.size()!=256*224*3) return 2;
    std::ofstream evidence(argv[2]);
    if(!evidence) return 2;
    evidence<<"{\"scope\":\"captured-game field through real pinned framework; not CPU/whole-core acceptance\",\"modes\":[";
    bool timing_ok=true,input_ok=true,native_rgb_ok=true,rotation_ok=true;
    unsigned source_nonzero=0;
    for(auto value:image) source_nonzero+=value!=0;
    if(!source_nonzero) return 2;
    for(unsigned mode=0;mode<7;mode++) {
        Valpha68kn_framework_video top;
        top.fx=mode>=5?0:mode;
        top.forced=mode==5;
        top.no_rotate=mode!=0;
        const unsigned width=mode==1?512:256;
        const unsigned height=mode && mode!=6?448:224;
        unsigned input_count=0,input_diff=0,output_count=0,output_nonzero=0;
        unsigned rgb_diff=0,hs_edges=0,vs_edges=0;
        unsigned last_output_sl=0;
        bool last_hs=false,last_vs=false;
        std::vector<uint32_t> measured_counts;
        // Model only accepted DDR writes and scaler vertical feedback. This
        // is a pixel-address contract with an always-ready DDR endpoint;
        // physical latency/bandwidth qualification remains separate.
        const uint64_t memory_base=0x24000000;
        std::vector<uint8_t> memory(mode==0?3*8*1024*1024:0);
        std::vector<uint8_t> written(memory.size());
        unsigned ddr_writes=0,ddr_out_of_bounds=0,disabled_writes=0;
        // Identical fields remove capture-epoch ambiguity; discard only the
        // first four fields while the framework measures sync polarity.
        for(unsigned field=0;field<7;field++) {
            unsigned field_output=0;
            for(unsigned tick=0;tick<384*264*8;tick++) {
                const unsigned pixel=tick/8,x=pixel%384,y=pixel/384;
                const bool active=x<256 && y>=16 && y<240;
                const unsigned offset=active?((y-16)*256+x)*3:0;
                top.clk=0;top.ce=(tick%8)==0;
                top.rgb=active?(uint32_t(image[offset])<<16)|(uint32_t(image[offset+1])<<8)|image[offset+2]:0;
                top.hb=x>=256;top.vb=y<16 || y>=240;
                top.hs=!(x>=272 && x<304);top.vs=!(y>=248 && y<252);
                top.fb_vblank=y>=248 && y<252;
                top.eval();top.clk=1;top.eval();
                if(top.ddr_we) {
                    if(field>=4) ddr_writes++;
                    if(mode!=0) {if(field>=4) disabled_writes++;}
                    else {
                        uint64_t address=uint64_t(top.ddr_addr)*8;
                        if(address<memory_base || address-memory_base+8>memory.size()) ddr_out_of_bounds++;
                        else for(unsigned lane=0;lane<8;lane++) if(top.ddr_be&(1u<<lane)) {
                            auto index=address-memory_base+lane;
                            memory[index]=(uint64_t(top.ddr_data)>>(lane*8))&255;
                            written[index]=1;
                        }
                    }
                }
                if(field>=4) {
                    if(top.capture_ce && !top.capture_hb && !top.capture_vb) {
                        unsigned index=(input_count%(256*224))*3;
                        uint32_t wanted=(uint32_t(image[index])<<16)|(uint32_t(image[index+1])<<8)|image[index+2];
                        input_diff+=top.capture_rgb!=wanted;input_count++;
                    }
                    if(top.output_ce) {
                        if(!last_hs && top.output_hs) hs_edges++;
                        if(!last_vs && top.output_vs) vs_edges++;
                        last_hs=top.output_hs;last_vs=top.output_vs;
                        if(top.output_de) {
                            if(mode==0 || mode==6) {
                                unsigned index=(output_count%(256*224))*3;
                                uint32_t wanted=(uint32_t(image[index])<<16)|(uint32_t(image[index+1])<<8)|image[index+2];
                                rgb_diff+=top.output_rgb!=wanted;
                            }
                            field_output++;output_count++;output_nonzero+=top.output_rgb!=0;
                            last_output_sl=top.output_sl;
                        }
                    }
                }
            }
            if(field>=4) measured_counts.push_back(field_output);
        }
        bool counts_ok=true;
        for(auto count:measured_counts) counts_ok &= count==width*height;
        const bool raw_ok=input_count==3*256*224 && input_diff==0;
        const bool shape_ok=counts_ok && hs_edges>0 && vs_edges>0;
        input_ok &= raw_ok;timing_ok &= shape_ok;
        if(mode==0 || mode==6) native_rgb_ok &= rgb_diff==0;
        unsigned rotated_differences=0,unwritten_pixels=0;
        bool rotate_passed;
        if(mode==0) {
            rotate_passed=top.rotated && top.fb_en && top.fb_width==224 && top.fb_height==256
                && top.fb_stride==224*4 && ddr_out_of_bounds==0;
            const uint64_t base=top.fb_base;
            for(unsigned sy=0;sy<224;sy++) for(unsigned sx=0;sx<256;sx++) {
                // Independent clockwise transform: (x,y)->(223-y,x).
                uint64_t address=base+uint64_t(sx)*top.fb_stride+(223-sy)*4;
                if(address<memory_base || address-memory_base+4>memory.size()) {
                    rotated_differences++;unwritten_pixels++;continue;
                }
                auto offset=address-memory_base;
                unsigned source=(sy*256+sx)*3;
                bool mismatch=false,missing=false;
                for(unsigned channel=0;channel<3;channel++) {
                    mismatch |= memory[offset+channel]!=image[source+channel];
                    missing |= !written[offset+channel];
                }
                rotated_differences+=mismatch;unwritten_pixels+=missing;
            }
            rotate_passed &= rotated_differences==0 && unwritten_pixels==0 && ddr_writes==3*256*224;
        } else rotate_passed=!top.rotated && !top.fb_en && disabled_writes==0;
        rotation_ok &= rotate_passed;
        if(mode) evidence<<',';
        evidence<<"{\"fx\":"<<unsigned(top.fx)<<",\"forced\":"<<unsigned(top.forced)
            <<",\"expected_width\":"<<width<<",\"expected_height\":"<<height
            <<",\"input_pixels\":"<<input_count<<",\"input_different_pixels\":"<<input_diff
            <<",\"output_pixels\":"<<output_count<<",\"output_nonzero_pixels\":"<<output_nonzero
            <<",\"native_output_different_pixels\":"<<((mode==0 || mode==6)?std::to_string(rgb_diff):"null")
            <<",\"output_sl\":"<<last_output_sl<<",\"hs_rises\":"<<hs_edges<<",\"vs_rises\":"<<vs_edges
            <<",\"input_register_passed\":"<<(raw_ok?"true":"false")
            <<",\"pixel_count_sync_passed\":"<<(shape_ok?"true":"false")<<",\"field_counts\":[";
        for(unsigned i=0;i<measured_counts.size();i++) {if(i) evidence<<',';evidence<<measured_counts[i];}
        evidence<<"],\"rotation_enabled\":"<<(top.rotated?"true":"false")
            <<",\"fb_width\":"<<unsigned(top.fb_width)<<",\"fb_height\":"<<unsigned(top.fb_height)
            <<",\"fb_stride\":"<<unsigned(top.fb_stride)<<",\"ddr_writes\":"<<ddr_writes
            <<",\"ddr_out_of_bounds\":"<<ddr_out_of_bounds
            <<",\"rotated_different_pixels\":"<<(mode==0?std::to_string(rotated_differences):"null")
            <<",\"unwritten_pixels\":"<<(mode==0?std::to_string(unwritten_pixels):"null")
            <<",\"rotation_contract_passed\":"<<(rotate_passed?"true":"false")<<"}";
        top.final();
    }
    evidence<<"],\"input_register_passed\":"<<(input_ok?"true":"false")
        <<",\"pixel_count_sync_passed\":"<<(timing_ok?"true":"false")
        <<",\"native_output_rgb_passed\":"<<(native_rgb_ok?"true":"false")
        <<",\"rotation_contract_passed\":"<<(rotation_ok?"true":"false")<<"}\n";
    // Keep an actual RGB failure a failure; narrower timing/input results are
    // separate evidence, never a substitute for the output contract.
    return input_ok && timing_ok && native_rgb_ok && rotation_ok ? 0 : 1;
}
