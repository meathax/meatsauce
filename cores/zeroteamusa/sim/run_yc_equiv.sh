cd /mnt/d/Arcade/AI/aCORES/zero
verilator --binary --timing -Wno-fatal -Wno-WIDTH --Mdir /mnt/r/Verilator/zero-yc-equiv --top-module tb sim/yc_equiv/yc_out_orig.sv sim/yc_equiv/yc_out_new.sv sim/yc_equiv/tb.sv >/tmp/yc.log 2>&1 || tail -15 /tmp/yc.log
/mnt/r/Verilator/zero-yc-equiv/Vtb | grep -E "cycles=|YC_EQUIV"
