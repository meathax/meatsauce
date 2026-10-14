import pathlib,json,hashlib,re,collections
out=pathlib.Path(__file__).parent
base=out.parent/'joined_rom_inference_v2'
folder=base/'fit_sta_evidence'
prior=out.parent/'sound_write_width/case2_standard_fit_evidence'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def load(p):return json.loads(p.read_text(encoding='utf-8'))
verified=[]
def verify_record(e):
    p=pathlib.Path(e['path']);assert sha(p)==e['sha256'],str(p)
    if 'bytes' in e:assert len(p.read_bytes())==e['bytes'],str(p)
    verified.append({'path':str(p),'sha256':e['sha256']})
manifest=folder/'fit_sta_import_manifest.json'
assert sha(manifest)=='cff90bd44f912151aea1770d0d67f5b610c6d1af8811b165f442e83351c26d30'
for e in load(manifest)['files']:verify_record(e)
for e in load(folder/'fit_import_manifest.json').get('files',[]):verify_record(e)
mapq=load(base/'map_qualification.json')
assert sha(base/'map_qualification.json')=='4f3a6d15a146a7b3d1880de0fdd7ba097bb2437c8c5429d9a37e1db991cfff6b'
for e in mapq['mapped_source_pins_160']:verify_record(e)
origin=base/'diagnostic_prepared.json'
assert sha(origin)==mapq['preparation_sha256']
for e in load(origin)['source_pins_161']:verify_record(e)
for e in mapq['copies']:verify_record(e)
workspace=pathlib.Path(mapq['workspace'])
assert sha(workspace/'Alpha68k_N.qsf')==mapq['effective_qsf_sha256']=='029436ac2cc7a389bd9b0bae4f2d89fef205a7318d0ff5abc5f988a5d254be5a'
qsf=(workspace/'Alpha68k_N.qsf').read_text()
sdcrows=re.findall(r'^set_global_assignment -name SDC_FILE (.+)$',qsf,re.M)
sdcfiles=[pathlib.Path(re.match(r'"([^"]+)"|([^\s]+)',x).group(1) or re.match(r'"([^"]+)"|([^\s]+)',x).group(2)) for x in sdcrows]
assert any(sha(p)=='8ef8f941d4c769a0bca7fbafd5aeb04de2c8eee1e4ec4151c02732fdc61c0d8a' for p in sdcfiles)
assert re.search(r'^set_global_assignment -name GENERATE_RBF_FILE OFF$',qsf,re.M)
fit=load(folder/'native_fit_result.json')
assert fit['actual_exit']==0 and fit['all7_resource_pass'] and not fit['critical_warnings']
fittext=(folder/'Alpha68k_N.fit.rpt').read_text(errors='replace')
for row in fit['resource_rows']:assert row in fittext,row
for name,gate in fit['resource_gates'].items():
    # Native exact report rows are pinned above. Preserve full gate operands.
    assert isinstance(gate,(dict,bool)),name
sta=load(folder/'fit_sta_result.json')
timing={};ucp={};clocks={}
labels={'Unconstrained Input Ports':'input_ports','Unconstrained Output Ports':'output_ports','Unconstrained Input Port Paths':'input_paths','Unconstrained Output Port Paths':'output_paths'}
def census(p):
    tables={k:set() for k in labels.values()};section=None;headers=[]
    for line in p.read_text(errors='replace').splitlines():
        cols=[c.strip() for c in line.split(';')[1:-1]]
        if len(cols)==1 and ('Unconstrained' in cols[0] or 'Clock Status' in cols[0]):
            headers.append(cols[0]);section=labels.get(cols[0]);continue
        if not section:continue
        if section.endswith('_ports') and len(cols)==2 and cols[0] not in ('Input Port','Output Port'):tables[section].add(tuple(cols))
        elif section.endswith('_paths') and len(cols)==3 and cols[0]!='From':tables[section].add(tuple(cols))
    return tables,headers
