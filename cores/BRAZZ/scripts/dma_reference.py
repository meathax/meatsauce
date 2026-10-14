"""Extract the pinned MAME DMA transfer function unchanged for unit comparison."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "docs/reference/mame/src/devices/machine/vrender0.cpp"


def function(text, signature):
    start = text.index(signature)
    opening = text.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


def main():
    source = SOURCE.read_text(encoding="utf-8")
    helper = function(source, "inline int dma_setup_hold")
    transfer = function(source, "template<int Which>\nvoid vrender0soc_device::dmac_w")
    transfer = transfer.replace("vrender0soc_device::", "vr0_reference::")
    header = '''// Generated test oracle from BSD-3-Clause MAME.
// Copyright Angelo Salese, ElSemi. See docs/reference/mame/COPYING.
#pragma once
#include "../cpu_reference/se3208_reference.hpp"
#define COMBINE_DATA(p) ((*(p) = (*(p) & ~mem_mask) | (data & mem_mask)))
inline void popmessage(const char*,...) {}
struct vr0_reference {
    struct vr0_dma {u32 src=0,dst=0,size=0,ctrl=0;};
    vr0_dma m_dma[2]; ByteBus *m_host_space=nullptr; u32 events=0;
    void int_req(int number) {events |= 1u << number;}
    template<int Which> void dmac_w(offs_t offset,u32 data,u32 mem_mask=~0u);
};
'''
    header = header.replace("offs_t", "u32")
    transfer = transfer.replace("offs_t", "u32")
    out = ROOT / "sim/obj_dir/dma_reference"
    out.mkdir(parents=True, exist_ok=True)
    path = out / "vr0_reference.hpp"
    path.write_text(header + helper + "\n" + transfer + "\n#undef COMBINE_DATA\n", encoding="utf-8")
    report = {"source": SOURCE.relative_to(ROOT).as_posix(), "source_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
              "functions": ["dma_setup_hold", "dmac_w"], "body_changes": "class qualification and offset type aliases only; bodies unchanged",
              "header_sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "scope": "unit oracle; not RTL/game CPU or DMA"}
    (ROOT / "docs/dma_reference.json").write_text(json.dumps(report, indent=2) + "\n")
    print("MAME DMA transfer oracle extracted")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
