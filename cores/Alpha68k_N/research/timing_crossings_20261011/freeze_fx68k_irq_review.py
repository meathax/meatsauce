import pathlib,json,hashlib
out=pathlib.Path(__file__).parent
stage=out.parent/'mame_cutoff_observer_stage'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def load(p):return json.loads(p.read_text())
pins={
 stage/'vpa_overlay_recipe1/corrected_consumer3/import_manifest.json':'ee8d02512cfa2123b17589706f7d986e335c4019495dbb0681e28e30f03066f4',
 stage/'first_irq_native57_released1/compact_cause/import_manifest.json':'42241e6f7f07e770150465b7579dedddbd8459b2b27ae3ea65b94f50e9e16a9d',
 stage/'first_irq_native57_proposal/source_contract.json':'b6f6d81259cd4f3f5a248955c0dbd57158fb1d1d6ffd67075fb0f7fce1511e80',
 stage/'manual_e_vpa/import_manifest.json':'89b21154749869faa0ea49e07bcca96964363d1690e99dc3eca7003122ed1401',
}
for p,h in pins.items():assert sha(p)==h,str(p)
verified=[]
for name in ['first_irq_native57_released1/compact_cause/import_manifest.json','manual_e_vpa/import_manifest.json']:
    d=load(stage/name)
    for e in d.get('entries',d.get('files',[])):
        p=pathlib.Path(e['path']);assert sha(p)==e['sha256'],str(p)
        verified.append(e)
c=load(stage/'first_irq_native57_proposal/source_contract.json')
for key in ['FX_E_VPA','board','MAME_E_timed_not_fixed_cycle']:
    e=c[key]['source'];p=pathlib.Path(e['path']);assert sha(p)==e['sha256'];verified.append(e)
fx=pathlib.Path(c['FX_E_VPA']['source']['path'])
ls=fx.read_text().splitlines()
assert 'Vpai <= VPAn' in ls[229]
assert 'xVma = ~rVma & (eCntr == 8)' in ls[474]
assert 'iStop <= xVma' in ls[557]
assert 'waitBusCycle = wendReg & !bcComplete' in ls[2349]
report=load(stage/'first_irq_native57_released1/compact_cause/report.json')
assert report['missed_first_VMA_gate']['tick']==45732669
assert report['physical_cause_proven'] is False
manifest=out/'fx68k_first_irq_contract_review_import_manifest.json';assert not manifest.exists()
names=['fx68k_first_irq_contract_review.md','freeze_fx68k_irq_review.py']
manifest.write_text(json.dumps({'scope':'Independent source/manual-only review of old69 native57; no supported RTL patch, no run/build/source changes; current43b and E-phase origin unqualified','files':[{'path':str(out/n),'sha256':sha(out/n)} for n in names],'primary_pins':[{'path':str(p),'sha256':h} for p,h in pins.items()],'verified_primary_source_and_manual_files':verified,'approved_RTL_correction':None},indent=2)+'\n',encoding='utf-8')
print('PASS independent donor/board/manual pins',len(verified),'NO PHYSICALLY SUPPORTED RTL PATCH')
print('MANIFEST',manifest,sha(manifest))
print('REPORT',sha(out/'fx68k_first_irq_contract_review.md'))
