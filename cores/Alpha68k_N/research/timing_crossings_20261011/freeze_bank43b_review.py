import pathlib,json,hashlib
out=pathlib.Path(__file__).parent
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def load(p):return json.loads(p.read_text())
review=load(out/'bank43b_independent_review.json')
supp=load(out/'bank43b_review_supplement.json')
assert supp['review_sha256']==sha(out/'bank43b_independent_review.json')=='3601435db68fcec180d972bb1b8ee023123acaadf46f61db10d56371d1de4541'
assert len(supp['all_eight_clock_reports_identical'])==8
assert len(review['clock_equality'])==8
for e in review['verified_files']+supp['all_eight_clock_reports_identical']+supp['pinned_framework_assignment_bytes_identical']:
    assert sha(pathlib.Path(e['path']))==e['sha256'],e['path']
for corner,d in review['ucp'].items():
    assert d['delta']==review['ucp']['corner_1']['delta'],corner
    assert all(d['normalized_equal'][k] for k in ['input_ports','output_ports','input_paths'])
assert set(supp['ucp_delta_by_pad']['output_paths']['added']['ports'])==set(supp['ucp_delta_by_pad']['output_paths']['removed']['ports'])
assert supp['ucp_delta_by_pad']['output_paths']['added']['count']==supp['ucp_delta_by_pad']['output_paths']['removed']['count']==38
assert not review['warning_delta']
old={pathlib.Path(e['path']).name:e for e in load(out/'standard_binding_independent_review.json')['old_pins']}
base=out.parent/'joined_rom_inference_v2'
unchanged=[]
for e in load(base/'map_qualification.json')['mapped_source_pins_160']:
    name=pathlib.Path(e['relative']).name
    if 'gfxmem' in name or 'jtframe_sdram' in e['relative']:
        assert old[name]['sha256']==e['sha256'],e['relative']
        assert sha(pathlib.Path(e['path']))==e['sha256']
        unchanged.append(e)
assert {'alpha68kn_gfxmem.sv','jtframe_sdram64.v','jtframe_sdram64_bank.v','jtframe_sdram64_latch.v'} <= {pathlib.Path(e['relative']).name for e in unchanged}
sta=load(base/'fit_sta_evidence/fit_sta_result.json')
assert sta['actual_sta_exit']==0
assert sta['minimum_pulse_width_worst_slack_ns']==1.041
closure=out/'bank43b_final_closure.json';assert not closure.exists()
closure.write_text(json.dumps({'source_and_report_records_verified':len(review['verified_files']),'unchanged_gfxmem_and_sdram_source_pins':unchanged,'all_eight_ucp_deltas_identical':True,'exact_pad_classes_unchanged':True,'clock_inventory_and_groups_each_eight_identical':True,'fit_warning_code_count_delta':{},'native_STA_terminal':{'actual_exit':sta['actual_sta_exit'],'chunk':sta['terminal_chunk']},'minimum_pulse_width_ns':sta['minimum_pulse_width_worst_slack_ns'],'overall_release_accepted':False},indent=2)+'\n',encoding='utf-8')
names=['review_bank43b.py','finish_bank43b_review.py','freeze_bank43b_review.py','bank43b_independent_review.json','bank43b_review_supplement.json','bank43b_review_recommendation.md',closure.name]
manifest=out/'bank43b_review_import_manifest.json';assert not manifest.exists()
manifest.write_text(json.dumps({'scope':'Independent frozen bank43b timed FIT/resource approval; external I/O/release acceptance open; no compiler jobs or production changes','producer_manifest':review['producer_manifest'],'files':[{'path':str(out/n),'sha256':sha(out/n)} for n in names]},indent=2)+'\n',encoding='utf-8')
print('PASS final frozen closure; unchanged SDRAM/gfxmem',len(unchanged),'sources; clock inventories/groups 8+8; UCP all8 same delta')
print('MANIFEST',manifest,sha(manifest))
print('RECOMMENDATION',sha(out/'bank43b_review_recommendation.md'))
print('SUPPLEMENT',sha(out/'bank43b_review_supplement.json'))
