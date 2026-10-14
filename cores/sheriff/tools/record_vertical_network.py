#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Record corrected vertical ENP connectivity; retain the rejected old extension."""
import hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def extension(limit,qualified_enable):
    phase,upper,active,vertical=0,12,0,0
    carries=[];increments=[]
    for edge in range(limit):
        carry=upper==15 and phase==15
        if carry:
            carries.append(edge)
            if active or not qualified_enable:
                vertical=(vertical+1)&255;increments.append(edge)
            upper,active=(12 if active else 0),1-active
        elif phase==15:upper=(upper+1)&15
        phase=(phase+1)&15
    return vertical,carries,increments
def main():
    old=json.loads((ROOT/'_checks/vertical-counter-20261010/source-correction/sheriff_vertical_network.json').read_text(encoding='utf-8'))
    native=json.loads((ROOT/'docs/evidence/sheriff_vertical_counter_native.json').read_text(encoding='utf-8'))
    assert native['native_exit']==0
    for path,digest in native['source_sha256'].items():assert sha(ROOT/path)==digest
    v,c,i=extension(320*128,False)
    assert v==0 and len(i)==256 and {b-a for a,b in zip(c,c[1:])}=={64,256}
    v,c,i=extension(320*256,True)
    assert v==0 and len(c)==512 and len(i)==256
    assert {b-a for a,b in zip(i,i[1:])}=={320}
    old['scope']='Corrected connected related-board vertical ENP/clock wiring and receipt-backed isolated native counters; no full Sheriff raster/graphics qualification.'
    old['connections'].pop('5I_CLK2_ENP7',None)
    old['connections'].update({
        '5I_CLK2_5J_CLK2':'Common CK/4. CLK wires cross the ENP risers without junction dots.',
        '5I_ENP7_5J_ENP7':'Independent risers join HB_n, the active-horizontal 4G Qbar6 feedback. NOT tied to CLK.',
        '5I_ENT10':'4J RCO15.',
        '5J_ENT10':'5I RCO15. Both ENP inputs must also be high to count.',
        '5I_LOAD9_5J_LOAD9':'High; CLR1 also held high in the drawn network. Native reset is an artificial origin.',
    })
    old['conditional_extension_negative_check']['conclusion']='Historical negative: counting every terminal carry omitted active-horizontal ENP gating. The related wiring now resolves this contradiction; no arbitrary divide-by-two was added.'
    old['corrected_extension_check']={
        'horizontal_period_pixels':320,'raw_carries_per_field':512,
        'vertical_increments_per_field':256,'increment_period_pixels':320,
        'field_counter_clocks':81920,'native_evidence':'docs/evidence/sheriff_vertical_counter_native.json',
        'software_derivation_scope':'Connected ideal enables only; reuses native terminal evidence, not a replacement for it.',
    }
    old['vertical_blank']={
        'D12':'AND of 5J QB13/QC12/QD11, via LS20 and inversion: V5 & V6 & V7.',
        'CLK11':'5J QA14 rising: V4.',
        'Q9':'VB high blank; Qbar8 high active.',
        'ideal_transitions':'clear VB at vertical16; set VB at vertical240;224 active rows.',
        'origin_limit':'Digital reset v=0/VB=1 is repeatable bench state, not verified PCB power-up/reset.',
    }
    old['correction']={
        'superseded_clock_enable_claim':'CLK2/ENP7 tied to CK/4 was a source-reading error.',
        'original_report':'_checks/vertical-counter-20261010/source-correction/sheriff_vertical_network.json',
        'original_report_sha256':sha(ROOT/'_checks/vertical-counter-20261010/source-correction/sheriff_vertical_network.json'),
        'bandido_source':'_checks/manuals/bandido-1980.pdf',
        'bandido_original_page':'_checks/manuals/bandido-page-34.png',
        'connected_view':'_checks/manuals/bandido-counter-joins-full-20261010.png',
        'polarity_view':'_checks/manuals/bandido-vertical-clock-enable-polarity-20261010.png',
        'polarity_view_original_box':[300,710,1830,1250],
        'transform':'Crop plus black/white polarity inversion for legibility; no circuit redrawn.',
        'second_source_view':'_checks/manuals/space-fever-5i-pin-joins-3x.png',
        'ttl_source':{'url':'https://www.ti.com/lit/ds/symlink/sn74ls161a.pdf',
                      'path':'_checks/manuals/ti-sn74ls161a.pdf','reviewed_pdf_pages':[1,2],
                      'semantics':'Both P/ENP and T/ENT high to count; T enables carry. ENP gates both vertical cascade stages.'},
    }
    paths=['tools/record_vertical_network.py','docs/evidence/sheriff_vertical_counter_native.json',
           'rtl/n8080_horizontal_counter.sv','rtl/n8080_vertical_counter.sv',
           '_checks/manuals/bandido-1980.pdf','_checks/manuals/bandido-page-34.png',
           '_checks/manuals/bandido-counter-joins-full-20261010.png',
           '_checks/manuals/bandido-vertical-clock-enable-polarity-20261010.png',
           '_checks/manuals/space-fever-color-schematic.pdf',
           '_checks/manuals/space-fever-5i-pin-joins-3x.png',
           '_checks/manuals/space-fever-counter-enables.png',
           '_checks/manuals/ti-sn74ls161a.pdf','_checks/manuals/ti-sn74ls161a-page1.png',
           '_checks/manuals/ti-sn74ls161a-page2.png']
    old['evidence_sha256']={path:sha(ROOT/path) for path in paths}
    old['limitations']=[
        'Connected ideal enable/VB behavior is source-qualified on related Bandido/TSF; exact Sheriff net/revision remains an applicability limit.',
        'C5/load/RCO propagation, chip grade/setup/hold and absolute reset/visible/IRQ origin remain unqualified.',
        'Physical DRAM/readback/READY and serializer/PROM/RGB alignment still require integration qualification.',
        'Module is outside files.qip; production board is unchanged. No field2760 waiver, graphics or fit/resource pass follows.',
    ]
    old['integrated_in_board']=False
    old['strict_graphics_gate_pass']=False
    old['quartus_executed']=False
    old['rbf_built']=False
    out=ROOT/'docs/evidence/sheriff_vertical_network.json'
    out.write_text(json.dumps(old,indent=2)+'\n',encoding='utf-8',newline='')
    print(json.dumps({'report':str(out),'related_vertical_enable_resolved':True,'counter_lines':256,
                      'production_integration':False,'strict_graphics_pass':False}))
if __name__=='__main__':main()
