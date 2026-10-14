cd /mnt/d/Arcade/AI/aCORES/zero
verilator --binary --timing -Wno-fatal -Wno-WIDTH --Mdir /mnt/r/Verilator/zero-credits-check -Icredits/generated credits/rtl/credits_overlay.sv credits/generated/credits_rom.sv sim/credits_overlay_check.sv --top-module credits_overlay_check >/tmp/cb.log 2>&1
/mnt/r/Verilator/zero-credits-check/Vcredits_overlay_check | grep -E "c1=|closed|CHECK"
