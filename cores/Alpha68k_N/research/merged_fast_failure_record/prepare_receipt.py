from pathlib import Path
import hashlib,json,shutil,re
stage=Path(__file__).resolve().parent
oldroot=stage.parents[1]
canonical=Path(r'D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N')
run=Path(r'C:\Users\meath\QuartusFast\runs\20261010-180833-6448-dev-fast')
cache=Path(r'C:\Users\meath\QuartusFast\cache\c27abd993c99e2de4f51\dev-fast-check')
capture=oldroot/'sim/captures/diagnostics/merged_fast_failure';capture.mkdir(parents=True,exist_ok=True)
sha=lambda b:hashlib.sha256(b).hexdigest()
launch=json.loads((oldroot/'research/quartus_check_merged_fast_launch.json').read_text())
admission=oldroot/'research/quartus_check_merged_preprocessed_admission.json'
assert sha(admission.read_bytes())==launch['admission_sha256']
pins=launch['source_pins'];assert len(pins)==161
after={name:sha((canonical/name).read_bytes()) for name in pins}
assert after==pins
mapreport=cache/'output_files/Alpha68k_N.map.rpt'
assert sha(mapreport.read_bytes())=='bf6a8f1c5fc6f0ba3434239468528de3acf3d485f7d9e0f6168eaccd8b129af0'
paths=[mapreport,run/'map.log',run/'fit.log',cache/'Alpha68k_N.qsf']
paths.extend(p for p in run.glob('*.json'))
recovery=[]
for p in paths:
    dst=capture/p.name;shutil.copyfile(p,dst)
    digest=sha(p.read_bytes());assert digest==sha(dst.read_bytes())
    recovery.append({'original_path':str(p),'recovery_path':str(dst),'sha256':digest,'bytes':p.stat().st_size})
lines=mapreport.read_text(errors='replace').splitlines()
def evidence(pattern):
    return [{'line':n+1,'text':s.strip()} for n,s in enumerate(lines) if re.search(pattern,s)]
start=next(n for n,s in enumerate(lines) if s.startswith('; Analysis & Synthesis RAM Summary'))
ram=[]
for n in range(start+1,min(len(lines),start+150)):
    s=lines[n]
    if s.startswith('; ') and '|ALTSYNCRAM' in s:
        col=[v.strip() for v in s.split(';')[1:-1]]
        def number(value):
            if value=='--':return None
            assert value.isdecimal(),value
            return int(value)
        ram.append({'line':n+1,'name':col[0],'type':col[1],'mode':col[2],'a_depth':number(col[3]),'a_width':number(col[4]),'b_depth':number(col[5]),'b_width':number(col[6]),'bits':number(col[7])})
