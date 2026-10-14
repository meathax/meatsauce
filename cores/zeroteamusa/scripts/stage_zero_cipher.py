"""Stage public Zero Team cipher tables and adapt the pinned donor datapath once."""
from pathlib import Path
import re,hashlib,json
root=Path(__file__).resolve().parents[1]
dest=root/'rtl/Raiden2/crypt'
target=dest/'zeroteam_sprite_decrypt.sv'
if target.exists(): raise SystemExit('Already staged; edit active RTL directly.')
source=root/'reference/mame/r2crypt.cpp'
text=source.read_text()
sizes={'rotate_zt':256,'x5_zt':256,'x11_zt':512}
for name,size in sizes.items():
    match=re.search(rf'\b{name}\s*\[[^\]]+\]\s*=\s*\{{(.*?)\}};',text,re.S)
    assert match,name
    values=[int(v,16) for v in re.findall(r'0x([0-9a-fA-F]+)',match.group(1))]
    assert len(values)==size,(name,len(values))
    width=4 if name=='x11_zt' else 2
    (dest/f'{name}.hex').write_text(''.join(f'{v:0{width}x}\n' for v in values))
s=(dest/'raiden2_sprite_decrypt.sv').read_text()
s='// Zero Team adaptation of the pinned donor datapath; see PROVENANCE.md.\n'+s
s=s.replace('module raiden2_sprite_decrypt (','module zeroteam_sprite_decrypt (')
s=s.replace("32'h60860000", "32'ha5800000").replace("32'h176c91a8", "32'h7b67b7b9").replace("32'h0f488000", "32'hf1412ea8")
s=s.replace('rot_tab [0:511]', 'rot_tab [0:255]').replace('x11_tab [0:255]', 'x11_tab [0:511]')
s=s.replace('rotate_r2.hex','rotate_zt.hex').replace('x5_r2.hex','x5_zt.hex').replace('x11_r2.hex','x11_zt.hex')
s=re.sub(r'wire \[8:0\] i1 =[^;]+;', 'wire [7:0] i1 = widx[7:0];',s)
s=re.sub(r'wire \[7:0\] i2 =[^;]+;', 'wire [7:0] i2 = widx[7:0];',s)
s=s.replace('wire [7:0] i3 = widx[15:8];','wire [8:0] i3 = widx[15:7];')
s=s.replace('reg [31:0] din_q;', 'reg [31:0] din_q;\n    reg bypass_q;')
s=s.replace('din_q <= din;', "din_q <= din;\n        bypass_q <= widx >= 22'h100000;")
s=s.replace("assign dout = ({sum[31:1], sum[0] ^ cy[32]}) ^ POST_XOR;", "assign dout = bypass_q ? din_q : (({sum[31:1], sum[0] ^ cy[32]}) ^ POST_XOR);")
target.write_text(s)
original=Path(r'D:\Arcade\AI\mame289\src\mame\seibu\seibu_helper.cpp')
helper=root/'reference/mame/seibu_helper.cpp'
helper.write_bytes(original.read_bytes())
(root/'reference/research/cipher-source.json').write_text(json.dumps({
    'mame':'0.289','sources':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [source,helper]},
    'tables':sizes,'encrypted_bytes':0x400000,'upper_region_bytes_passthrough':0x400000,
    'source_license':'BSD-3-Clause; notices retained',
    'datapath_donor':'rmonic79 Arcade-Raiden2_MiSTer 534c84c5803959e76538b65ac71808616f1caa41'
},indent=2)+'\n')
(dest/'PROVENANCE.md').write_text('''# Cipher provenance

`zeroteam_sprite_decrypt.sv` adapts the pinned GPL-3.0-or-later
rmonic79 `raiden2_sprite_decrypt.sv` datapath. Original notice remains.
The three `*_zt.hex` tables are extracted from MAME 0.289
`src/mame/seibu/r2crypt.cpp`, BSD-3-Clause, copyright Andreas Naive
and Olivier Galibert. That original source is retained in `reference/mame/`.
Indexing/constants follow `zeroteam_decrypt_sprites`; only the first 4 MiB
are decrypted, and the upper 4 MiB pass through as in `init_zeroteam`.
''')
print('Staged public Zero Team cipher tables and real RTL datapath.')
