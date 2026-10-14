import pathlib,json,hashlib,re
out=pathlib.Path(__file__).parent
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def load(p):return json.loads(p.read_text())
probe=out/'canonical_epoch_probe.json'
assert sha(probe)=='ad29a6af2119716fe9d28d1bd95e8abc5b0f76fb86f83b6f10fad40ed84f3b01'
d=load(probe);core=pathlib.Path(d['canonical_core'])
assert d['canonical_head']=='6cafdc7d5edac7a5403ac7224b74c996921de966'
receipt=d['canonical_commit_receipt'];assert sha(pathlib.Path(receipt['path']))==receipt['sha256']
assert receipt['data']['actual_exit_code']==0 and receipt['data']['clean'] is True
assert receipt['data']['revision']==d['canonical_head']
expected={'rtl/alpha68kn_mcu.sv','rtl/vendor/t48/t48_core.v','rtl/vendor/jt12/jt49/hdl/jt49_div.v'}
counts={};newline=[]
for closure in ['native160','origin161']:
    rows=[r for r in d['rows'] if r['closure']==closure]
    assert all(r['canonical_exists'] for r in rows)
    differences={r['relative'] for r in rows if not r['exact']}
    assert differences==expected|{'Alpha68k_N.qsf'},differences
    for r in rows:
        p=pathlib.Path(r['fitted_path']);c=pathlib.Path(r['canonical_path'])
        assert sha(p)==r['fitted_sha256'] and sha(c)==r['canonical_sha256']
        if r['relative'] in expected:
            assert r['crlf_to_lf_only'] and p.read_bytes().replace(b'\r\n',b'\n')==c.read_bytes()
            newline.append(r)
    counts[closure]={'files':len(rows),'byte_identical':sum(r['exact'] for r in rows),'only_CRLF_to_LF_HDL':3,'reviewed_QSF_overlay':1,'missing_or_unexplained':0}
qsf=core/'Alpha68k_N.qsf';overlay=b'set_global_assignment -name SDC_FILE constraints/alpha68kn_game_groups.sdc'
lines=qsf.read_bytes().splitlines(keepends=True)
assert sum(l.strip()==overlay for l in lines)==1
without=b''.join(l for l in lines if l.strip()!=overlay)
originqsf=next(r for r in d['rows'] if r['closure']=='origin161' and r['relative']=='Alpha68k_N.qsf')
assert without==pathlib.Path(originqsf['fitted_path']).read_bytes()
assert sha(qsf)=='57c6729be203f2a8289534ad3e686d842add90fb11d8e75fd5526f3bf10bec31'
sdc=core/'constraints/alpha68kn_game_groups.sdc'
assert sha(sdc)=='8ef8f941d4c769a0bca7fbafd5aeb04de2c8eee1e4ec4151c02732fdc61c0d8a'
base=out.parent/'joined_rom_inference_v2'
effective=base/'effective_Alpha68k_N.qsf'
assert sha(effective)=='029436ac2cc7a389bd9b0bae4f2d89fef205a7318d0ff5abc5f988a5d254be5a'
native=[r for r in d['rows'] if r['closure']=='native160']
byhash={}
for r in native:byhash.setdefault(r['fitted_sha256'],[]).append(r)
hdl=[]
for line in effective.read_text().splitlines():
    m=re.match(r'set_global_assignment -name (VERILOG_FILE|SYSTEMVERILOG_FILE|VHDL_FILE) (.+)',line)
    if not m:continue
    value=re.match(r'"([^"]+)"|([^\s]+)',m[2]);p=pathlib.Path(value[1] or value[2])
    h=sha(p);matches=byhash.get(h,[]);assert matches,(str(p),h)
    # Raw fitted assignment is matched to its frozen relative source pin,
    # then canonical bytes were proved above. Do not merely match basenames.
    exactpath=[r for r in matches if pathlib.Path(r['fitted_path'])==p]
    if exactpath:matches=exactpath
    if len(matches)>1:
        suffixpath=[r for r in matches if str(p).replace('\\','/').lower().endswith('/'+r['relative'].replace('\\','/').lower())]
        if suffixpath:matches=suffixpath
    assert len(matches)==1,(p,[r['relative'] for r in matches])
    r=matches[0]
    hdl.append({'kind':m[1],'fitted_assignment_path':str(p),'fitted_sha256':h,'canonical_path':r['canonical_path'],'canonical_sha256':r['canonical_sha256'],'relative':r['relative'],'exact_bytes':r['exact'],'only_CRLF_to_LF':r['crlf_to_lf_only']})
