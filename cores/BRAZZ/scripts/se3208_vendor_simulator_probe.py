"""Bounded synthetic probes of the private, staged official SE3208 simulator."""
from pathlib import Path
import ctypes
import hashlib
import json
import struct
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'sim/obj_dir/isa_research/vendor_bin'
EXPECTED_SHA256 = '60b8b1324067a18cbfd3cd8d78a08b08415cb133f5f857afec79e4207a3cc151'


def symbols_and_sections(data):
    assert data[:2] == b'MZ'
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    assert data[pe:pe+4] == b'PE\0\0'
    machine, count, _, offset, size, optional, _ = struct.unpack_from('<HHIIIHH', data, pe+4)
    assert machine == 0x14c, 'Expected native PE i386, not an ELF/script'
    base = struct.unpack_from('<I', data, pe+52)[0]
    sections = [struct.unpack_from('<IIII', data, pe+24+optional+40*i+8) for i in range(count)]
    strings = offset + size*18
    result = {}
    i = 0
    while i < size:
        pos = offset + i*18
        raw = data[pos:pos+8]
        value, section, _, _, auxiliary = struct.unpack_from('<IhHBB', data, pos+8)
        if raw[:4] == b'\0'*4:
            start = strings + struct.unpack_from('<I', raw, 4)[0]
            name = data[start:data.index(b'\0', start)].decode(errors='replace')
        else:
            name = raw.rstrip(b'\0').decode(errors='replace')
        if section > 0:
            _, virtual, _, file_offset = sections[section-1]
            result[name] = (base + virtual + value, file_offset + value)
        i += auxiliary + 1
    return result


def main():
    ctypes.windll.kernel32.SetErrorMode(3)
    data = (VENDOR / 'se3208-elf-run.exe').read_bytes()
    assert hashlib.sha256(data).hexdigest() == EXPECTED_SHA256
    symbols = symbols_and_sections(data)
    handlers = []
    for opcode in ['FC00', 'FC40', 'FC50', 'FC60', 'FC68', 'FCC0', 'FCC8', 'FC80', 'FC90']:
        address, offset = symbols['_OP_' + opcode]
        body = data[offset:offset+5]
        # push ebp; mov esp,ebp; pop ebp; ret. No architectural writes/calls.
        assert body == bytes.fromhex('55 89 e5 5d c3')
        handlers.append({'symbol': '_OP_' + opcode, 'address': f'{address:08x}',
                         'file_offset': offset, 'bytes': body.hex(), 'empty': True})
    results = []
    for name, source in [('halt', 'halt'), ('infinite', 'jmp _start'), ('unknown', '.short 0xffff')]:
        (VENDOR / 'iss_probe.s').write_text('.text\n.globl _start\n_start:\n' + source + '\n')
        for executable, args in [('se3208-elf-as.exe', ['-o', 'iss_probe.o', 'iss_probe.s']),
                                 ('se3208-elf-ld.exe', ['-Ttext', '0x100', '-e', '_start', '-o', 'iss_probe.elf', 'iss_probe.o'])]:
            run = subprocess.run([str(VENDOR / executable)] + args, cwd=VENDOR,
                                 capture_output=True, text=True, timeout=10)
            assert run.returncode == 0, run.stderr
        start = time.monotonic()
        try:
            run = subprocess.run([str(VENDOR / 'se3208-elf-run.exe'), '-v', '-t', 'iss_probe.elf'],
                                 cwd=VENDOR, capture_output=True, text=True, timeout=2)
            result = {'program': name, 'returncode': run.returncode,
                      'elapsed_ms': round((time.monotonic()-start)*1000),
                      'stdout': run.stdout, 'stderr': run.stderr}
        except subprocess.TimeoutExpired:
            result = {'program': name, 'timeout_seconds': 2}
        results.append(result)
    assert results[0]['returncode'] == 0
    assert results[1].get('timeout_seconds') == 2
    assert results[2]['returncode'] == 1 and '0xffff, PC=0x100' in results[2]['stdout']
    report = {'source': 'Official ADChips EISC Studio3 staged SDK; same archive as se3208_vendor_tools.json',
              'sha256': EXPECTED_SHA256, 'handlers': handlers, 'probes': results,
              'limit': 'The interpreter executes ordinary instructions, but these control handlers are empty. '
                       'They cannot establish physical SE3208/VRender0 control-register effects.'}
    (ROOT / 'docs/se3208_vendor_simulator_probe.json').write_text(json.dumps(report, indent=2)+'\n')
    print('PASS vendor simulator research: HALT exits, infinite loop times out, unknown opcode faults; '
          'nine coprocessor handlers verified empty. No hardware-effects oracle.')


if __name__ == '__main__':
    main()
