from pathlib import Path
import json,hashlib,shutil,re,collections
base=Path(__file__).resolve().parent
root=base.parents[1]
run=Path(r'C:\Users\meath\QuartusFast\runs\20261010-193713-46508-dev-fast')
cache=Path(r'C:\Users\meath\QuartusFast\cache\d20de4d4c2de9e666184\dev-fast-check')
canonical=Path(r'D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
launch=json.loads((base/'complete_overlay_launch.json').read_text())
after={relative:sha(canonical/relative) for relative in launch['canonical_source_pins']}
assert after==launch['canonical_source_pins']
assert sha(Path(launch['only_substitution']['actual_path']))==launch['only_substitution']['actual_sha256']
actual=json.loads((run/'result.json').read_text(encoding='utf-8-sig'))
assert actual['steps']['map']['exit_code']==0
assert 'sta' not in actual['steps'] and not actual['full'] and not actual['accepted']
report=cache/'output_files/Alpha68k_N.map.rpt'
text=report.read_text(errors='replace'); log=(run/'map.log').read_text(errors='replace')
assert 'Implemented 771962 logic cells' in log
assert re.search(r'; Total registers\s*;\s*548181\s*;',text)
assert re.search(r'; Estimate of Logic utilization \(ALMs needed\)\s*;\s*372510\s*;',text)
lines=text.splitlines()
start=next(i for i,l in enumerate(lines) if l.strip().startswith('; Analysis & Synthesis RAM Summary'))
ram=[dict(line=i+1,text=l.strip()) for i,l in enumerate(lines[start:start+180],start) if ';' in l and '|ALTSYNCRAM' in l]
assert ram and not any('sound_rom' in x['text'] for x in ram)
assert any('main_rom' in x['text'] for x in ram)
assert any('sound_ram' in x['text'] for x in ram)
deps=actual['dependencies']; canonical_prefix=str(canonical).lower()+'\\'
counts=collections.Counter(); totalbytes=0; changed=[]; roots=collections.Counter(); interesting=[]
for d in deps:
    p=Path(d['path']); low=str(p).lower(); totalbytes+=d['bytes']; counts[p.suffix.lower() or '<extensionless>']+=1
    if low.startswith(canonical_prefix):
        rel=p.relative_to(canonical); roots[rel.parts[0]]+=1
        if rel.parts[0].lower() in ['docs','research','sim'] and len(interesting)<25: interesting.append(str(p))
    if '4401' in low: interesting.append(str(p))
    try:
        stat=p.stat()
        if stat.st_size!=d['bytes'] or stat.st_mtime_ns!=d['mtime_ns']:
            item=dict(path=str(p),old_bytes=d['bytes'],current_bytes=stat.st_size,mtime_changed=stat.st_mtime_ns!=d['mtime_ns'])
            if stat.st_size<=10000000:item['current_sha256']=sha(p);item['hash_changed']=item['current_sha256']!=d['sha256']
            else:item['hash_changed']='not_rehashed_large_nonhardware_input'
            changed.append(item)
    except FileNotFoundError:changed.append(dict(path=str(p),status='missing_after_run'))
capture=root/'sim/captures/diagnostics/board15_complete_failure';capture.mkdir(parents=True,exist_ok=True)
files=[run/'result.json',run/'map.log',run/'fit.log',report,cache/'Alpha68k_N.qsf']
recover=[]
for p in files:
    dest=capture/p.name;shutil.copyfile(p,dest);assert sha(p)==sha(dest)
    recover.append(dict(original=str(p),recovery=str(dest),sha256=sha(p)))
cancel=json.loads((base/'board15_owned_cancel.json').read_text(encoding='utf-8-sig'))
assert cancel['leaf_id']==2840 and cancel['parent_id']==46508 and not cancel['unrelated_jobs_touched']
evidence=dict(status='complete15bit_only_candidate_failed_capacity',source_head=launch['hardware_frozen_head'],docs_head_at_launch=launch['current_docs_head'],source_mapping=launch['only_substitution'],canonical_161_pins_unchanged=True,canonical_after=after,actual_steps=actual['steps'],wrapper_exit=1,wrapper_terminal_chunk='81b743',owned_fit_cancel=cancel,sta='not_run',assembly='not_authorized_not_run',map=dict(exit_code=0,logic_cells=771962,registers=548181,estimated_ALMs=372510,block_memory_bits=1915224,RAM_segments=1299,DSP_elements=41,sound_ROM_inferred=False,healthy_RAM_rows=ram),dependencies=dict(count=len(deps),bytes=totalbytes,dependencies_complete=actual['dependencies_complete'],canonical_first_component_counts=dict(roots),suffix_counts=dict(counts),sample_scope_paths=interesting[:35],metadata_changed_paths=changed,terminal_full_rehash='Not performed: frontend takes failure branch after deliberately cancelled fit. Hardware161pins independently rechecked exact.'),recoveries=recover,limits=['Isolated cast inference success does not fix complete integration.','No fitted resource/routing metrics or timing pass. All7finalgates unqualified.','ExternalSDRAM I/O/device/PCB timing remains unqualified.','Source cause beyond width requires responsible-layer full-context diagnosis; no newlaunch authorized by thisreceipt.'])
(base/'complete_result.json').write_text(json.dumps(evidence,indent=2)+'\n')
(base/'complete_result.md').write_text('The complete private board15-bit-only candidate actualmap0 still has 771,962 logic cells, 548,181 registers and 372,510 estimated ALMs. Sound ROM is absent from the authentic RAM summary; main ROM, sound RAM, work/strip banks and video memories remain inferred. The isolated write-width result does not transfer to full integration.\n\nOnly our verified fitterPID2840 (parent46508) was deliberately stopped after the gross capacity result. Wrapper actualexit1, separateSTA and assembly notrun. All161canonicalhardwarepins and the private board candidate hash are unchanged. This is a source-bound capacity failure, not a fitted-resource or timing pass. Result JSON records the frontend dependency inventory and any metadata changes separately from hardware pins.\n')
names=['complete_overlay_launch.json','prepare_overlay.py','complete_result.json','complete_result.md','stop_board15_owned.ps1','board15_owned_cancel.json','finalize_complete.py']
manifest=dict(status='ready_for_parent_import',files=[dict(staged=str(base/n),canonical_relative='research/sound_write_width/'+n,sha256=sha(base/n)) for n in names])
(base/'complete_import_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps(dict(status=evidence['status'],manifest=str(base/'complete_import_manifest.json'),manifest_sha256=sha(base/'complete_import_manifest.json'),report_sha256=sha(report),actual_steps={k:v['exit_code'] for k,v in actual['steps'].items()},canonical_161_unchanged=True,dependency_count=len(deps),dependency_bytes=totalbytes,canonical_categories=dict(roots),changed_metadata_count=len(changed),changed_metadata_paths=[x['path'] for x in changed[:8]])))
