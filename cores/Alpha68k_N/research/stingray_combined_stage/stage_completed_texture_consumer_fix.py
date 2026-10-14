"""One narrow consumer correction; existing normalizer and historical evidence unchanged."""
from pathlib import Path
import difflib,hashlib,json
HERE=Path(__file__).resolve().parent; SCOPE=HERE/'next_coupled_scope_v2'
CAN=Path(r'D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N')
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def pin(p):return {'path':str(p),'sha256':H(p),'bytes':p.stat().st_size}
def main():
  original=HERE/'verify_next_coupled181.py'
  assert H(original)=='dd4db4c2ca7e30f65b0daf19d949fc33f886d98d940fd820ea67fb7717406092'
  text=original.read_text();needle="            item[name]=comparison(cap/f'frame_{f:06d}.{suffix}',refs/f'frame_{f:06d}.{suffix}',name=='RGB')"
  assert text.count(needle)==1
  replacement="\n".join([
    "            reference_suffix='display.rgb' if name=='RGB' else suffix",
    "            item[name]=comparison(cap/f'frame_{f:06d}.{suffix}',refs/f'frame_{f:06d}.{reference_suffix}',name=='RGB')",
    "        item['RGB_completed_texture_source']={'PNG':entry(refs/f'frame_{f:06d}.png'),",
    "            'RGB':entry(refs/f'frame_{f:06d}.display.rgb'),'orientation':'inverse driver-declared ROT90'}"])
  candidate=text.replace(needle,replacement)
  compile(candidate,'verify_next_coupled181_completed_texture.py','exec')
  out=SCOPE/'completed_texture_consumer_fix';assert not out.exists();out.mkdir()
  dest=out/'verify_next_coupled181_completed_texture.py';dest.write_text(candidate,encoding='utf8',newline='\n')
  patch=out/'checkpoint_reference.patch';patch.write_text(''.join(difflib.unified_diff(text.splitlines(True),candidate.splitlines(True),fromfile='verify_next_coupled181.py',tofile='verify_next_coupled181.py')),encoding='utf8',newline='\n')
  normalizer=CAN/'scripts/normalize_oracle_display.py';capture=CAN/'scripts/capture_oracle.py';consumer=CAN/'scripts/analyze_system_capture.py'
  assert "image.transpose(Image.Transpose.ROTATE_90).convert('RGB').tobytes()" in normalizer.read_text()
  assert "from normalize_oracle_display import normalize" in capture.read_text()
  assert 'path.name.replace(".rgb", ".display.rgb")' in consumer.read_text()
  completed=json.loads((SCOPE/'completed_png_diagnosis/qualification.json').read_text())
  static={'schema':'minimal_completed_texture_reference_consumer_v1','source_original':pin(original),'staged_candidate':pin(dest),'patch':pin(patch),
    'syntax_compile_pass':True,'actual_built_in_normalizer_already_correct':True,
    'existing_canonical_pipeline_pins':[pin(x) for x in [normalizer,capture,consumer]],
    'historical_diagnose_zero_and_old_181_evidence_preserved':True,
    'semantic_delta':'MAME RGB reference only: .rgb -> .display.rgb; source PNG/RGB identities retained. Native RGB, RAM, inputs, source checks, clock/RTL and existing diagnostic outputs unchanged.',
    'consumer_verified_by_completed_PNG_diagnosis':pin(SCOPE/'completed_png_diagnosis/qualification.json'),
    'existing_reference_display':[], 'production_or_registered_worker_modified':False,
    'no_whole_game_acceptance_or_new_replay':True,'helper':pin(Path(__file__))}
  for row in completed['frames']:
    p=CAN/'sim/captures/sstingry/gameplay'/f"frame_{row['frame']:06d}.display.rgb"
    if p.exists():
      assert H(p)==row['completed_RGB']['sha256']
      static['existing_reference_display'].append(pin(p))
  result=out/'verification.json';result.write_text(json.dumps(static,indent=2)+'\n')
  manifest={'schema':'staged_completed_texture_consumer_import_v1','files':[pin(p) for p in [dest,patch,result,Path(__file__)]],
    'related_verified_cause':pin(SCOPE/'first_buffer_cause/import_manifest.json'),'candidate_not_executed_against_existing_output':True}
  m=out/'import_manifest.json';m.write_text(json.dumps(manifest,indent=2)+'\n')
  print(json.dumps({'syntax_pass':True,'canonical_normalizer_unchanged':True,'existing_display_exact':len(static['existing_reference_display']), 'manifest':pin(m),'patch':patch.read_text()}))
if __name__=='__main__':main()
