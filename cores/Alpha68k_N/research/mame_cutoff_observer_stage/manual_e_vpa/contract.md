# Primary MC68000 E/VPA timing contract

Source: [NXP-hosted Motorola M68000 User Manual](https://www.nxp.com/docs/en/reference-manual/MC68000UM.pdf), catalog Rev 9.1 (2006-01-25); PDF cover copyright 1993, metadata modification 2006-01-25. Relevant printed pages 3-8, 5-29, B-1 through B-5; PDF pages 36, 75, 185-189 (one-based).

E runs freely: ten processor clocks, six low/four high. Section 3.7 states: "At power-on, it is impossible to guarantee phase relationship of E to CLK." Section 5.5 supplies reset sequencing, without establishing an E-phase origin.

Appendix B.1: promptly asserted VPA after AS is recognized on the falling edge of S4; subsequent waiting synchronizes E. Best case recognizes VPA three clocks before E rises; worst case recognizes it two clocks before E rises. Figures B-4/B-5 illustrate the extra E period. Thus VPA following AS does not always require the next E period; its recognized phase decides. This last distinction is an inference from the stated extrema and figures.

Appendix B.2/Figure B-6: VPA autovector acknowledge completes an ordinary E-synchronized M6800 read cycle. DTACK must remain inactive while VPA is active. VMA is asserted during autovector service.

Limit: these contracts establish phase-sensitive waiting, not Kyros PCB E phase, a fixed reset phase, or an exact donor/MAME edge correspondence. They do not authorize a timing patch.
