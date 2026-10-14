# Source provenance

Upstream: https://github.com/rmonic79/Arcade-Raiden2_MiSTer.git

Commit: `534c84c5803959e76538b65ac71808616f1caa41`

Original path: `rtl/pll/`

Imported unchanged, retaining original per-file notices. Integration changes belong in a dated change entry below. The project license is GPL-3.0-or-later; upstream file notices remain authoritative.

2026-10-05: Enable the existing PLL's second output at 96 MHz with a
1302 ps (45-degree) phase shift for SDRAM clock forwarding. The DDIO
inversion places the SDRAM rising edge at 225 degrees relative to the
unchanged fabric clock. Rising-edge I/O registers and a registered completion
stage preserve the pin windows while giving internal paths a full cycle.
