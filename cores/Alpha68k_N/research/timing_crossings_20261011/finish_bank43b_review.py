import pathlib,json,hashlib,re,collections
out=pathlib.Path(__file__).parent
base=out.parent/'joined_rom_inference_v2'
folder=base/'fit_sta_evidence'
prior=out.parent/'sound_write_width/case2_standard_fit_evidence'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def load(p):return json.loads(p.read_text())
review=out/'bank43b_independent_review.json'
assert sha(review)=='3601435db68fcec180d972bb1b8ee023123acaadf46f61db10d56371d1de4541'
d=load(review)
delta=d['ucp']['corner_1']['delta']
summary={}
for kind,entries in delta.items():
    portcol=0 if kind=='input_paths' else 1
    summary[kind]={}
    for change,rows in entries.items():
        counts=collections.Counter(row[portcol] if kind.endswith('_paths') else row[0] for row in rows)
        summary[kind][change]={'count':len(rows),'ports':dict(counts),'examples':rows[:4]}
        print('DELTA',kind,change,len(rows),json.dumps(dict(counts)),json.dumps(rows[:2]))
clocks=[]
for corner in sorted((folder/'all-corners').glob('corner_*')):
    matching=[p for p in corner.glob('*.txt') if 'clock' in p.name.lower() and 'group' not in p.name.lower()]
    assert len(matching)==1,(corner,matching)
    p=matching[0];old=prior/'all-corners'/corner.name/p.name
    assert p.read_bytes()==old.read_bytes(),p
    clocks.append({'path':str(p),'sha256':sha(p),'identical_to_prior':True})
sysold={pathlib.Path(e['path']).name:e for e in load(out/'standard_binding_independent_review.json')['old_pins'] if '/sys/' in e['path'].replace('\\','/')}
syspins=[]
for e in load(base/'map_qualification.json')['mapped_source_pins_160']:
    if e['relative'].startswith('sys/') or e['relative'].startswith('sys\\'):
        old=sysold.get(pathlib.Path(e['relative']).name)
        if old:
            assert e['sha256']==old['sha256'],e['relative']
            syspins.append(e)
assert syspins
print('CLOCK_REPORTS_MATCH',len(clocks),'PINNED_SYS_ASSIGNMENTS_SAME',len(syspins))
codes=collections.Counter(x['code'] for x in d['warnings'])
for code in sorted(codes):
    examples=[x for x in d['warnings'] if x['code']==code]
    print('WARNING',code,codes[code],examples[0]['text'][:260])
print('GATES',json.dumps(d['resource_gates']))
sta=load(folder/'fit_sta_result.json')
print('STA_KEYS',list(sta))
result={'scope':'Supplement only; immutable first-pass review retained','review_sha256':sha(review),'ucp_delta_by_pad':summary,'all_eight_clock_reports_identical':clocks,'pinned_framework_assignment_bytes_identical':syspins,'fit_warning_delta':d['warning_delta'],'native_fit_warning_counts':d['native_fit_warning_counts'],'native_STA_warning_count':1264}
p=out/'bank43b_review_supplement.json';assert not p.exists();p.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
print('SUPPLEMENT',p,sha(p))
