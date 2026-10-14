Preflight: Nintendo8080        FAIL
Fast run, 4 run(s) (board, hostile power-up; seeds 1..2), 1357 s. Source 74a18aa.

Game: Sheriff.mra
Video: 256x224, 15.75 kHz, 61.52 Hz, pixel clock 5.040 MHz

Boot ladder
  1 Clocks         ok           50.4 MHz
  2 Reset          FAIL         F-001: Boot depends on the power-up value of emu.pll_locked
  3 ROM download   ok           2 index(es), 18,456 bytes; ioctl_wait held 0 us
  4 Memory         n/a          SDRAM not used
  5 Core activity  risk         the picture never changes after boot
  6 Video timing   ok           256x224, 15.75 kHz, 61.52 Hz, pixel clock 5.040 MHz
  7 Picture        FAIL         F-002: The picture stays black after the boot
  8 Audio          ok           peak 4915, rms 3817.2
  9 Inputs         risk         no visible response to coin/start
 10 Stability      FAIL         2 of 4 power-ups fail

Fix first
 F-001  blocker  Boot depends on the power-up value of emu.pll_locked
        On hardware: Boots on some power-ups or some builds, black or garbage on others.
        Details and fix steps: preflight explain F-001
 F-002  blocker  The picture stays black after the boot
        On hardware: Black screen.
        Details and fix steps: preflight explain F-002

Also found
 F-003  info     A framework file needed a Verilator-only syntax fix

Pictures
 .preflight/latest/contact.png   tile 2 is the first bad frame
 .preflight/latest/report.html

Not checked in this run: timing after place-and-route (run --release)

Next: run: preflight diagnose   (names the registers whose power-up value breaks the boot)
