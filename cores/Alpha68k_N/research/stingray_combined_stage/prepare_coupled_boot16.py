"""Freeze one private actual-CPU/MCU build and audit retained oracle provenance."""
from pathlib import Path
import csv
import hashlib
import json
import shutil
import subprocess
import sys

HERE=Path(__file__).resolve().parent
JOB=HERE/'coupled_boot16'
CANON=Path('D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N')
OLD=HERE.parents[1]
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    assert not JOB.exists(), 'Never restart an observed job; inspect existing receipts.'
    JOB.mkdir();source=JOB/'source';source.mkdir()
    contract=json.loads((HERE/'integration_contract.json').read_text())
    for entry in contract['overlay']:
        original=CANON/entry['target']
        assert H(original)==entry['base_sha256'],entry['target']
        candidate=Path(entry['path']);assert H(candidate)==entry['candidate_sha256']
    selected=[]
    for pattern in ['rtl/alpha68kn_*.sv','rtl/vendor/fx68k/*.sv',
                    'rtl/vendor/fx68k/*.mem','rtl/vendor/t80/T80s.v',
                    'rtl/vendor/jtframe_sdram/*.v','rtl/vendor/jt12/hdl/*.v',
                    'rtl/vendor/jt12/jt49/hdl/*.v','rtl/vendor/ay49/hdl/*.v',
                    'rtl/vendor/t48/t48_core.v','sim/sdram_model.h']:
        matches=list(CANON.glob(pattern));assert matches,pattern
        selected.extend(matches)
    pins=[]
    for original in sorted(set(selected)):
        rel=original.relative_to(CANON);dest=source/rel;dest.parent.mkdir(parents=True,exist_ok=True)
        candidate=HERE/'candidate'/rel
        shutil.copy2(candidate if candidate.exists() else original,dest)
        pins.append({'path':str(dest),'canonical_path':str(original),'canonical_sha256':H(original),
                     'private_base_sha256':H(dest),'kind':'candidate' if candidate.exists() else 'unchanged'})
    for rel in ['sim/system_main.cpp','sim/build_system.sh']:
        dest=source/rel;shutil.copy2(HERE/'candidate'/rel,dest)
        pins.append({'path':str(dest),'canonical_path':str(CANON/rel),'canonical_sha256':H(CANON/rel),
                     'private_base_sha256':H(dest),'kind':'candidate'})
    reference=CANON/'sim/captures/sstingry/attract'
    manifest=json.loads((reference/'manifest.json').read_text())
    exe=Path(manifest['command'][0]);capture=Path(manifest['command'][28])
    # The command's script argument is after -autoboot_script, not positional.
    capture=Path(manifest['command'][manifest['command'].index('-autoboot_script')+1])
    checks={'set_mode':manifest['set']=='sstingry' and manifest['mode']=='attract',
            'MAME_executable_hash':exe.exists() and H(exe)==manifest['executable_sha256'],
            'driver_hash':H(Path('D:/Arcade/AI/mame289/src/mame/alpha/alpha68k_n.cpp'))==manifest['driver_sha256'],
            'recording_script_hash':capture.exists() and H(capture)==manifest['script_sha256']}
    region_pins=[]
    for item in manifest['rom_regions']:
        p=OLD/item['path'];ok=p.exists() and H(p)==item['sha256'] and p.stat().st_size==item['bytes']
        region_pins.append({'path':str(p),'sha256':item['sha256'],'pass':ok})
    checks['all_recorded_ROM_regions_match']=all(x['pass'] for x in region_pins)
    artifacts={x['path']:x for x in manifest['artifacts']}
    audit_artifacts=[]
    for name in ['complete.txt','events.csv','inputs.csv','states.csv','mame.log']:
        p=reference/name;item=artifacts.get(name)
        ok=bool(item) and p.exists() and H(p)==item['sha256'] and p.stat().st_size==item['bytes']
        audit_artifacts.append({'path':str(p),'sha256':H(p) if p.exists() else None,'manifest_pinned':bool(item),'pass':ok})
    checks['selected_artifacts_match_manifest']=all(x['pass'] for x in audit_artifacts)
    complete=(reference/'complete.txt').read_text();checks['actual_finite_completion']='frames=1800' in complete
    inputs=reference/'frame_states.csv';rows=list(csv.DictReader(inputs.open()))
    checks['full1800_contiguous_input_rows']=len(rows)==1800 and [int(x['frame']) for x in rows]==list(range(1800))
    checks['all_input_ports_match_attract_and_DIP']=all((int(x['in0']),int(x['in1']),int(x['in2']))==(0,1,3) for x in rows)
    snapshots=list(csv.DictReader((reference/'states.csv').open()))
    checks['snapshot_input_ports_agree']=all((int(x['in0']),int(x['in1']),int(x['in2']))==(0,1,3) for x in snapshots)
    actions=list(csv.DictReader((reference/'inputs.csv').open()))
    checks['no_attract_action_edges']=not actions
    target=JOB/'actual_attract_inputs.csv';shutil.copy2(inputs,target)
    event_samples=[];header=None
    with (reference/'events.csv').open() as f:
        reader=csv.DictReader(f);header=reader.fieldnames
        for row in reader:
            frame=int(row.get('frame',row.get('screen_frame','0')))
            if frame>=16:break
            address=row.get('address','')
            try:addr=int(address,0)
            except ValueError:
                try:addr=int(address,16)
                except ValueError:continue
            if 0x80000<=addr<0x80200 and len(event_samples)<40:event_samples.append(row)
    provenance={'manifest_path':str(reference/'manifest.json'),'manifest_sha256':H(reference/'manifest.json'),
                'checks':checks,'source_identity_pass':all(checks.values()),'historical_actual_exit_code_recorded':False,
                'completion_text':complete,'exe_path':str(exe),'exe_sha256':manifest['executable_sha256'],
                'capture_script':str(capture),'capture_script_expected_sha256':manifest['script_sha256'],
                'capture_script_actual_sha256':H(capture) if capture.exists() else None,
                'ROM_regions':region_pins,'artifacts':audit_artifacts,'input_path':str(target),'input_sha256':H(target),
                'input_historical_manifest_pin':artifacts.get('frame_states.csv'),
                'event_columns':header,'first16_command_samples':event_samples,
                'limits':['Retained manifest only exists after recorder success/completion, but no separate raw MAME process-exit receipt is retained.',
                          'CPU memory taps omit direct C++ MCU shared writes/control/HALT edges; commands alone cannot qualify coupled ordering.',
                          'Input trace may have been added after this original manifest; constant attract ports are independently checked against pinned snapshots/actions.'],
                'full_MCUpaired_order_pass':False}
    (JOB/'reference_provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
    # Read-only retention. These names do not alter CPU, RAM, reset or clock logic.
    vlt=source/'sim/coupled_observer.vlt'
    vlt.write_text('`verilator_config\n'+''.join('public_flat_rd -module "alpha68kn_board" -var "'+name+'"\n' for name in
                   ['sting_*','mas_n','bus_done','irq2','maddr','mrw_n','muds_n','mlds_n','mdout','cpu_phase']))
    host=source/'sim/system_main.cpp';text=host.read_text()
    old='    uint64_t ticks=0;\n    auto tick=[&]() {';assert text.count(old)==1
    observer='''    uint64_t ticks=0;
    std::ofstream mcu_events(output/"coupled_mcu.csv");
    mcu_events<<"tick,edge,command,command_addr,rw,uds_n,lds_n,dout,halt,ASn,bus_done,shared_write,shared_addr,shared_data,irq2_pulse,irq2_held,bus_event,control_event,control,program_addr,oscillator_ticks,core_ticks,cpu_phase\\n";
    uint64_t previous_mcu_state=~uint64_t(0);
    auto observe_mcu=[&](const char* edge) {
        auto* r=top.rootp;
        if(top.reset || top.downloading) return;
        const uint64_t state=(uint64_t(r->alpha68kn_system__DOT__board__DOT__sting_mcu_main_halt)<<0)
            |(uint64_t(r->alpha68kn_system__DOT__board__DOT__irq2)<<1)
            |(uint64_t(r->alpha68kn_system__DOT__board__DOT__sting_mcu_control)<<2);
        if(!r->alpha68kn_system__DOT__board__DOT__sting_mcu_command_valid
           && !r->alpha68kn_system__DOT__board__DOT__sting_mcu_shared_write
           && !r->alpha68kn_system__DOT__board__DOT__sting_mcu_irq2
           && !r->alpha68kn_system__DOT__board__DOT__sting_mcu_bus_event
           && !r->alpha68kn_system__DOT__board__DOT__sting_mcu_control_event
           && state==previous_mcu_state) return;
        previous_mcu_state=state;
        mcu_events<<ticks<<','<<edge
          <<','<<unsigned(r->alpha68kn_system__DOT__board__DOT__sting_mcu_command_valid)
          <<','<<((r->alpha68kn_system__DOT__board__DOT__maddr>>1)&255)
          <<','<<unsigned(r->alpha68kn_system__DOT__board__DOT__mrw_n)
          <<','<<unsigned(r->alpha68kn_system__DOT__board__DOT__muds_n)
          <<','<<unsigned(r->alpha68kn_system__DOT__board__DOT__mlds_n)
          <<','<<unsigned(r->alpha68kn_system__DOT__board__DOT__mdout)
          <<','<<unsigned(r->alpha68kn_system__DOT__board__DOT__sting_mcu_main_halt)
          <<','<<unsigned(r->alpha68kn_system__DOT__board__DOT__mas_n)
          <<','<<unsigned(r->alpha68kn_system__DOT__board__DOT__bus_done)
          <<','<<unsigned(r->alpha68kn_system__DOT__board__DOT__sting_mcu_shared_write)
          <<','<<unsigned(r->alpha68kn_system__DOT__board__DOT__sting_mcu_shared_addr)
          <<','<<unsigned(r->alpha68kn_system__DOT__board__DOT__sting_mcu_shared_data)
          <<','<<unsigned(r->alpha68kn_system__DOT__board__DOT__sting_mcu_irq2)
          <<','<<unsigned(r->alpha68kn_system__DOT__board__DOT__irq2)
          <<','<<unsigned(r->alpha68kn_system__DOT__board__DOT__sting_mcu_bus_event)
          <<','<<unsigned(r->alpha68kn_system__DOT__board__DOT__sting_mcu_control_event)
          <<','<<unsigned(r->alpha68kn_system__DOT__board__DOT__sting_mcu_control)
          <<','<<unsigned(r->alpha68kn_system__DOT__board__DOT__sting_mcu_program_addr)
          <<','<<r->alpha68kn_system__DOT__board__DOT__sting_mcu_oscillator_ticks
          <<','<<r->alpha68kn_system__DOT__board__DOT__sting_mcu_core_ticks
          <<','<<unsigned(r->alpha68kn_system__DOT__board__DOT__cpu_phase)<<'\\n';
    };
    auto tick=[&]() {'''
    text=text.replace(old,observer,1)
    old='        top.clk=1;top.eval();ticks++;';assert text.count(old)==1
    text=text.replace(old,'        observe_mcu("before");\n        top.clk=1;top.eval();ticks++;\n        observe_mcu("after");',1)
    host.write_text(text,encoding='utf8',newline='\n')
    build=source/'sim/build_system.sh';text=build.read_text()
    text=text.replace('    rtl/vendor/t48/t48_core.v sim/system_main.cpp sim/sdram_model.h "$build_root/"',
                      '    rtl/vendor/t48/t48_core.v sim/coupled_observer.vlt sim/system_main.cpp sim/sdram_model.h "$build_root/"')
    text=text.replace('    fx68k.sv fx68kAlu.sv uaddrPla.sv ./*.v '+chr(92),
                      '    fx68k.sv fx68kAlu.sv uaddrPla.sv coupled_observer.vlt ./*.v '+chr(92))
    assert 'coupled_observer.vlt ./*.v' in text
    build.write_text(text,encoding='utf8',newline='\n')
    for item in pins:item['actual_private_sha256']=H(Path(item['path']))
    pins.append({'path':str(vlt),'actual_private_sha256':H(vlt),'kind':'read_only_observer_retention'})
    (JOB/'source_pins.json').write_text(json.dumps({'source_files':pins,'contract_sha256':H(HERE/'integration_contract.json'),
                  'canonical_written':False,'requested_fields':16,'input_sha256':H(target),
                  'private_CPU_RTL_change':'Candidate integration only; observer retention is read-only.',
                  'clock_tick_function_preserved':True},indent=2)+'\n')
    print(json.dumps({'source_root':str(source),'files':len(pins),'reference_checks':checks,
                      'command_samples':event_samples[:6],'input_sha256':H(target),
                      'source_pins_sha256':H(JOB/'source_pins.json'),'no_build_yet':True}))

if __name__=='__main__':main()
