# Counter-to-PIO bridge

The related Bandido counter/XOR network establishes `hbyte={upper_4j,!phase_4i[3]} XOR {5{F}}` and `v_pio=vertical XOR {8{F}}`, where F is the physical OUT6 2D Q5 pin15. The existing flip source gives NOR=!F and RV=F. No visible origin or reset offset is chosen by these equations.

H0 is the exceptional lane: 4I QD11 enters 4K input9, NOR enters input10, output8 reaches PIO/CP3 pin31. H1/H2/H3/H4 use 4J QA14/QB13/QC12/QD11 through 4L XOR channels with RV and reach pins33/35/37/39. Thus H0 uses raw counter bit3 XOR the complementary flip net; it is not another plain upper-counter bit.

V0–V3 use 5I QA14/QB13/QC12/QD11 through 5K XOR channels with RV and reach pins41–44. V4–V7 use the same four 5J pin positions through 5L with RV and reach pins46–49. QA is included in both stages. The exact XOR input/output pins are retained in `docs/evidence/sheriff_pio_counter_bridge.json`.

The PIO values are the post-XOR physical lanes. The source-qualified PROM bridge therefore gives `prom_address={v_pio[7:3],hbyte[4:0]}`. Raw complemented timing outputs remain separate: 2L input5/output6 derives HREAD_n=!4I_QD; 2L input3/output4 derives !4I_QC. Neither is an extra PIO vertical/address bit.

One master clock with ce_counter represents the common CK/4 edge. The qualified horizontal module advances 4J on 4I carry and retains the source reload/blank network; the qualified vertical module advances on old horizontal-active plus horizontal terminal carry (horizontal RTL17–26, vertical RTL17–24). These source primitives use artificial diagnostic reset states. This report adds no physical reset or raster origin claim.

Connected original-coordinate viewboxes: sheet33 `[3650,900,5088,2920]` and `[3650,1850,5088,2930]`; sheet34 `[100,820,1740,2910]`. Source PDF/renders, viewports, module hashes and existing counter/serializer/flip/color/PROM proof hashes are retained in the JSON. No unrelated native proof was repeated. Exact Sheriff revision and electrical propagation remain open; the color-clock correction is documented separately in COLOR_CLOCK_REVIEW.md.
