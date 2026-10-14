import pathlib,json,hashlib
folder=pathlib.Path(__file__).parent
expected={
 'standard_fit_independent_review.json':'8ffa4f08b5e1c509272259ebddc5b2dc539e70d7b457de238d5934f361d100ba',
 'standard_binding_independent_review.json':'238c2bb80494e7ad0ee70deea0fa9dc9635843a5982658595f31fd22f3efa447',
 'game_clock_group_candidate.sdc':'8ef8f941d4c769a0bca7fbafd5aeb04de2c8eee1e4ec4151c02732fdc61c0d8a',
}
files=[]
for name in list(expected)+['standard_review_recommendation.md','review_standard_fit.py','verify_standard_bindings.py','freeze_standard_review.py']:
 p=folder/name;raw=p.read_bytes();sha=hashlib.sha256(raw).hexdigest()
 if name in expected:assert sha==expected[name],name
 files.append({'path':str(p),'sha256':sha,'bytes':len(raw)})
review=json.loads((folder/'standard_fit_independent_review.json').read_text())
binding=json.loads((folder/'standard_binding_independent_review.json').read_text())
assert len(review['manifest_files_verified'])==108 and len(review['timing'])==64
assert binding['all114_assigned_hdl_bytes_identical'] and binding['all161_closure_bytes_identical']
record={'status':'independent_STANDARD_FIT_internal_timing_review_pass','producer_manifest_sha256':review['manifest_sha256'],'operating_conditions':8,'timed_check_tables_verified':64,'producer_artifacts_independently_verified':108,'hdl_assignments_verified':114,'frozen_source_closure_verified':161,'source_changes':False,'compiler_jobs_launched':False,'core_group_overlay_reviewed':True,'reset_and_audio_optional_proposals_integrated':False,'external_IO_and_CDC_hardware_gate':'OPEN','overall_release_timing_accepted':False,'files':files}
p=folder/'standard_review_import_manifest.json';assert not p.exists(),'Preserve frozen manifest'
p.write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
print(json.dumps({'manifest':str(p),'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'files':len(files),'verified_reports':108,'timed_tables':64,'overall_release_timing_accepted':False}))
