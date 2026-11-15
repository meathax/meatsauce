// GPL-3.0-or-later. Cave donor provenance: rtl/donor_sdram/baseline.json.
// Adaptation:45.6MHz refresh budget, latched masked single writes, reset pins and explicit acceptance.
// This file is a Codex-assisted rewrite based on the original work of
// Josh Bassett (nullobject).

// SDRAM command sequencer for the MiSTer-side 16-bit SDRAM interface.
// Leave 8 ms of the chip's 64 ms retention window for power/reset startup
// and bounded transaction deferral. Read recovery also permits the conservative
// BL+CL auto-precharge close used by the strict board model, followed by tRP.
module steel_sdram_chip #(parameter integer CLK_HZ=45600000, REFRESH_MS=56)(
  input         clock,
  input         reset,
  input         io_mem_rd,
  input         io_mem_wr,
  input  [24:0] io_mem_addr,
  input  [15:0] io_mem_din,
  input  [1:0]  io_mem_strobes,
  output [15:0] io_mem_dout,
  output        io_mem_wait_n,
  output        io_mem_accept,
  output        io_init_done,
  output        io_mem_valid,
  output        io_mem_burstDone,
  output        io_sdram_cs_n,
  output        io_sdram_ras_n,
  output        io_sdram_cas_n,
  output        io_sdram_we_n,
  output        io_sdram_oe_n,
  output [1:0]  io_sdram_bank,
  output [12:0] io_sdram_addr,
  output [15:0] io_sdram_din,
  output [1:0] io_sdram_dqm,
  input  [15:0] io_sdram_dout
);
  localparam [2:0] STATE_INIT         = 3'd0;
  localparam [2:0] STATE_MODE         = 3'd1;
  localparam [2:0] STATE_IDLE         = 3'd2;
  localparam [2:0] STATE_ACTIVE       = 3'd3;
  localparam [2:0] STATE_READ         = 3'd4;
  localparam [2:0] STATE_WRITE        = 3'd5;
  localparam [2:0] STATE_REFRESH      = 3'd6;

  localparam [3:0] COMMAND_MODE       = 4'h0;
  localparam [3:0] COMMAND_REFRESH    = 4'h1;
  localparam [3:0] COMMAND_PRECHARGE  = 4'h2;
  localparam [3:0] COMMAND_ACTIVE     = 4'h3;
  localparam [3:0] COMMAND_WRITE      = 4'h4;
  localparam [3:0] COMMAND_READ       = 4'h5;
  localparam [3:0] COMMAND_NOP        = 4'h7;
  localparam [3:0] COMMAND_DESELECT   = 4'h8;

  localparam [14:0] INIT_PRECHARGE_AT = 15'h4AFF;
  localparam [14:0] INIT_REFRESH0_AT  = 15'h4B01;
  localparam [14:0] INIT_REFRESH1_AT  = 15'h4B07;
  localparam [14:0] INIT_MODE_AT      = 15'h4B0D;
  localparam [12:0] ADDR_PRECHARGE    = 13'h400;
  localparam [12:0] ADDR_MODE         = 13'h222;

  localparam [14:0] MODE_DONE_AT      = 15'h0001;
  // Four CL2 beats are still captured at the original data edges. Delay the
  // following command to READ+8 clocks: BL4+CL2 close plus two recovery clocks.
  // This is conservative for vendor SDR SDRAM's overlapping internal precharge.
  localparam [14:0] READ_DONE_AT      = 15'h0007;
  localparam [14:0] REFRESH_DONE_AT   = 15'h0005;
  localparam [14:0] WRITE_DONE_AT     = 15'h0006;
  localparam [14:0] WRITE_BURST_LAST  = 15'h0003;
  localparam integer REFRESH_TRIGGER = (CLK_HZ/1000)*REFRESH_MS/8192-16;

  reg  [2:0]  stateReg;
  reg  [3:0]  commandReg;
  reg         requestReg_wr;
  reg  [1:0]  requestReg_addr_bank;
  reg  [8:0]  requestReg_addr_col;
  reg  [1:0]  bankReg;
  reg  [12:0] addrReg;
  reg  [15:0] dinReg;
  reg  [15:0] doutReg;
  reg  [14:0] waitCounter;
  reg  [9:0]  refreshCounter;
  reg         validReg;
  reg         readBurstDoneReg;
  reg         writeDoneReg;
  reg [15:0] requestReg_data;
  reg [1:0] requestReg_strobes;

  wire        isReadWrite = io_mem_rd | io_mem_wr;
  wire        init = stateReg == STATE_INIT;
  wire        mode = stateReg == STATE_MODE;
  wire        idle = stateReg == STATE_IDLE;
  wire        active = stateReg == STATE_ACTIVE;
  wire        read = stateReg == STATE_READ;
  wire        write = stateReg == STATE_WRITE;
  wire        refresh = stateReg == STATE_REFRESH;

  wire        initDeselect = waitCounter == 15'h0000;
  wire        initPrecharge = waitCounter == INIT_PRECHARGE_AT;
  wire        initRefresh = waitCounter == INIT_REFRESH0_AT || waitCounter == INIT_REFRESH1_AT;
  wire        initMode = waitCounter == INIT_MODE_AT;
  wire        modeDone = waitCounter == MODE_DONE_AT;
  wire        readDone = waitCounter == READ_DONE_AT;
  wire        refreshDone = waitCounter == REFRESH_DONE_AT;
  wire        writeDone = waitCounter == WRITE_DONE_AT;
  wire        triggerRefresh = refreshCounter > REFRESH_TRIGGER;
  wire        startActiveAfterRefresh = refresh & refreshDone & isReadWrite;

  reg  [2:0]  nextState;
  reg  [3:0]  nextCommand;
  reg  [12:0] nextAddr;

  wire        latchRequest = stateReg != STATE_ACTIVE && nextState == STATE_ACTIVE;

  always @(*) begin
    nextState = stateReg;
    nextCommand = COMMAND_NOP;
    // The address bus only matters on command cycles. Keeping a constant
    // default avoids feedback/hold logic on the SDRAM output register.
    nextAddr = ADDR_PRECHARGE;

    case (stateReg)
      STATE_INIT: begin
        nextAddr = initMode ? ADDR_MODE : ADDR_PRECHARGE;
        if (initDeselect)
          nextCommand = COMMAND_DESELECT;
        else if (initPrecharge)
          nextCommand = COMMAND_PRECHARGE;
        else if (initRefresh)
          nextCommand = COMMAND_REFRESH;
        else if (initMode) begin
          nextCommand = COMMAND_MODE;
          nextState = STATE_MODE;
        end
      end

      STATE_MODE: begin
        if (modeDone)
          nextState = STATE_IDLE;
      end

      STATE_IDLE: begin
        if (triggerRefresh) begin
          nextCommand = COMMAND_REFRESH;
          nextState = STATE_REFRESH;
        end
        else if (isReadWrite) begin
          nextCommand = COMMAND_ACTIVE;
          nextState = STATE_ACTIVE;
          nextAddr = io_mem_addr[22:10];
        end
      end

      STATE_ACTIVE: begin
        if (modeDone) begin
          nextCommand = requestReg_wr ? COMMAND_WRITE : COMMAND_READ;
          nextState = requestReg_wr ? STATE_WRITE : STATE_READ;
          nextAddr = {4'h2, requestReg_addr_col};
        end
      end

      STATE_READ: begin
        if (readDone) begin
          if (triggerRefresh) begin
            nextCommand = COMMAND_REFRESH;
            nextState = STATE_REFRESH;
          end
          else if (isReadWrite) begin
            nextCommand = COMMAND_ACTIVE;
            nextState = STATE_ACTIVE;
            nextAddr = io_mem_addr[22:10];
          end
          else begin
            nextState = STATE_IDLE;
          end
        end
      end

      STATE_WRITE: begin
        if (writeDone) begin
          if (triggerRefresh) begin
            nextCommand = COMMAND_REFRESH;
            nextState = STATE_REFRESH;
          end
          else if (isReadWrite) begin
            nextCommand = COMMAND_ACTIVE;
            nextState = STATE_ACTIVE;
            nextAddr = io_mem_addr[22:10];
          end
          else begin
            nextState = STATE_IDLE;
          end
        end
      end

      STATE_REFRESH: begin
        if (refreshDone) begin
          if (isReadWrite) begin
            nextCommand = COMMAND_ACTIVE;
            nextState = STATE_ACTIVE;
            nextAddr = io_mem_addr[22:10];
          end
          else begin
            nextState = STATE_IDLE;
          end
        end
      end

      default: begin
        nextState = STATE_INIT;
        nextCommand = COMMAND_NOP;
        nextAddr = ADDR_PRECHARGE;
      end
    endcase
  end

  always @(posedge clock) begin
    if (reset) begin
      stateReg <= STATE_INIT;
      commandReg <= COMMAND_NOP;
      waitCounter <= 15'h0000;
      refreshCounter <= 10'h000;
      validReg <= 1'b0;
      readBurstDoneReg <= 1'b0;
      writeDoneReg <= 0;bankReg <= 0;requestReg_wr <= 0;
      requestReg_addr_bank <= 0;requestReg_addr_col <= 0;
      requestReg_data <= 0;requestReg_strobes <= 0;
    end
    else begin
      stateReg <= nextState;
      commandReg <= nextCommand;
      waitCounter <= nextState == stateReg ? waitCounter + 15'h0001 : 15'h0000;

      if (refresh && waitCounter == 15'h0000)
        refreshCounter <= 10'h000;
      else if (stateReg != STATE_INIT && stateReg != STATE_MODE)
        refreshCounter <= refreshCounter + 10'h001;

      // CL2 launches after the next chip edge. doutReg captures that first
      // beat on master edge 2; the backend consumes it on master edge 3.
      // Keep four valid beats; completion waits for command recovery separately.
      validReg <= read && waitCounter>=15'd1 && waitCounter<=15'd4;
      readBurstDoneReg <= read & readDone;
      writeDoneReg <= write & writeDone;
    end

    if (!reset && latchRequest) begin
      requestReg_wr <= io_mem_wr;
      requestReg_data <= io_mem_din;requestReg_strobes <= io_mem_strobes;
      requestReg_addr_bank <= io_mem_addr[24:23];
      requestReg_addr_col <= io_mem_addr[9:1];
    end

    if (!reset && !(init | mode)) begin
      if ((idle & isReadWrite & !triggerRefresh) ||
          (read & readDone & isReadWrite & !triggerRefresh) ||
          (write & writeDone & isReadWrite & !triggerRefresh) ||
          startActiveAfterRefresh) begin
        bankReg <= io_mem_addr[24:23];
      end
      else if (active & modeDone) begin
        bankReg <= requestReg_addr_bank;
      end
    end

    dinReg <= io_mem_din;
    doutReg <= io_sdram_dout;
  end

  always @(posedge clock) begin
    addrReg <= nextAddr;
  end

  assign io_mem_dout = doutReg;
  assign io_mem_accept = latchRequest && isReadWrite && !reset;
  assign io_init_done = !(init || mode) && !reset;
  assign io_mem_wait_n = (idle && !isReadWrite && !reset) || io_mem_accept;
  assign io_mem_valid = validReg;
  assign io_mem_burstDone = readBurstDoneReg | writeDoneReg;

  assign io_sdram_cs_n = commandReg[3];
  assign io_sdram_ras_n = commandReg[2];
  assign io_sdram_cas_n = commandReg[1];
  assign io_sdram_we_n = commandReg[0];
  // Pin control registers (same cycle as commandReg): lets the fitter place the DQ
  // output-enable and DQM drivers in the I/O cells (FAST_OUTPUT_ENABLE_REGISTER).
  // Strobes are latched only on entry to STATE_ACTIVE, so they are stable when
  // WRITE issues; pin values are cycle-identical to the former combinational decode.
  reg         oeNReg;
  reg  [1:0]  dqmReg;
  always @(posedge clock) begin
    if (reset) begin oeNReg <= 1'b1; dqmReg <= 2'b00; end
    else begin
      oeNReg <= nextCommand != COMMAND_WRITE;
      dqmReg <= nextCommand == COMMAND_WRITE ? ~requestReg_strobes : 2'b00;
    end
  end
  assign io_sdram_oe_n = oeNReg;
  assign io_sdram_bank = bankReg;
  assign io_sdram_addr = addrReg;
  assign io_sdram_din = requestReg_data;
  assign io_sdram_dqm = dqmReg;
endmodule