old,oldheaders=census(prior/'all-corners/corner_1/unconstrained.txt')
assert {k:len(v) for k,v in old.items()}==dict(input_ports=20,output_ports=85,input_paths=30,output_paths=149)
kinds=['setup','hold','recovery','removal','same_game_setup','same_game_hold','same_audio_setup','same_audio_hold']
corners=sorted((folder/'all-corners').glob('corner_*'));assert len(corners)==8
for corner in corners:
    condition=(corner/'condition.txt').read_text().strip()
    for kind in kinds:
        p=corner/(kind+'.txt');rows=[];summary=False
        for lineno,line in enumerate(p.read_text(errors='replace').splitlines(),1):
            if 'Summary of Paths' in line:summary=True
            if 'Path #1:' in line:break
            cols=[c.strip() for c in line.split(';')[1:-1]]
            if summary and len(cols)==8 and re.fullmatch(r'-?\d+\.\d+',cols[0]):rows.append({'line':lineno,'slack':float(cols[0]),'from':cols[1],'to':cols[2],'launch_clock':cols[3],'latch_clock':cols[4],'relationship':cols[5],'skew':cols[6],'data_delay':cols[7]})
        assert rows and all(r['slack']>0 for r in rows),(str(p),rows)
        timing[corner.name+'/'+kind]={'path':str(p),'sha256':sha(p),'condition':condition,'rows':rows}
    cur,headers=census(corner/'unconstrained.txt')
    assert {k:len(v) for k,v in cur.items()}==dict(input_ports=20,output_ports=85,input_paths=30,output_paths=149)
    assert not any('Internal' in h for h in headers)
    delta={k:{'added':sorted(cur[k]-old[k]),'removed':sorted(old[k]-cur[k])} for k in cur}
    normalize=lambda row:tuple(re.sub(r'~FF_\d+','~FF_<fit_atom>',x) for x in row)
    normalized_equal={k:{normalize(x) for x in cur[k]}=={normalize(x) for x in old[k]} for k in cur}
    ucp[corner.name]={'path':str(corner/'unconstrained.txt'),'sha256':sha(corner/'unconstrained.txt'),'counts':{k:len(v) for k,v in cur.items()},'delta':delta,'normalized_equal':normalized_equal,'headers':headers}
    # Exact matching reports prove the inherited clock inventory/group scope.
    for name in ['clocks.txt','inherited_clock_groups.txt']:
        p=corner/name
        if not p.exists():continue
        oldp=prior/'all-corners'/corner.name/name
        assert p.read_bytes()==oldp.read_bytes(),str(p)
        clocks[corner.name+'/'+name]={'path':str(p),'sha256':sha(p),'identical_to_baseline':True}
def warnings(text):
    rows=[]
    for i,line in enumerate(text.splitlines(),1):
        m=re.search(r'((?:Critical )?Warning) \((\d+)\):\s*(.*)',line)
        if m:rows.append({'line':i,'severity':m[1],'code':m[2],'text':m[3].strip(' ;')})
    return rows
newwarnings=warnings(fittext)
oldrecord=next(e for e in load(out/'standard_fit_independent_review.json')['manifest_files_verified'] if e['path'].endswith('Alpha68k_N.fit.rpt'))
verify_record(oldrecord)
oldwarnings=warnings(pathlib.Path(oldrecord['path']).read_text(errors='replace'))
nc=collections.Counter(x['code'] for x in newwarnings);oc=collections.Counter(x['code'] for x in oldwarnings)
warningdelta={k:{'before':oc[k],'after':nc[k],'examples':[x for x in newwarnings if x['code']==k][:3]} for k in sorted(set(nc)|set(oc)) if nc[k]!=oc[k]}
worst={kind:min((v for k,v in timing.items() if k.endswith('/'+kind)),key=lambda d:d['rows'][0]['slack']) for kind in kinds}
data={'scope':'Independent report/source qualification of frozen bank43b STANDARD fit; external I/O and false-pathed CDC physical qualification remain open; no jobs or source/constraint edits','producer_manifest':{'path':str(manifest),'sha256':sha(manifest)},'verified_files':verified,'source_counts':{'mapped':160,'origin':161},'qsf_sha256':mapq['effective_qsf_sha256'],'sdc_assignments':[{'path':str(p),'sha256':sha(p)} for p in sdcfiles],'resource_gates':fit['resource_gates'],'timing':timing,'worst':worst,'ucp':ucp,'clock_equality':clocks,'warnings':newwarnings,'warning_delta':warningdelta,'native_fit_warning_counts':fit['warning_counts_by_code'],'native_STA_total_warnings':1264,'release_accepted':False}
p=out/'bank43b_independent_review.json';assert not p.exists();p.write_text(json.dumps(data,indent=2)+'\n',encoding='utf-8')
print('PASS FILES',len(verified),'SOURCE160+161','SDC',len(sdcfiles),'TIMED_TABLES',len(timing))
for kind,v in worst.items():print('WORST',kind,v['condition'],json.dumps(v['rows'][0]))
print('UCP_DELTA',json.dumps(ucp['corner_1']['delta']))
print('UCP_NORMALIZED_EQUAL',json.dumps(ucp['corner_1']['normalized_equal']))
print('CLOCK_EQUALITY',len(clocks))
print('WARN_DELTA',json.dumps(warningdelta))
print('RESOURCES',json.dumps(fit['resource_gates']))
print('RESULT',p,sha(p))
