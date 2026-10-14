# Separate restart with controls after gameplay resumes

Preserve the frozen 3901-field oracle. This separate real-MAME run retains its complete legal input prefix and adds right at 3920–3959, button2 at3980–3983 and button1 at4040–4053. Actual capture rows are one field later because the recorder reads ports before applying the next input event. The final native replay must use actual `frame_states.csv` rows without manual phase changes.

MAME0.289 `alpha68k_n.cpp` lines574–582 and628–631 define Kyros active-high P1 right mask4, button1 mask16, button2 mask32. Only these actual PCB controls change. No memory, CPU, clock or game-state edits are made. Button labels alone do not prove successful actions; displayed observations will qualify movement and any visible action separately. Hit and pickup remain unknown unless demonstrated.

No new native build is required; the acceptance agent holds the one merged-core simulation until this 4101-field input is qualified.
