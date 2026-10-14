// SPDX-License-Identifier: GPL-3.0-or-later
package cs_bus_pkg;
    typedef struct packed {
        logic [31:0] addr;
        logic [31:0] data;
        logic [3:0]  strb;
        logic        write;
    } request_t;

    typedef struct packed {
        logic [31:0] data;
        logic        error;
    } response_t;
endpackage
