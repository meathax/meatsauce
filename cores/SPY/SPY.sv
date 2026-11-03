// SPDX-License-Identifier: GPL-3.0-or-later
// MiSTer boundary; framework body is separate for scoped integration.
module emu (
    `include "sys/emu_ports.vh"
);
    `include "rtl/framework/spy_emu_body.vh"
endmodule