assert hdl and {r['relative'] for r in hdl if not r['exact_bytes']}==expected
proof=out/'bank43b_epoch_binding.json';assert not proof.exists()
proof.write_text(json.dumps({'status':'source_epoch_semantic_equivalence_proven','canonical_commit':d['canonical_head'],'closure_counts':counts,'assigned_hdl_count':len(hdl),'assigned_hdl_bindings':hdl,'newline_only_bindings':newline,'canonical_qsf':{'path':str(qsf),'sha256':sha(qsf),'only_change_to_origin':overlay.decode()},'native_effective_qsf':{'path':str(effective),'sha256':sha(effective),'contract':'Relocated/flattened diagnostic check QSF; original settings STANDARD, RBF OFF; assigned HDL closure verified, no byte-identical canonical fitted-QSF claim'},'canonical_overlay':{'path':str(sdc),'sha256':sha(sdc)},'commit_receipt':receipt,'limits':['Source semantic equivalence only. Canonical raw graph was not compiled and is not byte-identical to frozen FIT input bytes.','All existing external I/O, physical CDC, current-image simulation and hardware/release gates remain separate.','Current HEAD directly read; clean status is the existing successful root commit receipt, not a new Git status query.']},indent=2)+'\n',encoding='utf-8')
md=out/'bank43b_epoch_binding.md';assert not md.exists()
md.write_text('# Bank43b fitted-source to canonical epoch proof\n\nCanonical commit `'+d['canonical_head']+'` is semantically equivalent to the frozen fitted source closure. Native160: **156 byte-identical files + 3 CRLF-to-LF-only HDL files + 1 reviewed QSF overlay**. Origin161: **157 byte-identical files + the same 3 HDL normalizations + 1 QSF overlay**. All paths exist; no unexplained source difference remains.\n\nThe only HDL differences are `rtl/alpha68kn_mcu.sv` (26614f -> 2626a0), `rtl/vendor/t48/t48_core.v` (2ad3ac -> 63dcf1), and `rtl/vendor/jt12/jt49/hdl/jt49_div.v` (2c4e8f -> e2258a). Exact raw replacement of CRLF with LF produces each canonical file; no token, whitespace beyond those line terminators, logic or parameter differs. Every '+str(len(hdl))+' actual flattened native HDL assignment matches its frozen source pin and canonical target; full hashes and paths are in `bank43b_epoch_binding.json`.\n\nCanonical QSF SHA256 `'+sha(qsf)+'` differs from original QSF `7b560a...` only by the single additive `SDC_FILE constraints/alpha68kn_game_groups.sdc` assignment. Removing that exact line reproduces the original QSF bytes. Canonical overlay SHA256 is `'+sha(sdc)+'`, identical to the reviewed native overlay. Both original SDCs and the source closure retain exact bytes. Native effective QSF `029436...` is a relocated/flattened check workspace with RBF OFF and is bound separately; it is not the canonical raw QSF.\n\nThis is a **source semantic equivalence proof**, not a byte-identical canonical FIT/rebuild claim. Existing eight-corner reports remain immutable and qualify their exact native input graph. No report was regenerated and no compile, source edit or constraint change was performed. All external timing, physical CDC, current-image gameplay/graphics and hardware/release gates remain open as previously recorded.\n\nHEAD is bound by direct read of the repository HEAD/ref and the existing successful root_commit_v4 receipt. Fresh Git subprocess status was unavailable (permission denied); the clean-status claim is explicitly limited to that root receipt.\n',encoding='utf-8')
names=['probe_canonical_epoch.py',probe.name,'freeze_bank43b_epoch.py',proof.name,md.name]
manifest=out/'bank43b_epoch_binding_import_manifest.json';assert not manifest.exists()
manifest.write_text(json.dumps({'scope':'Frozen source semantic equivalence only; no compile or canonical FIT byte identity claim','files':[{'path':str(out/n),'sha256':sha(out/n)} for n in names],'recovery_references':[d['released_plan'],{'path':receipt['path'],'sha256':receipt['sha256']},{'path':str(out/'bank43b_review_import_manifest.json'),'sha256':sha(out/'bank43b_review_import_manifest.json')}]},indent=2)+'\n',encoding='utf-8')
print('PASS',json.dumps(counts),'assignedHDL',len(hdl))
print('MANIFEST',manifest,sha(manifest))
print('PROOF',proof,sha(proof))
