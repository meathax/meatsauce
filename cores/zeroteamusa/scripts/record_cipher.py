"""Save bounded full-region differential evidence for the real target cipher RTL."""
from pathlib import Path
import json,hashlib
root=Path(__file__).resolve().parents[1]
result=json.loads((root/'sim/results/cipher-diff.json').read_text())
assert result['words_compared']==2097152 and result['different_words']==0
paths=['rtl/Raiden2/crypt/zeroteam_sprite_decrypt.sv','sim/zero_crypt_top.sv','sim/crypt_main.cpp','sim/crypt_compat.hpp','reference/mame/r2crypt.cpp','reference/mame/seibu_helper.cpp']
paths += [f'rtl/Raiden2/crypt/{n}.hex' for n in ['rotate_zt','x5_zt','x11_zt']]
result.update({'date':'2026-10-04','set':'zeroteam','command':'wsl.exe -d Ubuntu --cd D:\\Arcade\\AI\\aCORES\\zero --exec bash ./sim/run_crypt.sh',
    'source_sha256':{p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in paths},
    'encrypted_region_sha256':hashlib.sha256((root/'roms/regions/sprites.bin').read_bytes()).hexdigest(),
    'rtl_plain_region_sha256':hashlib.sha256((root/'sim/results/rtl-decrypted-sprites.bin').read_bytes()).hexdigest(),
    'limits':'Standalone real RTL cipher versus original MAME algorithm. This proves this US set ROM transform, not uploaded-key behavior or later COP sorting/gameplay.'})
(root/'docs/evidence/sprite-cipher.json').write_text(json.dumps(result,indent=2)+'\n')
print('Recorded full-region Zero Team RTL/MAME cipher equality.')
