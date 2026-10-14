import pathlib,re,json,hashlib
root=pathlib.Path(r'D:\Arcade\AI\aCORES\Alpha68k N\research\sound_write_width')
old=root/'case2_full_map';new=root/'case2_standard_fit';out=pathlib.Path(__file__).parent
pattern=re.compile(r'^set_global_assignment -name (SYSTEMVERILOG_FILE|VERILOG_FILE|VHDL_FILE|SDC_FILE) ("[^"]+"|\S+)')
def pins(base):
 qsf=base/'Alpha68k_N.qsf';text=qsf.read_text(errors='strict');result=[]
 for lineno,line in enumerate(text.splitlines(),1):
  m=pattern.match(line)
  if not m:continue
  p=pathlib.Path(m[2].strip('"'))
  if not p.is_absolute():p=base/p
  data=p.read_bytes()
  result.append({'kind':m[1],'qsf_line':lineno,'path':str(p),'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()})
 return qsf,text,result
old_qsf,old_text,old_pins=pins(old);new_qsf,new_text,new_pins=pins(new)
old_rtl=[p for p in old_pins if p['kind']!='SDC_FILE'];new_rtl=[p for p in new_pins if p['kind']!='SDC_FILE']
assert len(old_rtl)==len(new_rtl)==114,(len(old_rtl),len(new_rtl))
assert [(p['kind'],p['sha256'],p['bytes']) for p in old_rtl]==[(p['kind'],p['sha256'],p['bytes']) for p in new_rtl],'Source pin mismatch'
old_sdc=[p for p in old_pins if p['kind']=='SDC_FILE'];new_sdc=[p for p in new_pins if p['kind']=='SDC_FILE']
assert len(old_sdc)==2 and len(new_sdc)==3
assert [p['sha256'] for p in old_sdc]==[p['sha256'] for p in new_sdc[:2]]
group=out/'game_clock_group_candidate.sdc';sha=hashlib.sha256(group.read_bytes()).hexdigest()
assert sha==new_sdc[-1]['sha256']=='8ef8f941d4c769a0bca7fbafd5aeb04de2c8eee1e4ec4151c02732fdc61c0d8a'
normalized=new_text.replace(str(new).replace('\\','/'),str(old).replace('\\','/'))
remove=[l for l in old_text.splitlines() if l not in normalized.splitlines()]
add=[l for l in normalized.splitlines() if l not in old_text.splitlines()]
assert len(remove)==3 and all('FAST' in l for l in remove),remove
assert len(add)==1 and 'SDC_FILE' in add[0],add
prepared=root/'standard_fit_prepared.json'
assert hashlib.sha256(prepared.read_bytes()).hexdigest()=='476213d608867386bacf71dd4c5832d4d62f05cfb80982714f960cd7460816f5'
closure=json.loads(prepared.read_text(encoding='utf-8'))['source_pins_161']
assert len(closure)==161
closure_checked=[]
for entry in closure:
 p=pathlib.Path(entry['path']);relative=p.relative_to(new/'source');original=old/'source'/relative
 assert hashlib.sha256(p.read_bytes()).hexdigest()==entry['sha256'],str(p)
 assert hashlib.sha256(original.read_bytes()).hexdigest()==entry['sha256'],str(original)
 closure_checked.append({'relative':str(relative),'sha256':entry['sha256']})
critical_source=old/'source/sys/vga_out.sv';vga_raw=critical_source.read_bytes()
critical_lines=[(i+1,line) for i,line in enumerate(vga_raw.decode('utf-8').splitlines()) if re.search('pb_1r|posedge|de_out',line)]
result={'status':'independent_source_and_exception_review_pass','original_qsf_sha256':hashlib.sha256(old_qsf.read_bytes()).hexdigest(),'standard_qsf_sha256':hashlib.sha256(new_qsf.read_bytes()).hexdigest(),'hdl_assignment_count':114,'all114_assigned_hdl_bytes_identical':True,'frozen_source_closure_count':161,'all161_closure_bytes_identical':True,'original_two_sdc_identical':True,'only_removed_qsf_lines':remove,'only_added_qsf_lines':add,'candidate_sdc_sha256':sha,'old_pins':old_pins,'standard_pins':new_pins,'closure_verified':closure_checked,'critical_framework_source':{'path':str(critical_source),'sha256':hashlib.sha256(vga_raw).hexdigest(),'lines':critical_lines},'prior_failed_assumption':'First invocation expected 161 HDL assignments; actual 114 HDL plus 161 broader frozen source-file closure. No review result was emitted from that failure.','limit':'Clock groups restore reviewed boundaries; no physical I/O, metastability or replay acceptance from this check.'}
p=out/'standard_binding_independent_review.json';assert not p.exists(),'Preserve frozen review'
p.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
print(json.dumps({k:v for k,v in result.items() if k not in ('old_pins','standard_pins','closure_verified')}))
print('RESULT',p,hashlib.sha256(p.read_bytes()).hexdigest())
