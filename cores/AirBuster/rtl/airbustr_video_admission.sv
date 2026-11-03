// SPDX-License-Identifier: GPL-3.0-or-later
module airbustr_video_admission(
 input logic reference_profile,native_sync_qualified,rotation_enable,rotation_pause,
 output logic producer_enabled,select_reference_metadata
);
 assign producer_enabled=(reference_profile || native_sync_qualified) && rotation_enable && !rotation_pause;
 assign select_reference_metadata=reference_profile;
endmodule
