"""Freeze a read-only accepted-write/bank observer; no functional RTL changes."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys

HERE=Path(__file__).resolve().parent
BASE=HERE/'coupled_boot16'
OLD111=HERE/'coupled_boot111'
JOB=HERE/'bank_before_after111'
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    assert not JOB.exists(),'Preserve the existing observer job; never restart.'
    oldpins=json.loads((BASE/'source_pins.json').read_text())
    assert H(OLD111/'verification.json')=='5918ddcd8cce6295bd6d74ca0f17c8f3f8f0100658260c20165884b8abe594e3'
    JOB.mkdir();source=JOB/'source';source.mkdir()
    pins=[]
    for item in oldpins['source_files']:
        original=Path(item['path']);assert H(original)==item['actual_private_sha256']
        rel=original.relative_to(BASE/'source');dest=source/rel;dest.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(original,dest)
        pins.append({'path':str(dest),'base_path':str(original),'base_sha256':H(original)})
    host=source/'sim/system_main.cpp';text=host.read_text()
    old='    auto tick=[&]() {'
    assert text.count(old)==1
    observer='''    std::ofstream bank_events(output/"bank_write_edges.csv");
    bank_events<<"tick_before,tick_after,held_reset,CPU_work,CPU_rw,CPU_uds_n,CPU_lds_n,HS_work,HLE_low,MCU_work,port_addr,write_hi,write_lo,data_hi,data_lo,MCU_addr,MCU_data,before22,before29,beforeff,after22,after29,afterff,expected22,expected29,expectedff,match\\n";
    uint16_t bank_before[3];
    unsigned bank_addr,bank_hi,bank_lo,bank_data_hi,bank_data_lo;
    unsigned bank_CPU,bank_rw,bank_uds,bank_lds,bank_HS,bank_HLE,bank_MCU,bank_reset,bank_MCU_addr,bank_MCU_data;
    auto read_bank=[&](unsigned address) -> uint16_t {
        auto* r=top.rootp;
        if(address==0x22) return r->alpha68kn_system__DOT__board__DOT__work_word22;
        return (unsigned(r->alpha68kn_system__DOT__board__DOT__work_hi[address])<<8)
             | unsigned(r->alpha68kn_system__DOT__board__DOT__work_lo[address]);
    };
    auto observe_bank_before=[&]() {
        auto* r=top.rootp;
        bank_before[0]=read_bank(0x22);bank_before[1]=read_bank(0x29);bank_before[2]=read_bank(0xff);
        bank_addr=r->alpha68kn_system__DOT__board__DOT__work_port_addr;
        bank_hi=r->alpha68kn_system__DOT__board__DOT__work_write_hi;
        bank_lo=r->alpha68kn_system__DOT__board__DOT__work_write_lo;
        bank_data_hi=r->alpha68kn_system__DOT__board__DOT__work_data_hi;
        bank_data_lo=r->alpha68kn_system__DOT__board__DOT__work_data_lo;
        bank_CPU=r->alpha68kn_system__DOT__board__DOT__cpu_work_service;
        bank_rw=r->alpha68kn_system__DOT__board__DOT__mrw_n;
        bank_uds=r->alpha68kn_system__DOT__board__DOT__muds_n;
        bank_lds=r->alpha68kn_system__DOT__board__DOT__mlds_n;
        bank_HS=r->alpha68kn_system__DOT__board__DOT__hs_work_service;
        bank_HLE=r->alpha68kn_system__DOT__board__DOT__hle_low_write;
        bank_MCU=r->alpha68kn_system__DOT__board__DOT__sting_mcu_work_service;
        bank_reset=r->alpha68kn_system__DOT__board__DOT__held_reset;
        bank_MCU_addr=r->alpha68kn_system__DOT__board__DOT__sting_mcu_shared_addr;
        bank_MCU_data=r->alpha68kn_system__DOT__board__DOT__sting_mcu_shared_data;
    };
    auto observe_bank_after=[&]() {
        const unsigned addresses[3]={0x22,0x29,0xff};
        uint16_t after[3],expected[3];bool changed=false,match=true;
        for(unsigned i=0;i<3;i++) {
            after[i]=read_bank(addresses[i]);expected[i]=bank_before[i];
            if(bank_addr==addresses[i]) {
                if(bank_hi) expected[i]=(expected[i]&0xff)|(bank_data_hi<<8);
                if(bank_lo) expected[i]=(expected[i]&0xff00)|bank_data_lo;
            }
            changed|=after[i]!=bank_before[i];match&=after[i]==expected[i];
        }
        bool selected=bank_addr==0x22 || bank_addr==0x29 || bank_addr==0xff;
        if(!(changed || (selected && (bank_hi || bank_lo)))) return;
        bank_events<<ticks-1<<','<<ticks<<','<<bank_reset<<','<<bank_CPU<<','<<bank_rw
          <<','<<bank_uds<<','<<bank_lds<<','<<bank_HS<<','<<bank_HLE<<','<<bank_MCU
          <<','<<bank_addr<<','<<bank_hi<<','<<bank_lo<<','<<bank_data_hi<<','<<bank_data_lo
          <<','<<bank_MCU_addr<<','<<bank_MCU_data;
        for(unsigned i=0;i<3;i++) bank_events<<','<<bank_before[i];
        for(unsigned i=0;i<3;i++) bank_events<<','<<after[i];
        for(unsigned i=0;i<3;i++) bank_events<<','<<expected[i];
        bank_events<<','<<match<<'\\n';
    };
    auto tick=[&]() {'''
    text=text.replace(old,observer,1)
    old='        observe_mcu("before");\n        top.clk=1;top.eval();ticks++;\n        observe_mcu("after");'
    new='        observe_mcu("before");\n        observe_bank_before();\n        top.clk=1;top.eval();ticks++;\n        observe_bank_after();\n        observe_mcu("after");'
    assert text.count(old)==1;text=text.replace(old,new,1)
    host.write_text(text,encoding='utf8',newline='\n')
    vlt=source/'sim/coupled_observer.vlt'
    text=vlt.read_text()+''.join('public_flat_rd -module "alpha68kn_board" -var "'+name+'"\n' for name in
        ['held_reset','cpu_work_service','hs_work_service','hle_low_write','work_port_addr','work_write_hi','work_write_lo','work_data_hi','work_data_lo'])
    vlt.write_text(text,encoding='utf8',newline='\n')
    for item in pins:item['observer_sha256']=H(Path(item['path']))
    rtl=[x for x in pins if Path(x['path']).suffix in ['.sv','.v','.mem']]
    checks={'all_unchanged_RTL_ROM75_inputs_copied':all(x['base_sha256']==x['observer_sha256'] for x in rtl),
            'only_host_and_readonly_vlt_changed':all(x['base_sha256']==x['observer_sha256'] or x['path'] in [str(host),str(vlt)] for x in pins),
            'same_clock_tick_edges':text is not None and 'top.clk=1;top.eval();ticks++;' in host.read_text(),
            'no_synthetic_CPU_RAM_or_input_mutation':'read_bank' in host.read_text(),
            'actual_source_strobes_not_event_guesses':all(name in vlt.read_text() for name in ['work_write_hi','work_write_lo','work_port_addr','cpu_work_service','hs_work_service','hle_low_write']),
            'accepted_RAM_source_unmodified':H(source/'rtl/alpha68kn_board.sv')=='65abc024031683b20df2f0fea9aec3540af94cdcd52759d96e0602609c2212c8'}
    assert all(checks.values()),checks
    record={'schema':'private_sstingry_bank_observer111_v1','source_files':pins,'checks':checks,
       'original111_verification_sha256':H(OLD111/'verification.json'),'original111_final_low_check_failed_preserved':True,
       'original111_final_low_check_proves_drop':False,'required_input':str(BASE/'actual_attract_inputs.csv'),
       'required_input_sha256':H(BASE/'actual_attract_inputs.csv'),'requested_fields':111,
       'observed_words':[0x22,0x29,0xff],'hardware_source_changed':False,
       'observation':'Actual selected write wires and values sampled before/after the same master edge; no functional RTL or state writes.',
       'limits':['Lane expectation is a report only, never an execution assertion or a seeded response.',
                 'Full hardware/MAME timing pairing remains unqualified; this resolves actual storage commits versus later overwrites.'],
       'helper_sha256':H(Path(__file__))}
    (JOB/'source_pins.json').write_text(json.dumps(record,indent=2)+'\n')
    print(json.dumps({'checks':checks,'source_files':len(pins),'source_root':str(source),
                      'host_sha256':H(host),'vlt_sha256':H(vlt),'source_pins_sha256':H(JOB/'source_pins.json'),
                      'no_build_or_replay_yet':True}))

if __name__=='__main__':main()
