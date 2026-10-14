-- SPDX-License-Identifier: GPL-3.0-or-later
-- MAME 0.289 crysking oracle probe for the VRender0 control block (vr0_control.sv).
-- Run: PROBE_OUT=out.txt mame.exe crysking -rompath roms -video none -sound none -nothrottle
--      -skip_gameinfo -noplugins -autoboot_delay 0 -autoboot_script control_probe.lua -seconds_to_run 3
-- Recorded 2026-10-06: timer count reads zero in the unmapped upper half (u32=0000ffff after a
-- w32 of ffffffff), INTVEC w32 fffffe1f -> 00000600, INTEN byte lane w8@c0a=aa -> 11aa3344,
-- INTST/SYSID/CFGR writes ignored, PLL (0x4000) and watchdog (0x10) write/readback 0,
-- UART0 resets ucon=1 ubdr=1 ustat=0 rxb=0, unmapped aliases read 0. Writes are made to live
-- state at frame 3 only, so this probe is a register-semantics oracle, not a trace.
local out = io.open(os.getenv("PROBE_OUT"), "w")
local n = 0
local function p(...) out:write(string.format(...).."\n") end
emu.register_frame_done(function()
  n = n + 1
  if n ~= 3 then return end
  local sp = manager.machine.devices[":maincpu"].spaces["program"]
  local B = 0x01800000
  -- timer count
  sp:write_u32(B+0x1404, 0xffffffff)
  p("tcnt after w32 ffffffff: u32=%08x u16lo=%04x u16hi=%04x u8_4=%02x u8_5=%02x u8_6=%02x", sp:read_u32(B+0x1404), sp:read_u16(B+0x1404), sp:read_u16(B+0x1406), sp:read_u8(B+0x1404), sp:read_u8(B+0x1405), sp:read_u8(B+0x1406))
  sp:write_u32(B+0x1404, 0)
  sp:write_u8(B+0x1405, 0x12)
  p("tcnt after w8@1405=12: u32=%08x", sp:read_u32(B+0x1404))
  sp:write_u16(B+0x1406, 0x5555)
  p("tcnt after w16@1406=5555: u32=%08x", sp:read_u32(B+0x1404))
  sp:write_u32(B+0x1404, 0xabcd1234)
  p("tcnt after w32 abcd1234: u32=%08x", sp:read_u32(B+0x1404))
  -- timer ctrl full 32 bits
  sp:write_u32(B+0x1400, 0xdeadbeef & ~1)
  p("tcon0 after w32 deadbeee: %08x", sp:read_u32(B+0x1400))
  sp:write_u32(B+0x1400, 0xff00)
  -- intvec
  sp:write_u8(B+0xc05, 0x05)
  p("intvec after w8@c05=05: %08x", sp:read_u32(B+0xc04))
  sp:write_u16(B+0xc04, 0x0705)
  p("intvec after w16 0705: %08x", sp:read_u32(B+0xc04))
  sp:write_u32(B+0xc04, 0xfffffe1f)
  p("intvec after w32 fffffe1f: %08x", sp:read_u32(B+0xc04))
  sp:write_u32(B+0xc04, 0)
  -- inten
  sp:write_u32(B+0xc08, 0x11223344)
  p("inten after w32: %08x", sp:read_u32(B+0xc08))
  sp:write_u8(B+0xc0a, 0xaa)
  p("inten after w8@c0a=aa: %08x", sp:read_u32(B+0xc08))
  p("intst: %08x", sp:read_u32(B+0xc0c))
  sp:write_u32(B+0xc0c, 0xffffffff)
  p("intst after w: %08x", sp:read_u32(B+0xc0c))
  sp:write_u32(B+0xc08, 0)
  -- sysid writes
  sp:write_u32(B+0, 0x1234)
  p("sysid %08x cfgr %08x", sp:read_u32(B), sp:read_u32(B+4))
  -- platform regs write/readback
  sp:write_u32(B+0x4000, 0x12345678)
  p("pll write/read: %08x", sp:read_u32(B+0x4000))
  sp:write_u32(B+0x10, 0x12345678)
  p("wdog write/read: %08x", sp:read_u32(B+0x10))
  -- uart
  p("uart0 ucon %08x ubdr %08x ustat %08x rxb %08x", sp:read_u32(B+0x1000), sp:read_u32(B+0x1010), sp:read_u32(B+0x1004), sp:read_u32(B+0x100c))
  p("aliases: %08x %08x %08x", sp:read_u32(B+0x1014), sp:read_u32(B+0x101c), sp:read_u32(B+0x1040))
  out:close()
end, "probe")
