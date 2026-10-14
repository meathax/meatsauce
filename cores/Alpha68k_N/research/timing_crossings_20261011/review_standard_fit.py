import pathlib,json,hashlib,re,csv
folder=pathlib.Path(r'D:\Arcade\AI\aCORES\Alpha68k N\research\sound_write_width\case2_standard_fit_evidence')
out=pathlib.Path(__file__).parent
manifest=folder/'standard_fit_sta_import_manifest.json'
expected='fb9e62a0013236e248a6f4be11f056171755dabe7bfe52cd66ca43689fecfb90'
assert hashlib.sha256(manifest.read_bytes()).hexdigest()==expected
doc=json.loads(manifest.read_text(encoding='utf-8'))
checked=[]
for group in ['files','reports','recovery_references']:
 for entry in doc.get(group,[]):
  p=pathlib.Path(entry['path']);data=p.read_bytes()
  assert hashlib.sha256(data).hexdigest()==entry['sha256'],str(p)
  if 'bytes' in entry:assert len(data)==entry['bytes'],str(p)
  checked.append({'group':group,'path':str(p),'sha256':entry['sha256'],'bytes':len(data)})
print('MANIFEST',list(doc),{k:len(v) for k,v in doc.items() if isinstance(v,list)},'verified',len(checked))
result={'manifest_sha256':expected,'manifest_files_verified':checked,'timing':{},'metadata':{},'ucp':{}}
for name in ['source_binding.json','native_fit_result.json','fit_sta_result.json']:
 p=folder/name;data=json.loads(p.read_text(encoding='utf-8'))
 result['metadata'][name]={'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'data':data}
 print('METADATA',name,list(data))
 if name=='source_binding.json':print(json.dumps(data))
for corner in sorted((folder/'all-corners').glob('corner_*')):
 condition=(corner/'condition.txt').read_text().strip()
 for kind in ['setup','hold','recovery','removal','same_game_setup','same_game_hold','same_audio_setup','same_audio_hold']:
  p=corner/(kind+'.txt');lines=p.read_text(errors='replace').splitlines();rows=[];summary=False
  for lineno,line in enumerate(lines,1):
   if 'Summary of Paths' in line:summary=True
   if 'Path #1:' in line:break
   cols=[c.strip() for c in line.split(';')[1:-1]]
   if summary and len(cols)==8 and re.fullmatch(r'-?\d+\.\d+',cols[0]):rows.append({'line':lineno,'slack':float(cols[0]),'from':cols[1],'to':cols[2],'launch_clock':cols[3],'latch_clock':cols[4],'relationship':cols[5],'skew':cols[6],'data_delay':cols[7]})
  assert rows,(str(p),'No summary paths')
  assert min(r['slack'] for r in rows)>0,(str(p),'Failed timing')
  result['timing'][corner.name+'/'+kind]={'condition':condition,'path':str(p),'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'rows':rows}
 p=corner/'unconstrained.txt';lines=p.read_text(errors='replace').splitlines()
 ucp=[(i+1,l) for i,l in enumerate(lines) if re.search('Unconstrained (?:Clocks|Input Ports|Input Port Paths|Output Ports|Output Port Paths)|Illegal Clocks',l)]
 result['ucp'][corner.name]={'path':str(p),'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'summary_lines':ucp}
for kind in ['setup','hold','recovery','removal','same_game_setup','same_game_hold','same_audio_setup','same_audio_hold']:
 groups=[(k,d) for k,d in result['timing'].items() if k.endswith('/'+kind)]
 key,d=min(groups,key=lambda pair:pair[1]['rows'][0]['slack'])
 print('WORST',key,d['condition'],json.dumps(d['rows'][0]))
print('UCP',json.dumps(result['ucp']['corner_1']))
p=out/'standard_fit_independent_review.json'
assert not p.exists(),'Preserve independent review'
p.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
print('RESULT',p,hashlib.sha256(p.read_bytes()).hexdigest())
