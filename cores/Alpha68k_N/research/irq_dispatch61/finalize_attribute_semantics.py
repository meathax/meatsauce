"""Keep direct Iac signal edges distinct from the observed bus attribute edge."""
import csv,hashlib,json
from pathlib import Path
S=Path(__file__).resolve().parent;ROOT=S.parents[1]
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
d=json.loads((S/'compact_acceptance.json').read_text())
rows=list(csv.DictReader((ROOT/'sim/captures/rtl/irq_dispatch61/dispatch.csv').open()))
checks={}
for c in d['cases']:
    tick=c['assertion']['tick']
    hits=[x for x in rows if tick<=int(x['tick'])<=tick+1000 and int(x['Iac_before'])==0 and int(x['Iac_after'])==1]
    checks[c['IRQ']+'_one_direct_Iac_rise']=len(hits)==1
    edge=hits[0] if len(hits)==1 else None
    c['observed_IACK_bus_attribute_rise']=c.pop('actual_IACK_assertion')
    c['direct_Iac_signal_rise']=None if edge is None else {'tick':int(edge['tick']),'frame':int(edge['frame']),
        'Iac_before':int(edge['Iac_before']),'Iac_after':int(edge['Iac_after']),
        'address':int(edge['address']),'attrs_before':int(edge['attrs_before']),'attrs_after':int(edge['attrs_after'])}
    c['intervals_from_assertion_masterticks']['IACK_bus_attribute_rise']=c['intervals_from_assertion_masterticks'].pop('IACK_assertion')
    c['intervals_from_assertion_masterticks']['Iac_signal_rise']=None if edge is None else int(edge['tick'])-tick
    checks[c['IRQ']+'_signal_and_bus_attribute_are_distinct']=edge is not None and int(edge['tick'])!=c['observed_IACK_bus_attribute_rise']['tick']
d['bus_attribute_label_correction']={'original_compact_receipt_sha256':sha(S/'compact_acceptance.json'),
    'reason':'attrs bit3 transition is an observed bus IACK attribute; it must not be labeled the direct CPU Iac signal assertion. Both actual edges are now recorded separately.',
    'checks':checks,'all_checks_strict_boolean_true':all(type(v) is bool and v for v in checks.values())}
d['limits'].append('The Iac internal signal and IACK bus attribute are distinct actual boundaries; neither is equated with a MAME callback or a sampled vector-data latch.')
p=S/'compact_acceptance_v2.json';p.write_text(json.dumps(d,indent=2)+'\n')
doc=S/'interpretation_v2.md'
doc.write_text('Actual native61 build/run/verifier exited0, with all13 source/fidelity checks true and all61 CPU/renderer rows plus19whole RGB images exact. No production RTL or clocks changed.\n\n'+
    '\n\n'.join('Original '+c['IRQ']+' tick'+str(c['assertion']['tick'])+' is native field'+str(c['assertion']['frame'])+'; offsets '+json.dumps(c['intervals_from_assertion_masterticks'])+'.' for c in d['cases'])+
    '\n\nThe original collector-scope failure, frame-label-selected extraction, and earlier attribute-edge label are retained. Exact original ticks select the cases; no frames or pixels are shifted. Direct Iac and bus attribute edges remain distinct. Runtime MAME pending/next state at its IR-to-IRD cutoff is still missing. No physical cause, CPU correction, B16 closure or full graphics acceptance is proved.\n')
files=sorted(x for x in S.iterdir() if x.is_file() and x.name not in ['qualification.json','import_manifest.json'])
manifest={'scope':'Actual direct native61 with corrected original-tick and signal/attribute boundary semantics; prior receipts retained.',
    'files':[{'relative_path':x.relative_to(ROOT).as_posix(),'sha256':sha(x),'bytes':x.stat().st_size} for x in files],
    'recovery_only_large_artifacts':[d['raw_qualification_recovery'],d['raw_observer_recovery']],
    'authoritative_compact_boundary_receipt':'research/irq_dispatch61/compact_acceptance_v2.json'}
m=S/'import_manifest.json';m.write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps({'checks':checks,'cases':[{'IRQ':c['IRQ'],'assertion':c['assertion']['tick'],'native_field':c['assertion']['frame'],
    'intervals':c['intervals_from_assertion_masterticks']} for c in d['cases']],
    'compact_receipt_sha256':sha(p),'manifest_sha256':sha(m),'files':len(files),
    'portable_bytes':sum(x.stat().st_size for x in files)}))
raise SystemExit(0 if all(type(v) is bool and v for v in checks.values()) else 1)
