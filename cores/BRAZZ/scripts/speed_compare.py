"""Frame-cadence comparison: FPGA full-board sim (flips.csv/frames.csv from speed_check.py)
versus MAME (build/speed/mame/cadence.csv from build/speed/mame/cadence.lua).

Game frames are aligned by presented-frame index (k-th display-bank flip in each).
A slow frame is one whose FPGA flip interval spans more vblanks than MAME's.
Cause per slow interval:
  t_lastsubmit = clock (from previous flip) the CPU queued its last packet (the sync flip)
  t_sync       = clock the GPU reached that sync-flip packet (render done)
  CPU-bound if the GPU finished within 5% of a frame after the CPU's last submit
  (the GPU was waiting on the CPU), otherwise GPU-bound.  The memory share of the bound
  side (cpu_stall/interval or gpu_memwait/gpu_busy) is reported alongside.
usage: python scripts/speed_compare.py <activity_dir> [mame_csv] [out_csv]
"""
import csv, sys
from collections import Counter
from pathlib import Path

PERIOD = 1430520  # clk_sys per raster frame (455*262*12 at 85.90908 MHz)


def main():
    act = Path(sys.argv[1])
    mame_csv = Path(sys.argv[2] if len(sys.argv) > 2 else "build/speed/mame/cadence.csv")
    out_csv = Path(sys.argv[3] if len(sys.argv) > 3 else act / "cadence_compare.csv")
    mame = [r for r in csv.DictReader(mame_csv.open()) if r.get("first_poll_val") not in (None, "")]
    mflip = [int(r["frame"]) for r in mame if r["flip"] == "1"]
    m_gaps = [b - a for a, b in zip(mflip, mflip[1:])]
    frames = list(csv.DictReader((act / "frames.csv").open()))
    flips = list(csv.DictReader((act / "flips.csv").open()))
    # FPGA vblank index of each flip (raster frame in which it happened)
    fclock = [int(r["clock"]) for r in frames]
    def frame_of(clock):
        lo, hi = 0, len(fclock)
        while lo < hi:
            mid = (lo + hi) // 2
            if fclock[mid] <= clock: lo = mid + 1
            else: hi = mid
        return lo + 1
    fflip = [frame_of(int(r["clock"])) for r in flips]
    print(f"MAME: {len(mame)} frames, first flip at frame {mflip[0] if mflip else None}, flips {len(mflip)}, "
          f"vblanks/flip histogram {Counter(m_gaps).most_common(6)}")
    print(f"FPGA: {len(frames)} raster frames ({int(frames[-1]['clock'])/1e9:.3f} G clocks), first flip at frame "
          f"{fflip[0] if fflip else None}, flips {len(flips)}")
    if not flips:
        return 0
    rows = []
    slow = Counter()
    for k in range(1, len(flips)):
        f = flips[k]
        iv = int(f["interval_clocks"]); ticks = int(f["vblank_ticks"])
        mg = m_gaps[k - 1] if k - 1 < len(m_gaps) else None
        fg = fflip[k] - fflip[k - 1]
        ls, ts = int(f["t_lastsubmit"]), int(f["t_sync"])
        busy = int(f["gpu_busy"]); memw = int(f["gpu_memwait"]); stall = int(f["cpu_stall"])
        if ts < 0: ts = iv
        if ls < 0: ls = 0
        gpu_tail = ts - ls
        cause = "CPU" if gpu_tail < 0.05 * PERIOD else "GPU"
        detail = (f"cpu_mem_stall={stall/iv:.0%} retired={f['retired']}" if cause == "CPU"
                  else f"gpu_busy={busy/iv:.0%} gpu_memwait={memw/max(busy,1):.0%} burst_wait={int(f['burst_wait'])/max(busy,1):.0%}")
        is_slow = mg is not None and fg > mg
        if is_slow: slow[cause] += 1
        rows.append({"flip": k, "fpga_frame": fflip[k], "fpga_vblanks": fg, "mame_frame": mflip[k] if k < len(mflip) else "",
                     "mame_vblanks": mg, "slow": int(is_slow), "cause": cause if is_slow else "", "t_lastsubmit": ls, "t_sync": ts,
                     "interval": iv, "packets": f["packets"], "pixels": f["pixels"], "retired": f["retired"],
                     "cpu_stall": stall, "gpu_busy": busy, "gpu_memwait": memw, "burst_wait": f["burst_wait"], "detail": detail})
    with out_csv.open("w", newline="") as o:
        w = csv.DictWriter(o, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)
    fg_hist = Counter(r["fpga_vblanks"] for r in rows)
    print(f"FPGA vblanks/flip histogram {sorted(fg_hist.items())[:12]}")
    print(f"slow presented frames: {sum(r['slow'] for r in rows)}/{len(rows)}  by cause {dict(slow)}")
    print(f"boot: first flip FPGA raster frame {fflip[0]} vs MAME frame {mflip[0]}")
    print(f"written {out_csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
