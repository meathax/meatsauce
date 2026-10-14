//------------------------------------------------------------------------------
// AT28C16 2 KB EEPROM as the 68000 sees it: a byte at every even address of
// A00000-A00FFF (the upper data lane). Reads answer the clock after the
// request; writes are immediate (the real part's 10 ms write cycle is not
// modelled -- MAME does not either). A load port fills it from the Pocket's
// save slot during reset and a read-out port streams it back for saving.
// Powers up erased (0xFF), as MAME's nvram_default does, so a first boot with
// no save file lets the game initialise its settings.
//------------------------------------------------------------------------------
`default_nettype none

module at28c16 #(
    parameter HEXDIR = "rtl/data"
) (
    input  logic        clk,
    input  logic        reset,
    // CPU port
    input  logic [10:0] addr,
    input  logic        req,
    input  logic        we,
    input  logic  [7:0] wdata,
    output logic  [7:0] q,
    output logic        ack,
    // load (works during reset)
    input  logic        ld_we,
    input  logic [10:0] ld_addr,
    input  logic  [7:0] ld_data,
    // read-out for saving: rd_addr -> rd_q the next clock
    input  logic [10:0] rd_addr,
    output logic  [7:0] rd_q,
    output logic        dirty          // toggles on every CPU write (the save logic watches for changes)
);
    logic [7:0] mem [2048];
    initial $readmemh({HEXDIR, "/at28c16_erased.hex"}, mem);
    logic busy;
    wire  go = req & ~busy;
    always_ff @(posedge clk) begin
        if (reset) begin busy <= 1'b0; ack <= 1'b0; end
        else begin
            ack <= go;
            if (go) busy <= 1'b1; else if (!req) busy <= 1'b0;
        end
    end
    // single writer process: CPU writes and loads
    always_ff @(posedge clk) begin
        if (ld_we) mem[ld_addr] <= ld_data;
        else if (go && we && !reset) mem[addr] <= wdata;
        q <= mem[addr];
    end
    always_ff @(posedge clk) rd_q <= mem[rd_addr];
    always_ff @(posedge clk) begin
        if (reset) dirty <= 1'b0;
        else if (go && we) dirty <= ~dirty;
    end
endmodule
