from pathlib import Path
import json,hashlib,re,shutil
base=Path(__file__).resolve().parent
root=base.parents[1]
canonical=Path(r'D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N')
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
prepared=json.loads((base/'prepared.json').read_text(encoding='utf-8-sig'))
for name,pin in prepared['probes'].items():
    assert sha(base/name/(name+'.sv'))==pin['source_sha256']
assert sha(canonical/'rtl/alpha68kn_board.sv')==prepared['canonical_board_sha256']
assert sha(base/'board_write15.sv')==prepared['candidate_sha256']
old=(canonical/'rtl/alpha68kn_board.sv').read_text()
new=(base/'board_write15.sv').read_text()
needle="sound_rom[(load_addr-'h20100)>>1] <= load_data;"
replacement="sound_rom[15'((load_addr-'h20100)>>1)] <= load_data;"
assert old.count(needle)==1 and old.replace(needle,replacement)==new
cast=(base/'SoundWriteCast/SoundWriteCast.sv').read_text()
uncast=(base/'SoundWriteUncast/SoundWriteUncast.sv').read_text()
assert uncast.replace('SoundWriteUncast','SoundWriteCast').replace(needle,replacement)==cast
for addr in range(0x20100,0x30100):
    index=(addr-0x20100)>>1
    assert 0<=index<32768 and index==(index&0x7fff)
capture=root/'sim/captures/diagnostics/sound_write_width'
capture.mkdir(parents=True,exist_ok=True)
jobs={
 'cast':dict(name='SoundWriteCast',run='20261010-185927-56504-dev-fast',cache='49fddc988ebc8dd665e6',cells=22027,registers=16396,bits=524288,map_exit=0,fit_exit=0,sta_exit=0,wrapper_exit=1,terminal_chunk='32cf02'),
 'uncast':dict(name='SoundWriteUncast',run='20261010-190433-38544-dev-fast',cache='e260bc6151deecad2146',cells=753954,registers=540698,bits=0,map_exit=0,fit_exit='cancelled_numeric_exit_not_exposed',sta_exit='not_run',wrapper_exit=1,terminal_chunk='fa45b8')}
for kind,j in jobs.items():
    run=Path(r'C:\Users\meath\QuartusFast\runs')/j['run']
    cache=Path(r'C:\Users\meath\QuartusFast\cache')/j['cache']/'dev-fast-check'
    rpt=cache/'output_files'/(j['name']+'.map.rpt')
    text=rpt.read_text(errors='replace')
    log=(run/'map.log').read_text(errors='replace')
    assert 'Analysis & Synthesis was successful' in log
    assert f'Implemented {j["cells"]} logic cells' in log
    assert re.search(r'; Total registers\s*;\s*'+str(j['registers'])+r'\s*;',text)
    assert re.search(r'; Total block memory bits\s*;\s*'+str(j['bits'])+r'\s*;',text)
    j['files']=[]
    files=[rpt,run/'map.log',run/'fit.log',cache/(j['name']+'.qsf')]
    if kind=='cast': files += [run/'sta.log',cache/'output_files'/(j['name']+'.fit.rpt')]
    for p in files:
        assert p.exists(),str(p)
        dest=capture/(kind+'_'+p.name)
        shutil.copyfile(p,dest)
        assert sha(p)==sha(dest)
        j['files'].append(dict(original=str(p),recovery=str(dest),sha256=sha(p)))
    j['decisive_report_lines']=[dict(line=i,line_text=line.strip()) for i,line in enumerate(text.splitlines(),1) if any(s in line for s in ['Total registers','Total block memory bits','Estimate of Logic utilization','32768:1','SoundWidthMemory:memory|sound_rom','RAM Summary'])][:22]
cancel=json.loads((base/'uncast_owned_cancel.json').read_text(encoding='utf-8-sig'))
assert cancel['leaf_id']==22012 and cancel['parent_id']==38544 and not cancel['unrelated_jobs_touched']
result=dict(status='matched_actual_terminal_inference_proof',canonical_hardware_commit='6dfeca51f027e5d431f4ebe68c58f7a3a5df9a68',source_pins=prepared,only_candidate_delta='explicit15-bit sound-ROM loader write index; existing accepted range and all read/clock/CE/lane/NBA logic unchanged',exhaustive_accepted_range=dict(byte_addresses=65536,word_indices=32768,equal=True),exact_probe_source_join=True,jobs=jobs,uncast_cancellation=cancel,qualification_limits=['Probes omit other board memories/CPU; soundRAM conditional read stays uninferred in both twins.','Cast internal setup/hold do not qualify unconstrained external I/O. Wrapper1 despite native map/fit/STA0.','Uncast actualmap0, ownedfitcancelled, separateSTA notrun; no fitted-resource/timing pass.','Full production overlay check still required; canonical remains unchanged.','No assembly or RBF authorized/run.'])
(base/'matched_result.json').write_text(json.dumps(result,indent=2)+'\n')
(base/'matched_result.md').write_text('The full-depth matched sound-ROM probes differ only in the loader write index width (and top names). Cast actualmap0: 22,027 logic cells, 16,396 registers, 524,288 inferred memory bits. Uncast actualmap0: 753,954 logic cells, 540,698 registers, zero block-memory bits; its 32768:1 x16 mux consumes 349,520 LEs. The cast retains all 65,536 accepted byte addresses and 32,768 word indices exactly.\n\nCast leaf map/fit/STA all exit0; wrapper exit1 because I/O constraints and critical I/O warnings are unqualified. Uncast fitter PID22012, parent38544, was deliberately stopped after successful synthesis; wrapper exit1, separateSTA notrun. No assembly. This proves the isolated inference cause and supports the single-line private board candidate; it does not qualify the full production design.\n')
names=['prepared.json','board_write15.sv','board_write15.patch','matched_result.json','matched_result.md','uncast_owned_cancel.json','stop_uncast_owned.ps1','finalize.py']
for name in ['SoundWriteCast','SoundWriteUncast']:
    names += [str(p.relative_to(base)).replace('\\','/') for p in sorted((base/name).iterdir()) if p.suffix.lower() in ['.sv','.qpf','.qsf','.sdc']]
manifest=dict(status='ready_for_parent_import',files=[dict(staged=str(base/n),canonical_relative='research/sound_write_width/'+n,sha256=sha(base/n)) for n in names])
(base/'import_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps(dict(status=result['status'],manifest=str(base/'import_manifest.json'),sha256=sha(base/'import_manifest.json'),cast_cells=jobs['cast']['cells'],uncast_cells=jobs['uncast']['cells'],canonical_unchanged=True)))