assert ram and not any('sound_rom' in row['name'] for row in ram)
selected=[row for row in ram if 'alpha68kn_board:board|' in row['name'] or 'alpha68kn_video_rom:video_rom|' in row['name']]
assert any('main_rom_rtl' in row['name'] and row['bits']==1048576 for row in selected)
assert len([row for row in selected if any(part in row['name'] for part in ['renderer_strip_hi','renderer_strip_lo','strip_hi_rtl','strip_lo_rtl','work_hi_rtl','work_lo_rtl'])])==6
assert len([row for row in selected if 'alpha68kn_video_rom:video_rom|' in row['name']])==6
mux=evidence(r'; 32768:1 .*sound_rom_q')
assert len(mux)==1 and '349520 LEs' in mux[0]['text']
cancelpath=oldroot/'research/quartus_check_merged_owned_cancel.json'
cancel=json.loads(cancelpath.read_text(encoding='utf-8-sig'))
assert cancel['leaf_id']==70068 and not cancel['unrelated_jobs_touched']
record={'status':'full_check_failed_capacity_fit_deliberately_cancelled','immutable_scope':'Current complete sys_top design, Kyros/Japan; no future Stingray or RBF acceptance. Guard/probe work is separate.','hardware_frozen_head':launch['hardware_frozen_head'],'source_pin_count':161,'source_pins_before':pins,'source_pins_after':after,'all_production_inputs_unchanged':True,'original_admission_path':str(admission),'original_admission_sha256':launch['admission_sha256'],'original_qpf_qsf_hashes':launch['staged_hashes'],'original_launch_receipt_path':str(oldroot/'research/quartus_check_merged_fast_launch.json'),'actual_run':{'session_id':96534,'controller_pid':6448,'run_path':str(run),'cache_path':str(cache),'map_exit':0,'map_success_message':'Quartus Prime Analysis & Synthesis was successful. 0 errors, 1471 warnings','map_elapsed':'00:36:09','map_cpu':'00:35:32','map_peak_virtual_memory_MB':10271,'map_logic_cells':771911,'map_registers':548181,'map_estimated_ALMs_needed':372496,'map_block_memory_bits':1915224,'map_RAM_segments':1299,'map_DSP_elements':41,'fit_status':'deliberately_cancelled_exact_owned_PID70068','fit_numeric_exit':'not exposed by frontend; no fabricated exit','owned_stop_helper_exit':0,'owned_stop_helper_chunk':'0873a5','wrapper_exit':1,'wrapper_terminal_chunk':'044cd8','wrapper_accepted':False,'STA':'not_run','assembly':'not_authorized_not_run','production_queue_lease':False},'named_sound_failure':{'sound_rom_absent_from_complete_RAM_summary':True,'RAM_summary_rows_inspected':len(ram),'board_own_registers':524625,'sound_ROM_bits':524288,'register_count_difference':337,'explicit_sound_q_mux':mux,'cause_status':'Inference failure established; exact responsible-source cause awaits matched private probe. No main-ROM patch justified.'},'healthy_named_RAMs':selected,'resource_scope':{'seven_final_fitted_metrics':'all unqualified/not produced','ALM_synthesis_estimate':'gross device-capacity failure; not a fitted resource measurement','RAM_segments':'do not reinterpret as M10K block count','routing_peak_H_V_average':'unknown','timing_setup_hold_recovery_removal':'unknown; STA not run','clocks_unconstrained':'partial fitter clock processing is not complete STA qualification','external_SDRAM_IO_delays':'unqualified existing source-backed gate','resource_limits_relaxed':False},'source_evidence':evidence(r'(Total registers\s*;|Total block memory bits\s*;|Estimate of Logic utilization|\|alpha68kn_board:board\|\s*;)'),'cancellation_receipt':{'path':str(cancelpath),'sha256':sha(cancelpath.read_bytes()),'data':cancel},'authentic_report_recovery':recovery}
(stage/'full_check_failure.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
(stage/'full_check_failure.md').write_text('Complete current sys_top DEV_FAST check failed capacity. Actual map exit 0; estimated 372496 ALMs, 548181 registers, 771911 logic cells. Sound ROM is absent from the RAM summary and sound_rom_q is a32768:1 x16 mux costing349520 LEs. Board own524625 registers closely accounts for524288 sound bits plus337 control bits.\n\nMain ROM, all six work/strip banks and all six video PROM memories are present as inferred RAM. Exact inference cause is not yet proven.\n\nOnly owned fitPID70068 was deliberately stopped after identity checks; wrapper session96534 returned1. Numeric cancelled-leaf exit is not exposed. No STA, assembly or RBF occurred; final seven fitted resource metrics and complete timing remain unqualified. All161 production input hashes match the frozen source before/after. Authentic report SHA bf6a8f1c5fc6f0ba3434239468528de3acf3d485f7d9e0f6168eaccd8b129af0. See full_check_failure.json for exact recovery paths and report lines.\n',encoding='utf-8')
files=[p for p in stage.iterdir() if p.is_file() and p.name!='import_manifest.json']
manifest={'status':'immutable_verified_failure_record','files':[{'name':p.name,'sha256':sha(p.read_bytes())} for p in sorted(files)],'large_reports':'remain ignored at exact recovery paths in JSON; metadata import only','frozen_hardware_head':launch['hardware_frozen_head'],'evolving_candidate_probes_included':False}
(stage/'import_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
print(json.dumps({'status':record['status'],'source_pins_unchanged':len(pins),'healthy_named_rows':len(selected),'map_sha256':sha(mapreport.read_bytes()),'manifest_sha256':sha((stage/'import_manifest.json').read_bytes())}))
