library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all; 

library mem;

library altera_mf;                        -- Taito FX-1B/1Z FRAM M10K (altsyncram)
use altera_mf.altera_mf_components.all;

entity memorymux is
   port 
   (
      boot_debug : out std_logic_vector(255 downto 0) := (others => '0');
      clk1x                : in  std_logic;
      clk2x                : in  std_logic;
      ce                   : in  std_logic;
      reset                : in  std_logic;
      
      pauseNext            : in  std_logic;
      isIdle               : out std_logic;
      
      loadExe              : in  std_logic;
      exe_initial_pc       : in  unsigned(31 downto 0);
      exe_initial_gp       : in  unsigned(31 downto 0);
      exe_load_address     : in  unsigned(31 downto 0);
      exe_file_size        : in  unsigned(31 downto 0);
      exe_stackpointer     : in  unsigned(31 downto 0);
      reset_exe            : out std_logic := '0';
      
      fastboot             : in  std_logic;
      PATCHSERIAL          : in  std_logic;
      TURBO                : in  std_logic;
      ROM_PREFETCH         : in  std_logic;
      FAST_BIOS            : in  std_logic;
      -- The PR2 BIOS image is stored in SDRAM. In production the SDRAM
      -- response supplies the transport latency; retaining the original
      -- external ROM-bus wait after READBIOS would double-count that access
      -- and can expire the board watchdog before the BIOS reaches ATA init.
      -- Standalone memorymux benches leave this at '0' so their explicit
      -- memory-control pacing contract remains covered.
      BIOS_SDRAM_PACING    : in  std_logic := '0';
      region_in            : in  std_logic_vector(1 downto 0);

      ram_dataWrite        : out std_logic_vector(31 downto 0) := (others => '0');
      ram_dataRead         : in  std_logic_vector(31 downto 0);
      ram_Adr              : out std_logic_vector(26 downto 0) := (others => '0');
      ram_be               : out std_logic_vector(3 downto 0) := (others => '0');
      ram_rnw              : out std_logic := '0';
      ram_ena              : out std_logic := '0';
      ram_cache            : out std_logic := '0';
      ram_rom_prefetch     : out std_logic := '0';
      ram_done             : in  std_logic;

      -- PR2 ROM line-fill transport.  A production SDRAM controller can
      -- return the four words of a cache read through the clk3x cache bus;
      -- psx_top collects that bus and presents one stable line plus a
      -- completion pulse here.  Defaults keep the standalone memorymux
      -- directed benches on the scalar path.
      rom_burst_enable     : in  std_logic := '0';
      rom_burst_done       : in  std_logic := '0';
      rom_burst_data       : in  std_logic_vector(127 downto 0) := (others => '0');
      
      mem_in_request       : in  std_logic;
      mem_in_rnw           : in  std_logic; 
      mem_in_isData        : in  std_logic; 
      mem_in_isCache       : in  std_logic;
      mem_in_oldtagvalids  : in  std_logic_vector(3 downto 0);      
      mem_in_addressInstr  : in  unsigned(31 downto 0); 
      mem_in_addressData   : in  unsigned(31 downto 0); 
      mem_in_reqsize       : in  unsigned(1 downto 0); 
      mem_in_writeMask     : in  std_logic_vector(3 downto 0); 
      mem_in_dataWrite     : in  std_logic_vector(31 downto 0); 
      mem_dataRead         : out std_logic_vector(31 downto 0); 
      mem_done             : out std_logic;
      mem_fifofull         : out std_logic;
      mem_tagvalids        : out std_logic_vector(3 downto 0);
      
      bios_memctrl         : in  unsigned(13 downto 0);
      
      ex1_memctrl          : in  unsigned(13 downto 0);
      --bus_exp1_addr        : out unsigned(22 downto 0); 
      --bus_exp1_dataWrite   : out std_logic_vector(7 downto 0);
      bus_exp1_read        : out std_logic;
      --bus_exp1_write       : out std_logic;
      bus_exp1_dataRead    : in  std_logic_vector(7 downto 0);
      
      bus_memc_addr        : out unsigned(5 downto 0); 
      bus_memc_dataWrite   : out std_logic_vector(31 downto 0);
      bus_memc_read        : out std_logic;
      bus_memc_write       : out std_logic;
      bus_memc_dataRead    : in  std_logic_vector(31 downto 0);
      
      bus_pad_addr         : out unsigned(3 downto 0); 
      bus_pad_dataWrite    : out std_logic_vector(31 downto 0);
      bus_pad_read         : out std_logic;
      bus_pad_write        : out std_logic;
      bus_pad_writeMask    : out std_logic_vector(3 downto 0);
      bus_pad_dataRead     : in  std_logic_vector(31 downto 0);
      
      bus_sio_addr         : out unsigned(3 downto 0); 
      bus_sio_dataWrite    : out std_logic_vector(31 downto 0);
      bus_sio_read         : out std_logic;
      bus_sio_write        : out std_logic;
      bus_sio_writeMask    : out std_logic_vector(3 downto 0);
      bus_sio_dataRead     : in  std_logic_vector(31 downto 0);
      
      bus_memc2_addr       : out unsigned(3 downto 0); 
      bus_memc2_dataWrite  : out std_logic_vector(31 downto 0);
      bus_memc2_read       : out std_logic;
      bus_memc2_write      : out std_logic;
      bus_memc2_dataRead   : in  std_logic_vector(31 downto 0);
      
      bus_irq_addr         : out unsigned(3 downto 0); 
      bus_irq_dataWrite    : out std_logic_vector(31 downto 0);
      bus_irq_read         : out std_logic;
      bus_irq_write        : out std_logic;
      bus_irq_dataRead     : in  std_logic_vector(31 downto 0);
      
      bus_dma_addr         : out unsigned(6 downto 0); 
      bus_dma_dataWrite    : out std_logic_vector(31 downto 0);
      bus_dma_read         : out std_logic;
      bus_dma_write        : out std_logic;
      bus_dma_dataRead     : in  std_logic_vector(31 downto 0);
      
      bus_tmr_addr         : out unsigned(5 downto 0); 
      bus_tmr_dataWrite    : out std_logic_vector(31 downto 0);
      bus_tmr_read         : out std_logic;
      bus_tmr_write        : out std_logic;
      bus_tmr_dataRead     : in  std_logic_vector(31 downto 0);
      
      cd_memctrl           : in  unsigned(13 downto 0);
      bus_cd_addr          : out unsigned(3 downto 0); 
      bus_cd_dataWrite     : out std_logic_vector(7 downto 0);
      bus_cd_read          : out std_logic;
      bus_cd_write         : out std_logic;
      bus_cd_dataRead      : in  std_logic_vector(7 downto 0);
      
      bus_gpu_addr         : out unsigned(3 downto 0); 
      bus_gpu_dataWrite    : out std_logic_vector(31 downto 0);
      bus_gpu_read         : out std_logic;
      bus_gpu_write        : out std_logic;
      bus_gpu_dataRead     : in  std_logic_vector(31 downto 0);
      bus_gpu_stall        : in  std_logic;
      
      bus_mdec_addr        : out unsigned(3 downto 0);
      bus_mdec_dataWrite   : out std_logic_vector(31 downto 0);
      bus_mdec_read        : out std_logic;
      bus_mdec_write       : out std_logic;
      bus_mdec_dataRead    : in  std_logic_vector(31 downto 0);

      -- ZN-1 arcade I/O (0x1FA00000-0x1FAFFFFF)
      bus_znio_addr        : out unsigned(20 downto 0);
      bus_znio_dataWrite   : out std_logic_vector(31 downto 0);
      bus_znio_read        : out std_logic;
      bus_znio_write       : out std_logic;
      bus_znio_writeMask   : out std_logic_vector(3 downto 0);
      bus_znio_dataRead    : in  std_logic_vector(31 downto 0);

      -- Atari PR2 board glue: watchdog, VT83C461/ATA and IRQ control.
      bus_pr2_addr         : out unsigned(28 downto 0);
      bus_pr2_dataWrite    : out std_logic_vector(31 downto 0);
      bus_pr2_read         : out std_logic;
      bus_pr2_write        : out std_logic;
      bus_pr2_writeMask    : out std_logic_vector(3 downto 0);
      bus_pr2_reqsize      : out unsigned(1 downto 0);
      bus_pr2_dataRead     : in  std_logic_vector(31 downto 0);

      -- ZN platform: 0=Visco, 1=Raizing, 2=Taito FX, 3=Atlus, 4=Tecmo
      zn_platform          : in  std_logic_vector(3 downto 0) := "0000";
      -- B-inst5: live bank register readout for the JTAG instrument (BR2 bank-2 probe)
      dbg_zn_bank          : out std_logic_vector(2 downto 0) := (others => '0');

      spu_memctrl          : in  unsigned(13 downto 0);
      bus_spu_addr         : out unsigned(9 downto 0) := (others => '0'); 
      bus_spu_dataWrite    : out std_logic_vector(15 downto 0);
      bus_spu_read         : out std_logic;
      bus_spu_write        : out std_logic;
      bus_spu_dataRead     : in  std_logic_vector(15 downto 0);
      
      ex2_memctrl          : in  unsigned(13 downto 0);
      bus_exp2_addr        : out unsigned(12 downto 0); 
      bus_exp2_dataWrite   : out std_logic_vector(7 downto 0);
      bus_exp2_read        : out std_logic;
      bus_exp2_write       : out std_logic;
      bus_exp2_dataRead    : in  std_logic_vector(7 downto 0);
      
      ex3_memctrl          : in  unsigned(13 downto 0);
      --bus_exp3_dataWrite   : out std_logic_vector(7 downto 0);
      bus_exp3_read        : out std_logic;
      --bus_exp3_write       : out std_logic;
      bus_exp3_dataRead    : in  std_logic_vector(15 downto 0);
      
      com0_delay           : in  unsigned(3 downto 0);
      com1_delay           : in  unsigned(3 downto 0);
      com2_delay           : in  unsigned(3 downto 0);
      com3_delay           : in  unsigned(3 downto 0);
      
      loading_savestate    : in  std_logic;
      SS_reset             : in  std_logic;
      SS_DataWrite         : in  std_logic_vector(31 downto 0);
      SS_Adr               : in  unsigned(18 downto 0);
      SS_wren_SDRam        : in  std_logic;
      SS_rden_SDRam        : in  std_logic;

      -- build #39: expose Tecmo bank register for debug instrumentation
      zn_bank_8mb_out      : out std_logic_vector(2 downto 0);

      -- build #47: TIGHT-window classify of banked-ROM data-read for the cube palette.
      -- GREEN window = ONLY the green row [0x1F644800,0x1F644A00) (256 entries) at bank 0.
      --   green -> read delivers green (read-path CLEAN, bug downstream: CPU store / DMA)
      --   red   -> SMOKING GUN: green row reads RED (SDRAM/read-path/byte-lane corruption)
      -- RED-ROW control = [0x1F645000,0x1F645200): proves instrument distinguishes rows
      --   (expect this read to return red -> dbg_palrd_redrow_red lit).
      dbg_palrd_green      : out std_logic := '0';
      dbg_palrd_red        : out std_logic := '0';
      dbg_palrd_any        : out std_logic := '0';
      dbg_palrd_redrow_red : out std_logic := '0';
      -- build #50: raw 32-bit SDRAM word latched at the green anchor (CPU 0x1F644810)
      dbg_palrd_value      : out std_logic_vector(31 downto 0) := (others => '0');
      -- build #51: computed SDRAM byte address (ram_Adr) latched at the green anchor
      dbg_palrd_addr       : out std_logic_vector(31 downto 0) := (others => '0');
      -- build #52: 8 contiguous bank0 words [0x1F644800,0x1F644820) packed lo=word0..hi=word7
      dbg_palrd_words      : out std_logic_vector(255 downto 0) := (others => '0');
      -- build #135: CPU read at cube CLUT source address (0x1F7B610C in rp00.u0216)
      -- (1) any read in window [0x1F7B6000, 0x1F7B6200) (cube CLUT page)
      -- (2) exact read at 0x1F7B610C (the cube CLUT line)
      -- (3) at exact match AND bank=0 (correct bank selection)
      dbg_cubeclut_window_seen : out std_logic := '0';
      dbg_cubeclut_exact_seen  : out std_logic := '0';
      dbg_cubeclut_bank0_seen  : out std_logic := '0';

      -- B-meas: CPU memory-stall classification (combinational; drives debug
      -- perf bars only). Each is high while the CPU is stalled on that access
      -- type. Disjoint: ROM read uses state=READROM (readram=0); RAM read uses
      -- readram=1; RAM write uses writeram=1.
      dbg_busy_rom             : out std_logic := '0';
      dbg_busy_ramrd           : out std_logic := '0';
      dbg_busy_ramwr           : out std_logic := '0';
      -- B-meas10: latched offset of the last ZN-IO read in 0x1FA20000-0x1FBFFFFF
      -- (the logo poll). Reveals the exact polled register.
      dbg_znio_addr            : out std_logic_vector(20 downto 0) := (others => '0')
   );
end entity;

architecture arch of memorymux is
  
   type tState is
   (
      IDLE,
      WAITFORRAMREAD,
      WAITFORRAMWRITE,
      READBIOS,
      READROM,
      -- ROM prefetch: after a ROM-read miss, fire 3 more reads back-to-back
      -- to fill the remaining slots of a 16-byte line in rom_buf_w0..w3.
      ROM_PF_FILL,
      ROM_PF_WAIT,
      BUSWRITE,
      BUSWRITEEXTERNAL,
      BUSREADEXTERNAL,
      BUSREADREQUEST,
      BUSREAD,
      BUSREAD_CDSTUB,
      BUSREAD_UNKNOWNIO,
      BUSREAD_SNDSTUB,   -- Taito FX-1B/1Z sound-comm read stub (returns 0)
      FRAMWAIT,          -- Taito FRAM: 1 cycle for the M10K to register fram_addr
      BUSREAD_FRAM,      -- Taito FX-1B/1Z FM1208S FRAM read completion
      WAITING,
      
      EXEPATCHBIOSWRITE,
      EXEPATCHBIOSWAIT,
      EXECOPYREAD,
      EXECOPYWRITE,
      -- Wait for the collected four-word SDRAM cache line.  This state is
      -- appended so the existing diagnostic state numbers remain stable.
      ROM_PF_BURST_WAIT
   );
   signal state                  : tState := IDLE;
      
   signal mem_request            : std_logic;
   signal mem_rnw                : std_logic; 
   signal mem_isData             : std_logic; 
   signal mem_isCache            : std_logic; 
   signal mem_oldtagvalids       : std_logic_vector(3 downto 0);
   signal mem_addressInstr       : unsigned(31 downto 0); 
   signal mem_addressData        : unsigned(31 downto 0); 
   signal mem_reqsize            : unsigned(1 downto 0); 
   signal mem_writeMask          : std_logic_vector(3 downto 0); 
   signal mem_dataWrite          : std_logic_vector(31 downto 0); 
   
   signal mem_save_request       : std_logic := '0'; 
   signal mem_save_rnw           : std_logic := '0'; 
   signal mem_save_isData        : std_logic := '0'; 
   signal mem_save_isCache       : std_logic := '0'; 
   signal mem_save_oldtagvalids  : std_logic_vector(3 downto 0) := (others => '0');
   signal mem_save_addressInstr  : unsigned(31 downto 0) := (others => '0'); 
   signal mem_save_addressData   : unsigned(31 downto 0) := (others => '0');
   signal mem_save_reqsize       : unsigned(1 downto 0) := (others => '0'); 
   signal mem_save_writeMask     : std_logic_vector(3 downto 0) := (others => '0');
   signal mem_save_dataWrite     : std_logic_vector(31 downto 0) := (others => '0'); 
   
   signal writeFifo_Din          : std_logic_vector(69 downto 0);
   signal writeFifo_Wr           : std_logic; 
   signal writeFifo_NearFull     : std_logic; 
   signal writeFifo_Dout         : std_logic_vector(69 downto 0);
   signal writeFifo_Rd           : std_logic;
   signal writeFifo_Empty        : std_logic;
   signal writeFifo_busy         : std_logic;
   signal writeFifo_Wr_1         : std_logic;
   
   signal bios_page_open         : std_logic;
   signal ram_page_open          : std_logic;
   signal ram_page_addr          : unsigned(10 downto 0);
   signal ram_load_last          : integer range 0 to 7 := 0;

   -- Narrow BIOS control shadow for the boot poll at normalized 0x1FC0BF08
   -- (physical/runtime BFC0BF08).  The surrounding BIOS window remains the
   -- normal SDRAM-backed path; only this exact word is locally stateful.
   signal bios_control_shadow    : std_logic_vector(31 downto 0) := (others => '0');

   -- Optional 16-byte line buffer for PR2's fixed, immutable 2 MiB program
   -- image. A miss returns its requested word, then fills the other three.
   -- Reset must accompany image replacement; partial fills are never hits.
   signal rom_buf_valid          : std_logic := '0';
   signal rom_buf_word           : std_logic_vector(31 downto 0);
   signal rom_buf_saved_word     : std_logic_vector(31 downto 0);

   -- ============================================================
   -- Taito FX-1B / FX-1Z FM1208S FRAM (RAMTRON 4Kbit non-volatile RAM, 512 x 8)
   -- Used by gdarius/raystorm/ftimpact (& variants), Taito platform (zn_platform = "0010").
   -- In MAME (sony/zn.cpp taito_fx1z_state) it is a PLAIN memory-mapped array at
   -- 0x1FB00000-0x1FB003FF (umask 0x00ff00ff), read/written via trivial fram_r/fram_w
   -- (NOT a serial/bit-banged protocol). Blank default = 0xFF (nvram DEFAULT_ALL_1).
   -- gdarius checksums this region at boot (PC 0x8006DD60: sum of low bytes over
   -- 0x1FB00060 for 0x1D0 halfwords) and re-initialises it if invalid. Without a
   -- working read/write model the FPGA returned 0x00000000 on reads and DROPPED writes,
   -- so the checksum/reinit cycle could never succeed and the game never reached gameplay.
   -- 256 x 32-bit words cover the full 0x400 window; byte-lane write mask applied.
   -- Implemented as an M10K dpram (NOT logic registers) — an inline array here synthesises to
   -- ~8000 FFs (~2000 ALMs) and overflows the device. The dpram gives free block RAM. Power-up
   -- state is 0x00 (no init) rather than MAME's 0xFF, which is harmless: gdarius checksums and
   -- REINITS the region on any invalid content, and writes now persist, so it self-heals to a
   -- valid state and boots. (For byte-exact MAME parity / true persistence, an ioctl-loaded MIF
   -- + save path is the follow-up — same NVRAM infra the FX-1A EEPROM needs.)
   signal fram_addr              : std_logic_vector(7 downto 0) := (others => '0');
   signal fram_wren              : std_logic := '0';
   signal fram_be                : std_logic_vector(3 downto 0) := (others => '0');
   signal fram_din               : std_logic_vector(31 downto 0) := (others => '0');
   signal fram_q                 : std_logic_vector(31 downto 0);
    signal rom_buf_tag            : std_logic_vector(22 downto 4) := (others => '0');
    -- A line may be consumed as each word arrives.  The tag is installed on
    -- the cold miss, while this mask excludes every unwritten word.
    signal rom_buf_word_valid     : std_logic_vector(3 downto 0) := (others => '0');
    signal rom_buf_w0             : std_logic_vector(31 downto 0) := (others => '0');
   signal rom_buf_w1             : std_logic_vector(31 downto 0) := (others => '0');
   signal rom_buf_w2             : std_logic_vector(31 downto 0) := (others => '0');
   signal rom_buf_w3             : std_logic_vector(31 downto 0) := (others => '0');

   -- In-flight prefetch state:
   --   pf_line_addr_base : pre-computed SDRAM byte address of slot 0 of the line
   --   pf_first_slot     : the slot that was satisfied by the cold miss; we skip it
   --   pf_curr_slot      : which slot's read is currently in flight in ROM_PF_FILL/WAIT
   --   pf_remaining      : 3,2,1 — how many slots still to fill (0 = done, write back valid)
   --   pf_tag_snap       : mem_addressData[22:4] at the cold miss; saved into rom_buf_tag on completion
   signal pf_line_addr_base      : std_logic_vector(26 downto 0) := (others => '0');
   signal pf_first_slot          : std_logic_vector(1 downto 0) := "00";
   signal pf_curr_slot           : std_logic_vector(1 downto 0) := "00";
   signal pf_remaining           : integer range 0 to 3 := 0;
   signal pf_tag_snap            : std_logic_vector(22 downto 4) := (others => '0');
   signal pf_first_rotate_bits   : std_logic_vector(1 downto 0) := "00";
   signal pf_first_returned      : std_logic := '0';
   signal rom_speculative_burst  : std_logic := '0';
   
    signal waitcnt                : integer range 0 to 255;

    -- BIOS instruction reads are represented by one 32-bit SDRAM transfer,
    -- but the PSX memory-control register describes the external ROM bus
    -- timing.  Model the documented first/sequential access shape here so the
    -- active `bios_memctrl` and COMMON-delay values own the pacing.  The extra
    -- first-transfer cycle preserves the pre-existing reset cadence: with
    -- BIOS=0x243f and COMMON=0x1125 this returns 26 for the first transfer and
    -- 25 for consecutive transfers.  This is deliberately independent of the
    -- SDRAM response: READBIOS still waits for `ram_done` before WAITING starts.
    function bios_instruction_wait(
       constant control : unsigned(13 downto 0);
       constant com0    : unsigned(3 downto 0);
       constant com2    : unsigned(3 downto 0);
       constant com3    : unsigned(3 downto 0);
       constant first_transfer : boolean
    ) return integer is
       -- Recovery can start at -1; the largest completed access is
       -- (15 - 1) + 15 + 15 + 2 = 46 clocks. Four accesses plus the
       -- first-transfer clock therefore fit in 185 clocks.
       variable first_access      : integer range -1 to 46 := 0;
       variable sequential_access : integer range -1 to 46 := 0;
       variable minimum_access    : integer range 0 to 15 := 0;
       variable total_access      : integer range 0 to 185 := 0;
    begin
       -- PSX-SPX's documented memory-control approximation: recovery and
       -- floating periods extend both accesses; pre-strobe establishes the
       -- minimum; the read-delay field then applies to each bus transfer.
       if (control(8) = '1') then
          first_access      := first_access + to_integer(com0) - 1;
          sequential_access := sequential_access + to_integer(com0) - 1;
       end if;
       if (control(10) = '1') then
          first_access      := first_access + to_integer(com2);
          sequential_access := sequential_access + to_integer(com2);
       end if;
       if (control(11) = '1') then
          minimum_access := to_integer(com3);
       end if;
       if (first_access < 6) then
          first_access := first_access + 1;
       end if;
       first_access      := first_access + to_integer(control(7 downto 4)) + 2;
       sequential_access := sequential_access + to_integer(control(7 downto 4)) + 2;
       if (first_access < minimum_access + 6) then
          first_access := minimum_access + 6;
       end if;
       if (sequential_access < minimum_access + 2) then
          sequential_access := minimum_access + 2;
       end if;

       -- An instruction fetch is a word.  The configured ROM-bus width
       -- determines whether that word occupies four byte or two halfword
       -- transfers.  The data-side auto-increment behavior is not observable
       -- on this scalar instruction interface, so it does not change this
       -- transfer count.
       if (control(12) = '1') then
          total_access := first_access + sequential_access;
       else
          -- Fixed factors expressed as additions avoid a variable DSP
          -- multiplier for the two possible ROM-bus widths.
          total_access := first_access + sequential_access + sequential_access + sequential_access;
       end if;
       if (first_transfer) then
          total_access := total_access + 1;
       end if;
       return total_access;
    end function;

   -- EEPROM (0x1FAF0000) reads go through the zn1_io altsyncram, which registers its address
   -- internally (+1 cycle) unlike the combinational znio input/coin registers. Without an extra
   -- cycle the BUSREAD samples the PREVIOUS address's word (stale). Sequential signature reads
   -- (psyforce/raystorm validate the "TAITO_TG" NVRAM byte-by-byte) then read shifted data →
   -- validation fails → EE-PROM ERROR. This flag inserts one wait in BUSREADREQUEST for EEPROM
   -- reads only. (JTAG-confirmed: without it, words 1-4 all read word-0's value.)
   signal ee_read_wait           : std_logic := '0';

   signal mem_dataRead_buf       : std_logic_vector(31 downto 0);
   signal mem_done_buf           : std_logic := '0';
         
   signal readram                : std_logic := '0';
   signal writeram               : std_logic := '0';
         
   signal data_ram               : std_logic_vector(31 downto 0);
   signal data_ram_rotate        : std_logic_vector(31 downto 0);
   signal ram_rotate_bits        : std_logic_vector(1 downto 0);
   signal region                 : std_logic_vector(1 downto 0);

   -- One-word CPU data forwarding entry.  The BIOS delay routine is a
   -- read-after-write loop (lw/lw/sw) over one stack word.  The SDRAM
   -- controller correctly completes every request, but its scalar transport
   -- costs about six clk1x ticks per word.  Forwarding the most recently
   -- observed CPU RAM word removes the redundant reads while preserving the
   -- existing controller and watchdog timing for all other addresses.
   signal cpu_ram_cache_valid   : std_logic := '0';
   signal cpu_ram_cache_addr    : std_logic_vector(20 downto 0) := (others => '0');
   signal cpu_ram_cache_data    : std_logic_vector(31 downto 0) := (others => '0');
   signal cpu_ram_pending_valid : std_logic := '0';
   signal cpu_ram_pending_addr  : std_logic_vector(20 downto 0) := (others => '0');
   -- The forwarding entry is a PR2-specific timing repair.  memorymux is
   -- shared by other ZN/PSX profiles, so keep their scalar RAM semantics.
   signal pr2_cpu_ram_cache_enable : std_logic;

   -- build #47: tight-window banked-ROM palette-read classifier (see entity ports)
   signal pal_read_pending       : std_logic := '0';   -- green-row window pending
   signal redrow_read_pending    : std_logic := '0';   -- red-row control window pending
   signal palrd_green_seen       : std_logic := '0';
   signal palrd_red_seen         : std_logic := '0';
   signal palrd_any_seen         : std_logic := '0';
   signal palrd_redrow_red_seen  : std_logic := '0';
   signal palrd_value_latch      : std_logic_vector(31 downto 0) := (others => '0'); -- build #50
   signal palrd_addr_latch       : std_logic_vector(31 downto 0) := (others => '0'); -- build #51
   -- build #52: capture 8 contiguous bank0 words [0x1F644800,0x1F644820) by addr[4:2]
   -- build #52: flat 256-bit pack of 8 words; word N occupies bits [N*32+31 : N*32].
   -- (A named array-of-slv type introduces an implicit "&" that makes other slv
   --  concatenations in this file ambiguous, so keep this flat.)
   signal palrd_w                : std_logic_vector(255 downto 0) := (others => '0');

   -- build #135: cube CLUT source-address sticky-latches
   signal cubeclut_window_seen   : std_logic := '0';
   signal cubeclut_exact_seen    : std_logic := '0';
   signal cubeclut_bank0_seen    : std_logic := '0';

   signal addressData_buf        : unsigned(31 downto 0);
   signal dataWrite_buf          : std_logic_vector(31 downto 0);
   signal reqsize_buf            : unsigned(1 downto 0);   
   signal writeMask_buf          : std_logic_vector(3 downto 0);
            
   signal addressBIOS_buf        : unsigned(18 downto 0);
            
   signal bus_stall              : std_logic;
   signal dataFromBusses         : std_logic_vector(31 downto 0);
   signal rotate32               : std_logic;
   signal rotate16               : std_logic;
         
   -- EXE handling      
   signal loadExe_latched        : std_logic := '0';
   signal exestep                : integer range 0 to 8;
   signal execopycnt             : unsigned(31 downto 0);
   
   -- external busses
   type tExtState is
   (
      EXT_IDLE,
      EXE_WRITE_PREWAIT,
      EXT_WRITE,
      EXT_WRITE_WAIT,
      EXT_READ_NEXT,
      EXT_READ,
      EXT_READ_WAIT
   );
   signal ext_state              : tExtState := EXT_IDLE; 
   
   signal ext_done               : std_logic := '0';
   signal ext_finished           : std_logic := '0';
   signal ext_lastactive         : std_logic := '0';
   signal ext_recovered          : std_logic := '0';
   signal ext_data               : std_logic_vector(31 downto 0);
   signal ext_data_new           : std_logic_vector(31 downto 0);
   signal ext_dataWrite_buf      : std_logic_vector(31 downto 0);
   signal ext_writeMask_buf      : std_logic_vector(3 downto 0);
   
   signal ext_bus_addr           : unsigned(12 downto 0) := (others => '0'); 
   
   signal ext_memctrl            : unsigned(13 downto 0);
   signal ext_memctrl_WDelay     : unsigned(3 downto 0);
   signal ext_memctrl_RDelay     : unsigned(3 downto 0);
   signal ext_memctrl_RecP       : std_logic;
   signal ext_memctrl_Hold       : std_logic;
   signal ext_memctrl_Float      : std_logic;
   signal ext_memctrl_PStrobe    : std_logic;
   signal ext_memctrl_width      : std_logic;
   signal ext_memctrl_autoinc    : std_logic;
   signal ext_byteStep           : unsigned(1 downto 0);
   signal ext_waitcnt            : integer range 0 to 63;
   signal ext_reccount           : integer range 0 to 31;
   signal ext_write_ena          : std_logic;
   signal ext_dataWrite          : std_logic_vector(15 downto 0);
   
   signal ext_select_spu         : std_logic := '0';
   signal ext_select_spu_saved   : std_logic := '0';   
   signal ext_select_cd          : std_logic := '0';
   signal ext_select_cd_saved    : std_logic := '0';
   signal ext_select_ex1         : std_logic := '0';
   signal ext_select_ex1_saved   : std_logic := '0';   
   signal ext_select_ex2         : std_logic := '0';
   signal ext_select_ex2_saved   : std_logic := '0';   
   signal ext_select_ex3         : std_logic := '0';
   signal ext_select_ex3_saved   : std_logic := '0';     
         
   -- debug    
   signal stallcountRead         : integer;
   signal stallcountReadC        : integer;
   signal stallcountWrite        : integer;
   signal stallcountWriteF       : integer;
   signal stallcountIntBus       : integer;
         
   signal addressDataF           : std_logic := '0';

   -- ZN-1 ROM bank register (5-bit, selects 1MB bank window at 0x1FB00000, Visco only)
   signal zn_bank_reg            : std_logic_vector(4 downto 0) := (others => '0');
   -- ZN-1 8MB bank register (3-bit, selects 8MB bank at 0x1F000000, non-Visco platforms, banks 0-6)
   signal zn_bank_8mb            : std_logic_vector(2 downto 0) := (others => '0');

begin
   -- Read-only diagnostic taps.
   boot_debug(7 downto 0) <= std_logic_vector(to_unsigned(tState'pos(state),8));
   boot_debug(15 downto 8) <= std_logic_vector(to_unsigned(tExtState'pos(ext_state),8));
   boot_debug(16) <= ce;
   boot_debug(17) <= reset;
   boot_debug(18) <= readram;
   boot_debug(19) <= writeram;
   boot_debug(20) <= writeFifo_busy;
   boot_debug(21) <= mem_save_request;
   boot_debug(22) <= ram_done;
   boot_debug(23) <= mem_in_request;
   boot_debug(24) <= mem_in_rnw;
   boot_debug(25) <= mem_in_isData;
   boot_debug(26) <= mem_in_isCache;
   boot_debug(27) <= writeFifo_Empty;
   boot_debug(28) <= writeFifo_NearFull;
   boot_debug(29) <= bus_stall;
   boot_debug(30) <= mem_done_buf;
   boot_debug(31) <= pauseNext;
   boot_debug(63 downto 32) <= std_logic_vector(addressData_buf);
   boot_debug(95 downto 64) <= std_logic_vector(mem_in_addressInstr);
   boot_debug(127 downto 96) <= std_logic_vector(mem_in_addressData);
   boot_debug(159 downto 128) <= ram_dataRead;
   boot_debug(191 downto 160) <= mem_in_dataWrite;
   boot_debug(223 downto 192) <= std_logic_vector(mem_save_addressInstr);
   boot_debug(255 downto 224) <= bios_control_shadow;

   pr2_cpu_ram_cache_enable <= '1' when zn_platform = "0101" else '0';

   isIdle <= '1' when (reset = '0' and state = IDLE and readram = '0' and writeram = '0' and writeFifo_busy = '0' and mem_save_request = '0') else '0';

   dbg_zn_bank <= zn_bank_8mb;  -- B-inst5

   process (state, addressData_buf, writeMask_buf, dataWrite_buf, reqsize_buf)
      variable address  : unsigned(28 downto 0);
      variable enableRead  : std_logic;
      variable enableWrite : std_logic;
   begin
   
      address := addressData_buf(28 downto 0);
   
      enableRead  := '0';
      enableWrite := '0';
      if (state = BUSREADREQUEST) then 
         enableRead := '1';
      end if;
      if (state = BUSWRITE) then 
         enableWrite := '1';
      end if;
      
      -- memc
      bus_memc_read      <= '0';
      bus_memc_write     <= '0';
      bus_memc_addr      <= address(5 downto 0);
      bus_memc_dataWrite <= dataWrite_buf;
      if (address >= 16#1F801000# and address < 16#1F801040#) then
         bus_memc_read  <= enableRead;
         bus_memc_write <= enableWrite;
      end if;
      
      -- pad
      bus_pad_read      <= '0';
      bus_pad_write     <= '0';
      bus_pad_addr      <= address(3 downto 0);
      bus_pad_dataWrite <= dataWrite_buf;
      bus_pad_writeMask <= writeMask_buf;
      if (address >= 16#1F801040# and address < 16#1F801050#) then
         bus_pad_read  <= enableRead;
         bus_pad_write <= enableWrite;
      end if;
      
      -- sio
      bus_sio_read      <= '0';
      bus_sio_write     <= '0';
      bus_sio_addr      <= address(3 downto 0);
      bus_sio_dataWrite <= dataWrite_buf;
      bus_sio_writeMask <= writeMask_buf;
      if (address >= 16#1F801050# and address < 16#1F801060#) then
         bus_sio_read  <= enableRead;
         bus_sio_write <= enableWrite;
      end if;
      
      -- memc2
      bus_memc2_read      <= '0';
      bus_memc2_write     <= '0';
      bus_memc2_addr      <= address(3 downto 0);
      bus_memc2_dataWrite <= dataWrite_buf;
      if (address >= 16#1F801060# and address < 16#1F801070#) then
         bus_memc2_read  <= enableRead;
         bus_memc2_write <= enableWrite;
      end if;
      
      -- irq
      bus_irq_read      <= '0';
      bus_irq_write     <= '0';
      bus_irq_addr      <= address(3 downto 0);
      bus_irq_dataWrite <= dataWrite_buf;
      if (address >= 16#1F801070# and address < 16#1F801080#) then
         bus_irq_read  <= enableRead;
         bus_irq_write <= enableWrite;
      end if;
      
      -- dma
      bus_dma_read      <= '0';
      bus_dma_write     <= '0';
      bus_dma_addr      <= address(6 downto 0);
      bus_dma_dataWrite <= dataWrite_buf;
      if (address >= 16#1F801080# and address < 16#1F801100#) then
         bus_dma_read  <= enableRead;
         bus_dma_write <= enableWrite;
      end if;
      
      -- timer
      bus_tmr_read      <= '0';
      bus_tmr_write     <= '0';
      bus_tmr_addr      <= address(5 downto 0);
      bus_tmr_dataWrite <= dataWrite_buf;
      if (address >= 16#1F801100# and address < 16#1F801140#) then
         bus_tmr_read  <= enableRead;
         bus_tmr_write <= enableWrite;
      end if;
      
      -- gpu
      bus_gpu_read      <= '0';
      bus_gpu_write     <= '0';
      bus_gpu_addr      <= address(3 downto 0);
      bus_gpu_dataWrite <= dataWrite_buf;
      if (address >= 16#1F801810# and address < 16#1F801820#) then
         bus_gpu_read  <= enableRead;
         bus_gpu_write <= enableWrite;
      end if;
      
      -- mdec
      bus_mdec_read      <= '0';
      bus_mdec_write     <= '0';
      bus_mdec_addr      <= address(3 downto 0);
      bus_mdec_dataWrite <= dataWrite_buf;
      if (address >= 16#1F801820# and address < 16#1F801830#) then
         bus_mdec_read  <= enableRead;
         bus_mdec_write <= enableWrite;
      end if;

      -- ZN-1 I/O (0x1FA00000-0x1FAFFFFF)
      bus_znio_read      <= '0';
      bus_znio_write     <= '0';
      bus_znio_addr      <= address(20 downto 0);
      bus_znio_dataWrite <= dataWrite_buf;
      bus_znio_writeMask <= writeMask_buf;
      if (address >= 16#1FA00000# and address < 16#1FB00000#) then
         bus_znio_read  <= enableRead;
         bus_znio_write <= enableWrite;
      end if;

      -- PR2-only Atari windows. 0x1f000000 is write-only watchdog glue and
      -- overlays the read-only program ROM at the same address.
      bus_pr2_read      <= '0';
      bus_pr2_write     <= '0';
      bus_pr2_addr      <= address;
      bus_pr2_dataWrite <= dataWrite_buf;
      bus_pr2_writeMask <= writeMask_buf;
      bus_pr2_reqsize   <= reqsize_buf;
      if ((address >= 16#1F7E4000# and address < 16#1F7E5000#) or
          (address >= 16#1F7E8000# and address < 16#1F7E8004#) or
          (address >= 16#1F7F4000# and address < 16#1F7F5000#)) then
         bus_pr2_read  <= enableRead;
         bus_pr2_write <= enableWrite;
      elsif (address >= 16#1F000000# and address < 16#1F000004#) then
         bus_pr2_write <= enableWrite;
      end if;

   end process;
   
   bus_stall         <= bus_gpu_stall;
   
   dataFromBusses    <= bus_memc_dataRead or bus_pad_dataRead or bus_sio_dataRead or bus_memc2_dataRead or bus_irq_dataRead or
                        bus_dma_dataRead or bus_tmr_dataRead or bus_gpu_dataRead or bus_mdec_dataRead or bus_znio_dataRead or
                        bus_pr2_dataRead;
   
   rom_buf_word <= rom_buf_w0 when mem_addressData(3 downto 2) = "00" else
                   rom_buf_w1 when mem_addressData(3 downto 2) = "01" else
                   rom_buf_w2 when mem_addressData(3 downto 2) = "10" else rom_buf_w3;
   rom_buf_saved_word <= rom_buf_w0 when mem_save_addressData(3 downto 2) = "00" else
                         rom_buf_w1 when mem_save_addressData(3 downto 2) = "01" else
                         rom_buf_w2 when mem_save_addressData(3 downto 2) = "10" else rom_buf_w3;

   data_ram          <= ram_dataRead;
  
   data_ram_rotate   <= data_ram                            when ram_rotate_bits(1 downto 0) = "00" else
                        x"00" & data_ram(31 downto 8)       when ram_rotate_bits(1 downto 0) = "01" else
                        x"0000" & data_ram(31 downto 16)    when ram_rotate_bits(1 downto 0) = "10" else
                        x"000000" & data_ram(31 downto 24);

   -- build #47: expose latched palette-read classification to the debug bars
   dbg_palrd_green      <= palrd_green_seen;
   dbg_palrd_red        <= palrd_red_seen;
   dbg_palrd_any        <= palrd_any_seen;
   dbg_palrd_redrow_red <= palrd_redrow_red_seen;
   dbg_palrd_value      <= palrd_value_latch;   -- build #50
   dbg_palrd_addr       <= palrd_addr_latch;    -- build #51
   -- build #52: pack 8 words (word0 in low 32 bits .. word7 in high 32 bits)
   dbg_palrd_words      <= palrd_w;

   -- build #135: cube CLUT source-address sticky outputs
   dbg_cubeclut_window_seen <= cubeclut_window_seen;
   dbg_cubeclut_exact_seen  <= cubeclut_exact_seen;
   dbg_cubeclut_bank0_seen  <= cubeclut_bank0_seen;

   -- B-meas2: I/O-POLL region classification. B-meas showed RAM/ROM/write reads
   -- are ~0 during the post-coin load, yet cpu_mem_inflight is ~60% -> the load
   -- is I/O-poll bound. Bucket the in-flight I/O/external read (BUSREADREQUEST =
   -- PSX hw regs DMA/GPU/timer/IRQ + ZN-IO; BUSREADEXTERNAL = CD/SPU/EXP) by
   -- target, using the latched data address addressData_buf:
   --   RED   = DMA registers  0x1F801080-0x1F8010FF  (DMA-completion polling)
   --   GREEN = GPU registers   0x1F801810-0x1F801817  (GPUSTAT polling)
   --   BLUE  = all other I/O   (timer/IRQ/ZN-IO/CD/SPU/EXP: delay loops, input)
   -- B-meas6: the 55s logo is a BLOCKING BIOS routine (frame loop suspended,
   -- vblank 60Hz). It spends ~12% of cycles polling internal I/O. Split that
   -- poll by target register to name what the routine spins on:
   -- B-meas9: pinpoint within 0x1FA20000-0x1FBFFFFF. The fix for 0x1FA60000
   -- didn't help, so test which is actually read:
   --   RED   = coin         0x1FA20000-0x1FA2FFFF
   --   GREEN = spu_hack rgn  0x1FA60000-0x1FA6FFFF  (the fix target — is it read?)
   --   BLUE  = everything else in 0x1FA20000-0x1FBFFFFF (bank 0x1FB00000+, etc.)
   dbg_busy_rom   <= '1' when (state = BUSREADREQUEST
                               and addressData_buf(28 downto 0) >= 16#1FA20000#
                               and addressData_buf(28 downto 0) <= 16#1FA2FFFF#) else '0';
   dbg_busy_ramrd <= '1' when (state = BUSREADREQUEST
                               and addressData_buf(28 downto 0) >= 16#1FA60000#
                               and addressData_buf(28 downto 0) <= 16#1FA6FFFF#) else '0';
   dbg_busy_ramwr <= '1' when (state = BUSREADREQUEST
                               and addressData_buf(28 downto 0) >= 16#1FA20000#
                               and addressData_buf(28 downto 0) <= 16#1FBFFFFF#
                               and not (addressData_buf(28 downto 0) >= 16#1FA20000#
                                        and addressData_buf(28 downto 0) <= 16#1FA2FFFF#)
                               and not (addressData_buf(28 downto 0) >= 16#1FA60000#
                                        and addressData_buf(28 downto 0) <= 16#1FA6FFFF#)) else '0';

   -- B-meas10: latch the offset of ZN-IO reads in 0x1FA20000-0x1FBFFFFF (the
   -- logo poll). During the 55s logo this settles on the polled register.
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (state = BUSREADREQUEST
             and addressData_buf(28 downto 0) >= 16#1FA20000#
             and addressData_buf(28 downto 0) <= 16#1FBFFFFF#) then
            dbg_znio_addr <= std_logic_vector(addressData_buf(20 downto 0));
         end if;
      end if;
   end process;

   mem_dataRead      <= data_ram_rotate when (readram = '1' and ram_done = '1') else
                        ext_data_new    when (ext_done = '1') else
                        mem_dataRead_buf;
                        
    mem_done          <= '1'            when (reset = '0' and readram = '1'  and ram_done = '1') else
                         '1'            when (reset = '0' and ext_done = '1') else
                         '0'            when (reset = '1') else
                         mem_done_buf;
   
   
   -- write fifo
   iwritefifo: entity mem.SyncFifoFallThroughMLAB
   generic map
   (
      SIZE              => 8,
      DATAWIDTH         => 70,
      NEARFULLDISTANCE  => 4,
      NEAREMPTYDISTANCE => 2
   )
   port map
   ( 
      clk         => clk1x,
      reset       => reset,
                  
      Din         => writeFifo_Din,     
      Wr          => writeFifo_Wr,      
      Full        => open,                -- NearFull will stall cpu to have full 4 element size
      NearFull    => writeFifo_NearFull,
            
      Dout        => writeFifo_Dout,     
      Rd          => writeFifo_Rd,   
      Empty       => writeFifo_Empty,
      NearEmpty   => open
   );
   
   writeFifo_Din <= mem_in_writeMask & std_logic_vector(mem_in_reqsize) & std_logic_vector(mem_in_addressData) & mem_in_dataWrite;
   writeFifo_Wr  <= '1' when (reset = '0' and ce = '1' and mem_in_request = '1' and mem_in_rnw = '0' and (pauseNext = '1' or state /= IDLE or writeFifo_busy = '1' or ((readram = '1' or writeram = '1') and ram_done = '0'))) else '0';
   
   writeFifo_Rd  <= '1' when (reset = '0' and ce = '1' and pauseNext = '0' and state = IDLE and writeFifo_Empty = '0' and ((readram = '0' and writeram = '0') or ram_done = '1')) else '0';
   
   mem_fifofull  <= writeFifo_NearFull;
   
   -- input muxing with buffer and writefifo
   mem_request      <= mem_in_request or mem_save_request;
   mem_rnw          <= '0'                                    when writeFifo_Empty = '0' else mem_save_rnw          when mem_save_request = '1' else mem_in_rnw         ;
   mem_isData       <= '1'                                    when writeFifo_Empty = '0' else mem_save_isData       when mem_save_request = '1' else mem_in_isData      ;
   mem_isCache      <= '0'                                    when writeFifo_Empty = '0' else mem_save_isCache      when mem_save_request = '1' else mem_in_isCache     ;
   mem_oldtagvalids <= "0000"                                 when writeFifo_Empty = '0' else mem_save_oldtagvalids when mem_save_request = '1' else mem_in_oldtagvalids; 
   mem_addressInstr <= unsigned(writeFifo_Dout(63 downto 32)) when writeFifo_Empty = '0' else mem_save_addressInstr when mem_save_request = '1' else mem_in_addressInstr;
   mem_addressData  <= unsigned(writeFifo_Dout(63 downto 32)) when writeFifo_Empty = '0' else mem_save_addressData  when mem_save_request = '1' else mem_in_addressData ;
   mem_reqsize      <= unsigned(writeFifo_Dout(65 downto 64)) when writeFifo_Empty = '0' else mem_save_reqsize      when mem_save_request = '1' else mem_in_reqsize     ;
   mem_writeMask    <= writeFifo_Dout(69 downto 66)           when writeFifo_Empty = '0' else mem_save_writeMask    when mem_save_request = '1' else mem_in_writeMask   ;
   mem_dataWrite    <= writeFifo_Dout(31 downto  0)           when writeFifo_Empty = '0' else mem_save_dataWrite    when mem_save_request = '1' else mem_in_dataWrite   ;
  
   process (clk1x)
      variable biosPatch       : std_logic_vector(31 downto 0);
      variable cache_write_next : std_logic_vector(31 downto 0);
      variable bios_control_next : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk1x) then
      
         ram_ena              <= '0';
         ram_rom_prefetch     <= '0';
         mem_done_buf         <= '0';
         reset_exe            <= '0';
         fram_wren            <= '0';   -- Taito FRAM write is a 1-cycle pulse from IDLE

         if (loadExe = '1') then
            loadExe_latched <= '1';
         end if;
         
         if (ram_done = '1') then
            -- Capture completed CPU data reads as a forwarding entry.  The
            -- pending address is latched when the request is accepted, so
            -- delayed WAITFORRAMREAD requests cannot be attributed to a
            -- later CPU address.
            if (readram = '1' and cpu_ram_pending_valid = '1') then
               cpu_ram_cache_valid <= '1';
               cpu_ram_cache_addr  <= cpu_ram_pending_addr;
               cpu_ram_cache_data  <= ram_dataRead;
            end if;
            cpu_ram_pending_valid <= '0';
            readram  <= '0';
            writeram <= '0';
         end if;
      
         if (ram_load_last > 0) then
            ram_load_last <= ram_load_last - 1;
         end if;
      
         if (reset = '1') then

            state            <= IDLE;
            -- Reset abandons the CPU transaction, including its outstanding
            -- SDRAM token. At power-up SDRAM init may discard a request before
            -- it can acknowledge it. Retaining that token across reset blocks
            -- the reset-vector fetch and prevents the pause handshake forever.
            readram          <= '0';
            writeram         <= '0';
            region           <= region_in;
            mem_save_request <= '0';
            writeFifo_busy   <= '0';
            ram_page_open    <= '0';
            ext_lastactive   <= '0';
            bios_control_shadow <= (others => '0');
            zn_bank_reg      <= (others => '0');
            zn_bank_8mb      <= (others => '0');
            cpu_ram_cache_valid   <= '0';
            cpu_ram_cache_addr    <= (others => '0');
            cpu_ram_cache_data    <= (others => '0');
            cpu_ram_pending_valid <= '0';
            cpu_ram_pending_addr  <= (others => '0');
            ee_read_wait     <= '0';
            rom_buf_valid    <= '0';
            rom_buf_word_valid <= (others => '0');
            pf_remaining     <= 0;
            pf_first_returned <= '0';
            rom_speculative_burst <= '0';
            pal_read_pending      <= '0';   -- build #47
            redrow_read_pending   <= '0';   -- build #47
            palrd_green_seen      <= '0';   -- build #47
            palrd_red_seen        <= '0';   -- build #47
            palrd_any_seen        <= '0';   -- build #47
            palrd_redrow_red_seen <= '0';   -- build #47
            palrd_value_latch     <= (others => '0');  -- build #50
            palrd_addr_latch      <= (others => '0');  -- build #51
            palrd_w               <= (others => '0');  -- build #52
            cubeclut_window_seen  <= '0';   -- build #135
            cubeclut_exact_seen   <= '0';   -- build #135
            cubeclut_bank0_seen   <= '0';   -- build #135

          elsif (ce = '1') then

             -- DMA owns the external RAM pins while pauseNext is asserted.
             -- A DMA write can replace any CPU word, so discard the forwarding
             -- entry across the pause and fetch the word again after ownership
             -- returns.  This costs at most one miss after DMA and prevents a
             -- stale BIOS/game-data read from surviving a DMA transfer.
             if (pauseNext = '1') then
                cpu_ram_cache_valid <= '0';
             end if;

             if (mem_in_request = '1' and mem_in_rnw = '1') then
               mem_save_request      <= '1';
               mem_save_rnw          <= '1';         
               mem_save_isData       <= mem_in_isData;
               mem_save_isCache      <= mem_in_isCache;     
               mem_save_oldtagvalids <= mem_in_oldtagvalids;     
               mem_save_addressInstr <= mem_in_addressInstr;
               mem_save_addressData  <= mem_in_addressData; 
               mem_save_reqsize      <= mem_in_reqsize;     
               mem_save_writeMask    <= mem_in_writeMask;   
               mem_save_dataWrite    <= mem_in_dataWrite;   
            end if;
            
            writeFifo_Wr_1 <= writeFifo_Wr;
            if (writeFifo_Wr = '1') then
               writeFifo_busy <= '1';
            elsif (writeFifo_Wr_1 = '0' and writeFifo_Empty = '1') then
               writeFifo_busy <= '0';
            end if;
          
            -- A speculative next-line fill runs while the CPU consumes the
            -- current line.  Its completion is independent of the FSM state;
            -- publish it before normal IDLE arbitration so a same-cycle CPU
            -- miss cannot launch a duplicate burst.
            if (rom_speculative_burst = '1' and rom_burst_done = '1') then
               -- A speculative fill leaves the current line in the buffer
               -- until this edge.  That lets byte/halfword reads which stay
               -- in the old line complete while the next line is in flight.
               -- The saved request is evaluated against the old tag before
               -- the replacement assignments below take effect.
               if (mem_save_request = '1' and mem_save_rnw = '1' and
                   mem_save_isData = '1' and ROM_PREFETCH = '1' and
                   mem_save_addressData(28 downto 0) >= 16#1F000000# and
                   mem_save_addressData(28 downto 0) < 16#1F200000# and
                   rom_buf_valid = '1' and
                   rom_buf_tag = std_logic_vector(mem_save_addressData(22 downto 4)) and
                   rom_buf_word_valid(to_integer(unsigned(mem_save_addressData(3 downto 2)))) = '1') then
                  mem_save_request <= '0';
                  mem_dataRead_buf <= std_logic_vector(shift_right(unsigned(rom_buf_saved_word),
                                           to_integer(mem_save_addressData(1 downto 0)) * 8));
                  mem_done_buf <= '1';
               end if;
               rom_buf_w0          <= rom_burst_data(31 downto 0);
               rom_buf_w1          <= rom_burst_data(63 downto 32);
               rom_buf_w2          <= rom_burst_data(95 downto 64);
               rom_buf_w3          <= rom_burst_data(127 downto 96);
               rom_buf_word_valid  <= "1111";
               rom_buf_valid       <= '1';
               rom_buf_tag         <= pf_tag_snap;
               pf_remaining        <= 0;
               rom_speculative_burst <= '0';
               pf_first_returned   <= '0';
               state               <= IDLE;
            else
            case (state) is
               when IDLE =>

                  addressData_buf <= mem_addressData;
                  dataWrite_buf   <= mem_dataWrite;
                  reqsize_buf     <= mem_reqsize;
                  writeMask_buf   <= mem_writeMask;
                  
                  if (loadExe_latched = '1') then
                     
                     state      <= EXEPATCHBIOSWRITE;
                     exestep    <= 0;
                     execopycnt <= (others => '0');

                  -- A recently completed CPU RAM word can satisfy a
                  -- same-word load without another SDRAM transaction.  This
                  -- is deliberately below EXE handling and above the ROM and
                  -- bus paths: it only applies to ordinary data reads in the
                  -- first 8 MiB RAM window and never bypasses a queued store
                  -- or an outstanding RAM write.
                   elsif (pr2_cpu_ram_cache_enable = '1' and pauseNext = '0' and mem_request = '1' and
                          writeFifo_busy = '0' and writeFifo_Empty = '1' and
                         ((readram = '0' and writeram = '0') or ram_done = '1') and
                         mem_isData = '1' and mem_rnw = '1' and
                         mem_addressData(28 downto 0) < 16#800000# and
                         cpu_ram_cache_valid = '1' and
                         cpu_ram_cache_addr = std_logic_vector(mem_addressData(22 downto 2))) then
                     mem_save_request <= '0';
                     case (mem_addressData(1 downto 0)) is
                        when "00"   => mem_dataRead_buf <= cpu_ram_cache_data;
                        when "01"   => mem_dataRead_buf <= x"00"       & cpu_ram_cache_data(31 downto  8);
                        when "10"   => mem_dataRead_buf <= x"0000"     & cpu_ram_cache_data(31 downto 16);
                        when others => mem_dataRead_buf <= x"000000"   & cpu_ram_cache_data(31 downto 24);
                      end case;
                      mem_done_buf <= '1';

                   -- A complete immutable ROM line can also serve CPU data
                  -- while an older RAM store drains. Keep that store's pins
                  -- and tracking intact; queued writes and reads still order.
                  elsif (pauseNext = '0' and mem_request = '1' and
                         writeFifo_busy = '0' and writeFifo_Empty = '1' and
                         (readram = '0' or ram_done = '1') and
                         mem_isData = '1' and mem_rnw = '1' and
                         ROM_PREFETCH = '1' and rom_buf_valid = '1' and
                         mem_addressData(28 downto 0) >= 16#1F000000# and
                         mem_addressData(28 downto 0) < 16#1F200000# and
                         rom_buf_tag = std_logic_vector(mem_addressData(22 downto 4))) then
                     mem_save_request <= '0';
                     mem_dataRead_buf <= std_logic_vector(shift_right(unsigned(rom_buf_word),
                                             to_integer(mem_addressData(1 downto 0)) * 8));
                     mem_done_buf <= '1';

                     -- The ROM copy loop consumes each immutable line in
                     -- order.  As soon as slot 3 is returned, start filling
                     -- the next line so its request is ready before the CPU
                     -- reaches it.  Keep the current word response driven
                     -- from the old buffer; all assignments here take effect
                     -- after this clock edge.
                     if (rom_burst_enable = '1' and
                         -- The BIOS probes the low ROM header with mixed
                         -- byte/halfword accesses and revisits old lines.
                         -- Restrict overlap prefetch to the game image's
                         -- upper region, where the copy stream is linear.
                         mem_addressData(28 downto 0) >= 16#1F100000# and
                         mem_addressData(3 downto 2) = "11" and
                         unsigned(pf_line_addr_base) < to_unsigned(16#0A7FFF0#, 27)) then
                        ram_ena                 <= '1';
                        ram_cache               <= '1';
                        ram_rom_prefetch        <= '1';
                        ram_rnw                 <= '1';
                        ram_Adr                 <= std_logic_vector(unsigned(pf_line_addr_base) + to_unsigned(16, 27));
                        ram_rotate_bits         <= "00";
                        -- Keep the current line valid while this burst is in
                        -- flight; ROM_PF_BURST_WAIT services any repeated
                        -- reads from it before publishing the next line.
                        pf_line_addr_base        <= std_logic_vector(unsigned(pf_line_addr_base) + to_unsigned(16, 27));
                        pf_tag_snap              <= std_logic_vector(unsigned(rom_buf_tag) + 1);
                        pf_first_slot             <= "00";
                        pf_first_rotate_bits     <= "00";
                        pf_first_returned        <= '0';
                        rom_speculative_burst    <= '1';
                        state                    <= ROM_PF_BURST_WAIT;
                     end if;

                  -- A completed immutable program-ROM line needs no SDRAM
                  -- transaction.  A following CPU load is saved while an
                  -- older RAM store waits in the write FIFO, so normal input
                  -- mux priority hides that load behind the store.  Return
                  -- this safe, independent hit while the FIFO drains.  The
                  -- bypass is deliberately restricted to an ordinary RAM
                  -- store and preserves an outstanding RAM-read guard; I/O
                  -- writes and RAM-read ordering remain serialized.
                  elsif (pauseNext = '0' and mem_save_request = '1' and
                         mem_save_isData = '1' and mem_save_rnw = '1' and
                         ROM_PREFETCH = '1' and writeFifo_Empty = '0' and
                         -- A FIFO pop must execute the normal store branch.
                         -- Never consume a store solely to return a ROM hit.
                         writeFifo_Rd = '0' and
                         unsigned(writeFifo_Dout(60 downto 32)) < 16#800000# and
                         (readram = '0' or ram_done = '1') and
                         mem_save_addressData(28 downto 0) >= 16#1F000000# and
                         mem_save_addressData(28 downto 0) < 16#1F200000# and
                         rom_buf_word_valid(to_integer(unsigned(mem_save_addressData(3 downto 2)))) = '1' and
                         rom_buf_tag = std_logic_vector(mem_save_addressData(22 downto 4))) then
                     mem_save_request <= '0';
                     mem_dataRead_buf <= std_logic_vector(shift_right(unsigned(rom_buf_saved_word),
                                             to_integer(mem_save_addressData(1 downto 0)) * 8));
                     mem_done_buf <= '1';

                  elsif (pauseNext = '0' and ((readram = '0' and writeram = '0') or ram_done = '1') and ((mem_request = '1' and writeFifo_busy = '0') or writeFifo_Empty = '0')) then
                  
                     if (mem_request = '1' and writeFifo_busy = '0') then
                        mem_save_request <= '0';
                     end if;
                  
                     readram  <= '0';
                     writeram <= '0';
                     
                     ram_page_open  <= '0';
                     bios_page_open <= '0';
                  
                     if (mem_isData = '0') then
               
                        if (mem_addressInstr(28 downto 0) < 16#800000#) then -- RAM
                           ram_ena     <= '1';
                           ram_cache   <= mem_isCache;
                           ram_rnw     <= '1';
                           ram_Adr     <= "0000" & std_logic_vector(mem_addressInstr(22 downto 2)) & "00";
                           state       <= IDLE;
                           readram     <= '1';
                           ram_rotate_bits <= "00";
                           if (mem_isCache = '0') then
                              if (TURBO = '0') then
                                 state   <= WAITFORRAMREAD;
                                 waitcnt <= 0;
                                 ram_ena <= '0';
                                 readram <= '0';
                              end if;
                           end if;
                           
                           case (mem_addressInstr(3 downto 2)) is
                              when "00" => mem_tagvalids <= "1111";
                              when "01" => mem_tagvalids <= "1110";
                              when "10" => mem_tagvalids <= "1100";
                              when "11" => mem_tagvalids <= "1000";
                              when others => null;
                           end case;
                           
                        elsif (mem_addressInstr(28 downto 0) >= 16#1FC00000# and mem_addressInstr(28 downto 0) < 16#1FC80000#) then -- BIOS
                           ram_ena         <= '1';
                           ram_cache       <= '0';
                           ram_rnw         <= '1';
                           ram_Adr         <= "00010000" & std_logic_vector(mem_addressInstr(18 downto 2)) & "00";
                           state           <= READBIOS;
                           addressBIOS_buf <= mem_addressInstr(18 downto 0);
                           ram_rotate_bits <= "00";
                           -- FAST_BIOS: skip the original-PSX ROM-chip pacing for ZN-1 SDRAM
                            if (FAST_BIOS = '1' or BIOS_SDRAM_PACING = '1') then
                               waitcnt        <= 0;
                               bios_page_open <= '1';
                            else
                               -- Keep first/sequential fetches on one arithmetic
                               -- datapath; only the final extra clock differs.
                               waitcnt        <= bios_instruction_wait(bios_memctrl, com0_delay, com2_delay, com3_delay, bios_page_open /= '1');
                               -- An earlier control-write invalidation in this
                               -- clock must still win for an already-open page.
                               if (bios_page_open /= '1') then
                                  bios_page_open <= '1';
                               end if;
                            end if;
                           
                           mem_tagvalids <= mem_oldtagvalids;
                           case (mem_addressInstr(3 downto 2)) is
                              when "00" => mem_tagvalids(0) <= '1';
                              when "01" => mem_tagvalids(1) <= '1';
                              when "10" => mem_tagvalids(2) <= '1';
                              when "11" => mem_tagvalids(3) <= '1';
                              when others => null;
                           end case;
                        elsif (mem_addressInstr(28 downto 0) >= 16#1F000000# and
                               mem_addressInstr(28 downto 0) < 16#1F200000#) then -- PR2 fixed 2 MiB ROM
                           ram_ena         <= '1';
                           -- Cached instruction tags require real cache data.
                           -- Single-word reads return to the CPU but never
                           -- generate the controller's cache-write strobes.
                           ram_cache       <= mem_isCache;
                           ram_rnw         <= '1';
                           ram_Adr         <= std_logic_vector(to_unsigned(16#0880000#, 27) +
                                                resize(mem_addressInstr(20 downto 2) & "00", 27));
                           state           <= READROM;
                           ram_rotate_bits <= "00";
                           mem_tagvalids   <= mem_oldtagvalids;
                           case (mem_addressInstr(3 downto 2)) is
                              when "00" => mem_tagvalids(0) <= '1';
                              when "01" => mem_tagvalids(1) <= '1';
                              when "10" => mem_tagvalids(2) <= '1';
                              when "11" => mem_tagvalids(3) <= '1';
                              when others => null;
                           end case;
                         else
                            -- Unmapped instruction fetches use the platform open-bus
                            -- value.  Keep the transaction bounded so a diagnostic
                            -- or future service vector cannot abort the whole run.
                            mem_dataRead_buf <= x"FFFFFFFF";
                            mem_done_buf     <= '1';
                            state            <= IDLE;
                        end if;
            
                     else
                     
                        if (mem_addressData(28 downto 0) < 16#800000#) then -- RAM
                           ext_lastactive  <= '0';
                           ram_cache       <= '0';
                           ram_rnw         <= mem_rnw;
                           ram_Adr         <= "0000" & std_logic_vector(mem_addressData(22 downto 2)) & "00";
                           ram_rotate_bits <= std_logic_vector(mem_addressData(1 downto 0));
                           if (mem_rnw = '1') then
                              cpu_ram_pending_addr  <= std_logic_vector(mem_addressData(22 downto 2));
                              cpu_ram_pending_valid <= '1';
                              ram_load_last <= 7;
                              if (TURBO = '1' or ram_load_last > 0) then
                                 state   <= IDLE;
                                 ram_ena <= '1';
                                 readram <= '1';
                              else
                                 state   <= WAITFORRAMREAD;
                                 waitcnt <= 0;
                              end if;
                           else
                              -- Keep the forwarding entry coherent with CPU
                              -- stores. Full-word stores install a new entry;
                              -- masked stores merge into an entry for the
                              -- same word and leave an unrelated entry alone.
                              if (pr2_cpu_ram_cache_enable = '1' and cpu_ram_cache_valid = '1' and
                                  cpu_ram_cache_addr = std_logic_vector(mem_addressData(22 downto 2))) then
                                 cache_write_next := cpu_ram_cache_data;
                                 if (mem_writeMask(0) = '1') then
                                    cache_write_next(7 downto 0) := mem_dataWrite(7 downto 0);
                                 end if;
                                 if (mem_writeMask(1) = '1') then
                                    cache_write_next(15 downto 8) := mem_dataWrite(15 downto 8);
                                 end if;
                                 if (mem_writeMask(2) = '1') then
                                    cache_write_next(23 downto 16) := mem_dataWrite(23 downto 16);
                                 end if;
                                 if (mem_writeMask(3) = '1') then
                                    cache_write_next(31 downto 24) := mem_dataWrite(31 downto 24);
                                 end if;
                                 cpu_ram_cache_data <= cache_write_next;
                              elsif (pr2_cpu_ram_cache_enable = '1' and mem_writeMask = "1111") then
                                 cpu_ram_cache_valid <= '1';
                                 cpu_ram_cache_addr  <= std_logic_vector(mem_addressData(22 downto 2));
                                 cpu_ram_cache_data  <= mem_dataWrite;
                              end if;
                              ram_page_open <= '1';
                              ram_page_addr <= mem_addressData(20 downto 10);
                              if (TURBO = '1' or (ram_page_open = '1' and mem_addressData(20 downto 10) = ram_page_addr)) then
                                 state    <= IDLE;
                                 ram_ena  <= '1';
                                 writeram <= '1';
                              else
                                 state   <= WAITFORRAMWRITE;
                                 waitcnt <= 0;
                                 if (ram_page_open = '1' and mem_addressData(20 downto 10) /= ram_page_addr) then
                                    waitcnt <= 3;
                                 end if;
                              end if;
                           end if;
                           ram_be        <= mem_writeMask;
                           ram_dataWrite <= mem_dataWrite;
                        elsif (mem_addressData(28 downto 0) = 16#1FC0BF08#) then
                           -- The BIOS status/control word is the only local
                           -- shadow in this otherwise SDRAM-backed window.
                           -- Keep writes on the existing BUSWRITE timing while
                           -- applying the CPU byte-lane mask exactly.
                           if (mem_rnw = '1') then
                              mem_dataRead_buf <= bios_control_shadow;
                              mem_done_buf     <= '1';
                              state            <= IDLE;
                           else
                              bios_control_next := bios_control_shadow;
                              if (mem_writeMask(0) = '1') then
                                 bios_control_next(7 downto 0) := mem_dataWrite(7 downto 0);
                              end if;
                              if (mem_writeMask(1) = '1') then
                                 bios_control_next(15 downto 8) := mem_dataWrite(15 downto 8);
                              end if;
                              if (mem_writeMask(2) = '1') then
                                 bios_control_next(23 downto 16) := mem_dataWrite(23 downto 16);
                              end if;
                              if (mem_writeMask(3) = '1') then
                                 bios_control_next(31 downto 24) := mem_dataWrite(31 downto 24);
                              end if;
                              bios_control_shadow <= bios_control_next;
                              state <= BUSWRITE;
                           end if;
                        elsif (mem_rnw = '1' and mem_addressData(28 downto 0) >= 16#1FC00000# and mem_addressData(28 downto 0) < 16#1FC80000#) then -- BIOS
                           ram_ena         <= '1';
                           ram_cache       <= '0';
                           ram_rnw         <= '1';
                           ram_Adr         <= "00010000" & std_logic_vector(mem_addressData(18 downto 2)) & "00";
                           ram_rotate_bits <= std_logic_vector(mem_addressData(1 downto 0));
                           state           <= READBIOS;
                           addressBIOS_buf <= mem_addressData(18 downto 0);
                           -- FAST_BIOS: zero pacing for ZN-1's SDRAM-resident BIOS
                           if (FAST_BIOS = '1' or BIOS_SDRAM_PACING = '1') then
                              waitcnt <= 0;
                           else
                              case (mem_reqsize) is
                                 when "00" => waitcnt <= 1;
                                 when "01" => waitcnt <= 9;
                                 when "10" => waitcnt <= 25;
                                 when others => null;
                              end case;
                           end if;
                        else
                           ext_select_spu <= '0';
                           ext_select_cd  <= '0';
                           ext_select_ex1 <= '0';
                           ext_select_ex2 <= '0';
                           ext_select_ex3 <= '0';
                           if (mem_rnw = '1' and mem_addressData(28 downto 0) >= 16#1F000000# and
                               mem_addressData(28 downto 0) < 16#1F200000#) then
                              -- PR2 has one fixed 2 MiB program region; no bank register exists.
                              ext_lastactive  <= '0';
                              if (ROM_PREFETCH = '1' and
                                  rom_buf_word_valid(to_integer(unsigned(mem_addressData(3 downto 2)))) = '1' and
                                  rom_buf_tag = std_logic_vector(mem_addressData(22 downto 4))) then
                                 mem_dataRead_buf <= std_logic_vector(shift_right(unsigned(rom_buf_word),
                                                       to_integer(mem_addressData(1 downto 0)) * 8));
                                 mem_done_buf <= '1';
                              else
                                 ram_ena         <= '1';
                                 ram_rnw         <= '1';
                                 pf_remaining    <= 0;
                                 if (ROM_PREFETCH = '1' and rom_burst_enable = '1') then
                                    -- Align the physical SDRAM request to the
                                    -- start of the 16-byte line.  The
                                    -- clk3x cache stream is collected by
                                    -- psx_top and returned as rom_burst_data.
                                    ram_cache       <= '1';
                                    ram_rom_prefetch <= '1';
                                    ram_Adr         <= std_logic_vector(to_unsigned(16#0880000#, 27) +
                                                         resize(mem_addressData(20 downto 4) & "0000", 27));
                                    ram_rotate_bits       <= "00";
                                    pf_first_rotate_bits  <= std_logic_vector(mem_addressData(1 downto 0));
                                    state                  <= ROM_PF_BURST_WAIT;
                                    rom_buf_valid          <= '0';
                                    rom_buf_word_valid     <= (others => '0');
                                    rom_buf_tag             <= std_logic_vector(mem_addressData(22 downto 4));
                                    pf_line_addr_base       <= std_logic_vector(to_unsigned(16#0880000#, 27) +
                                                               resize(mem_addressData(20 downto 4) & "0000", 27));
                                    pf_tag_snap              <= std_logic_vector(mem_addressData(22 downto 4));
                                    pf_first_slot            <= std_logic_vector(mem_addressData(3 downto 2));
                                    pf_first_returned        <= '0';
                                    rom_speculative_burst    <= '0';
                                 else
                                    -- Preserve the original scalar request
                                    -- when prefetch is disabled or the burst
                                    -- collector is unavailable.
                                    ram_cache       <= '0';
                                    ram_Adr         <= std_logic_vector(to_unsigned(16#0880000#, 27) +
                                                         resize(mem_addressData(20 downto 2) & "00", 27));
                                    ram_rotate_bits <= std_logic_vector(mem_addressData(1 downto 0));
                                    state            <= READROM;
                                 end if;
                                 if (ROM_PREFETCH = '1' and rom_burst_enable = '0') then
                                     rom_buf_valid <= '0';
                                     rom_buf_word_valid <= (others => '0');
                                     rom_buf_tag <= std_logic_vector(mem_addressData(22 downto 4));
                                     pf_remaining <= 3;
                                    pf_line_addr_base <= std_logic_vector(to_unsigned(16#0880000#, 27) +
                                                          resize(mem_addressData(20 downto 4) & "0000",27));
                                    pf_tag_snap <= std_logic_vector(mem_addressData(22 downto 4));
                                    pf_first_slot <= std_logic_vector(mem_addressData(3 downto 2));
                                    if (mem_addressData(3 downto 2) = "00") then pf_curr_slot <= "01";
                                    else pf_curr_slot <= "00"; end if;
                                 end if;
                              end if;
                           elsif ((mem_addressData(28 downto 0) >= 16#1F7E4000# and mem_addressData(28 downto 0) < 16#1F7E5000#) or
                                  (mem_addressData(28 downto 0) >= 16#1F7E8000# and mem_addressData(28 downto 0) < 16#1F7E8004#) or
                                  (mem_addressData(28 downto 0) >= 16#1F7F4000# and mem_addressData(28 downto 0) < 16#1F7F5000#) or
                                  (mem_rnw = '0' and mem_addressData(28 downto 0) >= 16#1F000000# and mem_addressData(28 downto 0) < 16#1F000004#)) then
                              ext_lastactive <= '0';
                              if (mem_rnw = '0') then
                                 state <= BUSWRITE;
                              else
                                 state   <= BUSREADREQUEST;
                                 waitcnt <= 0;
                              end if;
                           elsif (mem_addressData(28 downto 0) >= 16#1FA00000# and mem_addressData(28 downto 0) < 16#1FB00000#) then
                              -- ZN-1 I/O: routed through internal bus (bus_znio_*)
                              ext_lastactive  <= '0';
                              if (mem_rnw = '0') then
                                 state   <= BUSWRITE;
                              else
                                 state   <= BUSREADREQUEST;
                                 waitcnt <= 0;
                                 -- EEPROM read (0x1FAF0000-0x1FAFFFFF): +1 cycle for the altsyncram
                                 if (mem_addressData(28 downto 0) >= 16#1FAF0000# and mem_addressData(28 downto 0) < 16#1FB00000#) then
                                    ee_read_wait <= '1';
                                 else
                                    ee_read_wait <= '0';
                                 end if;
                              end if;
                           elsif (mem_addressData(28 downto 0) >= 16#1F801800# and mem_addressData(28 downto 0) < 16#1F801810#) then
                              -- ZN-1 has no CD-ROM: return 0xFF for reads (matches MAME open-bus), ignore writes
                              if (mem_rnw = '1') then
                                 state <= BUSREAD_CDSTUB;
                              else
                                 state <= BUSWRITE;
                              end if;
                           elsif (mem_addressData(28 downto 0) >= 16#1F801C00# and mem_addressData(28 downto 0) < 16#1F802000#) then
                              ext_select_spu <= '1';
                              if (mem_rnw = '1') then
                                 state    <= BUSREADEXTERNAL;
                              else
                                 state    <= BUSWRITEEXTERNAL;
                              end if;
                           elsif (mem_addressData(28 downto 0) >= 16#1F000000# and mem_addressData(28 downto 0) < 16#1F800000#) then
                              ext_select_ex1 <= '1';
                              if (mem_rnw = '1') then
                                 state    <= BUSREADEXTERNAL;
                              else
                                 state    <= BUSWRITEEXTERNAL;
                              end if;
                           elsif (mem_addressData(28 downto 0) >= 16#1F802000# and mem_addressData(28 downto 0) < 16#1F804000#) then
                              ext_select_ex2 <= '1';
                              if (mem_rnw = '1') then
                                 state    <= BUSREADEXTERNAL;
                              else
                                 state    <= BUSWRITEEXTERNAL;
                              end if;
                           elsif (mem_rnw = '1' and mem_addressData(28 downto 0) >= 16#1FB20000# and mem_addressData(28 downto 0) <= 16#1FB20007#) then
                              -- MAME: unknown_r() returns 0x0000FFFF for all ZN platforms
                              state <= BUSREAD_UNKNOWNIO;
                           elsif (mem_rnw = '1' and zn_platform = "0010" and
                                  (mem_addressData(28 downto 0) = 16#1FBC0000# or
                                   (mem_addressData(28 downto 0) >= 16#1FBE0000# and mem_addressData(28 downto 0) < 16#1FBE0200#))) then
                              -- Taito FX-1B/1Z (gdarius/raystorm/ftimpact) Taito Zoom sound comm.
                              -- The FPGA does NOT emulate the MN10200 sound CPU, so these addresses
                              -- otherwise fall through to an unmapped SDRAM/open-bus read of UNDEFINED
                              -- value. Two addresses matter to the main CPU's sound dispatcher
                              -- (game code at 0x800B2A34):
                              --   0x1FBC0000  sound_irq_r : MAME returns 0; game does andi 1 / bne — if
                              --               bit0 reads 1 the dispatcher bails WITHOUT draining its
                              --               command queue (0x800B2A48-58), which can wedge any higher
                              --               level "wait for sound idle".  Return 0 => bit0 = 0 = "not busy".
                              --   0x1FBE0000-0x1FBE01FF  M66220FP shared RAM : game reads the status byte
                              --               and compares to 0x55 (0x800B2AE8/2AF4); == 0x55 means "slot
                              --               still owned by sound CPU" so it backs off.  Returning 0
                              --               (!= 0x55) keeps the slot "free" so the dispatcher always
                              --               uploads and advances its ring head => queue drains.
                              -- Both stubs mirror MAME's ground-truth handshake WITHOUT the sound CPU.
                              -- These EXACT addresses are UNIQUE to FX-1B/1Z; Taito FX-1A (fx1s: sfchamp/
                              -- psyforce, also zn_platform="0010") maps its sound via the TC0140SYT at
                              -- 0x1FB80000-0x1FB80003 and never touches 0x1FBC0000/0x1FBE0000, so this
                              -- decode is invisible to FX-1A.  Writes to these addresses are unchanged
                              -- (dropped by the final else BUSWRITE), matching current behaviour.
                              state <= BUSREAD_SNDSTUB;
                           else
                              ext_lastactive <= '0';
                              if (mem_rnw = '0') then
                                 state   <= BUSWRITE;
                              else
                                 state   <= BUSREADREQUEST;
                                 waitcnt <= 0;
                              end if;
                           end if;
                        end if;
            
                     end if;
                     
                  end if;        

               when WAITFORRAMREAD =>
                  if (waitcnt > 0) then
                     waitcnt <= waitcnt - 1;
                  else
                     state   <= IDLE;
                     ram_ena <= '1';
                     readram <= '1';
                  end if;
                  
               when WAITFORRAMWRITE =>
                  if (waitcnt > 0) then
                     waitcnt <= waitcnt - 1;
                  else
                     state   <= IDLE;
                     ram_ena  <= '1';
                     writeram <= '1';
                  end if;
                  
               when READBIOS =>
                  if (ram_done = '1') then
                     if (fastboot = '1' and to_integer(addressBIOS_buf) >= 16#18000# and to_integer(addressBIOS_buf) <= 16#18013#) then
                        case (to_integer(addressBIOS_buf(4 downto 2))) is
                           when 0 => biosPatch := x"3C011F80";
                           when 1 => biosPatch := x"3C0A0300";
                           when 2 => biosPatch := x"AC2A1814";
                           when 3 => biosPatch := x"03E00008";
                           when 4 => biosPatch := x"00000000";
                           when others => null;
                        end case;
                        case (addressBIOS_buf(1 downto 0)) is
                           when "00" => mem_dataRead_buf <= biosPatch;
                           when "01" => mem_dataRead_buf <= x"00" & biosPatch(31 downto 8);
                           when "10" => mem_dataRead_buf <= x"0000" & biosPatch(31 downto 16);
                           when "11" => mem_dataRead_buf <= x"000000" & biosPatch(31 downto 24);
                           when others => null;
                        end case;
                     elsif (PATCHSERIAL = '1' and (to_integer(addressBIOS_buf(18 downto 2)) = 16#1BC3# or to_integer(addressBIOS_buf(18 downto 2)) = 16#1BC5#)) then
                        if (to_integer(addressBIOS_buf(18 downto 2)) = 16#1BC3#) then mem_dataRead_buf <= x"24010001"; end if;
                        if (to_integer(addressBIOS_buf(18 downto 2)) = 16#1BC5#) then mem_dataRead_buf <= x"AF81A9C0"; end if;
                     else
                        mem_dataRead_buf <= data_ram_rotate;
                     end if;
                        
                     state    <= WAITING;
                  end if;
                  
               when READROM =>
                  if (ram_done = '1') then
                     mem_dataRead_buf <= data_ram_rotate;
                     mem_done_buf     <= '1';
                     -- If a prefetch was set up by the cold-miss path, store
                     -- the just-read word in its buffer slot and kick off the
                     -- 3-word back-fill of the rest of the line. Otherwise
                     -- return to IDLE as in baseline.
                     if (pf_remaining > 0) then
                        case pf_first_slot is
                           when "00"   => rom_buf_w0 <= data_ram;
                           when "01"   => rom_buf_w1 <= data_ram;
                        when "10"   => rom_buf_w2 <= data_ram;
                        when others => rom_buf_w3 <= data_ram;
                     end case;
                     rom_buf_word_valid(to_integer(unsigned(pf_first_slot))) <= '1';
                     state <= ROM_PF_FILL;
                     else
                        state <= IDLE;
                     end if;
                     -- build #49: EXACT-VALUE classification of the raw SDRAM word at the
                     -- single-word green anchor (CPU 0x1F644810). data_ram = ram_dataRead (raw,
                     -- not rotated). ROM holds 0x00200000 here. Split the mechanism:
                     --   palrd_green ([1]GREEN)        = hi halfword == 0x0020 (G1) -> CLEAN read
                     --   palrd_red   ([3]YELLOW)       = hi halfword == 0x0001 (R1) -> corrupted
                     --   palrd_redrow_red ([2]BLUE)    = lo halfword == 0x0001 (R1) -> +0x800 addr
                     --                                    offset (clean & >>5 both leave lo=BLK)
                     --   palrd_any   ([4]WHITE)        = anchor read fired
                     if (pal_read_pending = '1') then
                        palrd_any_seen <= '1';
                        palrd_value_latch <= data_ram;   -- build #50: capture raw word
                        -- build #52: store into the 8-word slot indexed by SDRAM addr bits[4:2]
                        case palrd_addr_latch(4 downto 2) is
                           when "000"  => palrd_w( 31 downto   0) <= data_ram;
                           when "001"  => palrd_w( 63 downto  32) <= data_ram;
                           when "010"  => palrd_w( 95 downto  64) <= data_ram;
                           when "011"  => palrd_w(127 downto  96) <= data_ram;
                           when "100"  => palrd_w(159 downto 128) <= data_ram;
                           when "101"  => palrd_w(191 downto 160) <= data_ram;
                           when "110"  => palrd_w(223 downto 192) <= data_ram;
                           when others => palrd_w(255 downto 224) <= data_ram;
                        end case;
                        if (data_ram(31 downto 16) = x"0020") then
                           palrd_green_seen <= '1';
                        end if;
                        if (data_ram(31 downto 16) = x"0001") then
                           palrd_red_seen <= '1';
                        end if;
                        if (data_ram(15 downto 0) = x"0001") then
                           palrd_redrow_red_seen <= '1';
                        end if;
                        pal_read_pending <= '0';
                     end if;
                  end if;

               -- ROM prefetch: fire one SDRAM read for the slot identified by
               -- pf_curr_slot at pf_line_addr_base + slot*4. Single-word, no
               -- cache. Loops back to ROM_PF_FILL until pf_remaining hits 0.
               when ROM_PF_FILL =>
                  -- A completed word may return while a later prefetch word
                  -- owns SDRAM. Keep the active SDRAM transaction untouched.
                  if (mem_save_request = '1' and mem_save_rnw = '1' and
                      mem_save_isData = '1' and ROM_PREFETCH = '1' and
                      mem_save_addressData(28 downto 0) >= 16#1F000000# and
                      mem_save_addressData(28 downto 0) < 16#1F200000# and
                      rom_buf_tag = std_logic_vector(mem_save_addressData(22 downto 4)) and
                      rom_buf_word_valid(to_integer(unsigned(mem_save_addressData(3 downto 2)))) = '1') then
                     mem_save_request <= '0';
                     mem_dataRead_buf <= std_logic_vector(shift_right(unsigned(rom_buf_saved_word),
                                          to_integer(mem_save_addressData(1 downto 0)) * 8));
                     mem_done_buf <= '1';
                  end if;
                  ram_ena   <= '1';
                  ram_cache <= '0';
                  ram_rnw   <= '1';
                  ram_Adr   <= pf_line_addr_base(26 downto 4) & pf_curr_slot & "00";
                  ram_rotate_bits <= "00";
                  state     <= ROM_PF_WAIT;

               when ROM_PF_WAIT =>
                  if (ram_done = '0' and mem_save_request = '1' and mem_save_rnw = '1' and
                      mem_save_isData = '1' and ROM_PREFETCH = '1' and
                      mem_save_addressData(28 downto 0) >= 16#1F000000# and
                      mem_save_addressData(28 downto 0) < 16#1F200000# and
                      rom_buf_tag = std_logic_vector(mem_save_addressData(22 downto 4)) and
                      rom_buf_word_valid(to_integer(unsigned(mem_save_addressData(3 downto 2)))) = '1') then
                     mem_save_request <= '0';
                     mem_dataRead_buf <= std_logic_vector(shift_right(unsigned(rom_buf_saved_word),
                                          to_integer(mem_save_addressData(1 downto 0)) * 8));
                     mem_done_buf <= '1';
                  end if;
                  if (ram_done = '1') then
                     case pf_curr_slot is
                        when "00"   => rom_buf_w0 <= data_ram;
                        when "01"   => rom_buf_w1 <= data_ram;
                        when "10"   => rom_buf_w2 <= data_ram;
                        when others => rom_buf_w3 <= data_ram;
                     end case;
                     rom_buf_word_valid(to_integer(unsigned(pf_curr_slot))) <= '1';
                     if (pf_remaining = 1) then
                        -- Last fill — mark the buffer valid and return to IDLE.
                        rom_buf_valid    <= '1';
                        rom_buf_tag      <= pf_tag_snap;
                        pf_remaining     <= 0;
                        state            <= IDLE;
                     else
                        pf_remaining <= pf_remaining - 1;
                        -- next slot to fill: advance, skipping pf_first_slot.
                        if (std_logic_vector(unsigned(pf_curr_slot) + 1) = pf_first_slot) then
                           pf_curr_slot <= std_logic_vector(unsigned(pf_curr_slot) + 2);
                        else
                           pf_curr_slot <= std_logic_vector(unsigned(pf_curr_slot) + 1);
                        end if;
                        state <= ROM_PF_FILL;
                     end if;
                  end if;

               when ROM_PF_BURST_WAIT =>
                  -- The SDRAM controller publishes the first cache word on
                  -- its ordinary ram_done before the clk3x collector has
                  -- completed the line.  Return an aligned slot-0 request
                  -- immediately; the next CPU load is latched while this
                  -- state waits for the remaining three beats.  This keeps
                  -- the line-fill latency from being paid twice by the
                  -- sequential ROM copy loop.
                  if (rom_speculative_burst = '1' and
                      mem_save_request = '1' and mem_save_rnw = '1' and
                      mem_save_isData = '1' and ROM_PREFETCH = '1' and
                      mem_save_addressData(28 downto 0) >= 16#1F000000# and
                      mem_save_addressData(28 downto 0) < 16#1F200000# and
                      rom_buf_valid = '1' and
                      rom_buf_tag = std_logic_vector(mem_save_addressData(22 downto 4)) and
                      rom_buf_word_valid(to_integer(unsigned(mem_save_addressData(3 downto 2)))) = '1') then
                     -- The CPU may issue another byte/halfword from the
                     -- current line after the slot-3 word.  Serve it from
                     -- the still-valid old buffer while the next line fills.
                     mem_save_request <= '0';
                     mem_dataRead_buf <= std_logic_vector(shift_right(unsigned(rom_buf_saved_word),
                                          to_integer(mem_save_addressData(1 downto 0)) * 8));
                     mem_done_buf <= '1';
                  elsif (ram_done = '1' and pf_first_returned = '0' and pf_first_slot = "00" and
                         mem_save_request = '1' and mem_save_rnw = '1' and
                         mem_save_isData = '1' and
                         mem_save_addressData(28 downto 0) >= 16#1F000000# and
                         mem_save_addressData(28 downto 0) < 16#1F200000# and
                         mem_save_addressData(22 downto 4) = unsigned(pf_tag_snap) and
                         mem_save_addressData(3 downto 2) = "00") then
                     -- For a cold or speculative miss, only return the first
                     -- SDRAM word early when the pending request is actually
                     -- slot 0 of the line being filled.  A same-line byte
                     -- request must never consume the next line's word.
                     rom_buf_w0            <= data_ram;
                     rom_buf_word_valid(0) <= '1';
                     -- data_ram is the aligned SDRAM word.  The CPU-facing
                     -- return must use the saved request's byte offset; the
                     -- live address may already describe a later request.
                     mem_dataRead_buf      <= std_logic_vector(shift_right(unsigned(data_ram),
                                                to_integer(mem_save_addressData(1 downto 0)) * 8));
                     -- This completion owns the saved request.  Keep the
                     -- burst active for its remaining words, but do not let
                     -- the completed load replay when the line is published.
                     mem_save_request     <= '0';
                     mem_done_buf          <= '1';
                     pf_first_returned     <= '1';
                  elsif (rom_burst_done = '1') then
                     rom_buf_w0          <= rom_burst_data(31 downto 0);
                     rom_buf_w1          <= rom_burst_data(63 downto 32);
                     rom_buf_w2          <= rom_burst_data(95 downto 64);
                     rom_buf_w3          <= rom_burst_data(127 downto 96);
                     rom_buf_word_valid  <= "1111";
                     rom_buf_valid       <= '1';
                     rom_buf_tag         <= pf_tag_snap;
                     pf_remaining        <= 0;
                     case pf_first_slot is
                        when "00" =>
                           mem_dataRead_buf <= std_logic_vector(shift_right(unsigned(rom_burst_data(31 downto 0)),
                                                       to_integer(unsigned(pf_first_rotate_bits)) * 8));
                        when "01" =>
                           mem_dataRead_buf <= std_logic_vector(shift_right(unsigned(rom_burst_data(63 downto 32)),
                                                       to_integer(unsigned(pf_first_rotate_bits)) * 8));
                        when "10" =>
                           mem_dataRead_buf <= std_logic_vector(shift_right(unsigned(rom_burst_data(95 downto 64)),
                                                       to_integer(unsigned(pf_first_rotate_bits)) * 8));
                        when others =>
                           mem_dataRead_buf <= std_logic_vector(shift_right(unsigned(rom_burst_data(127 downto 96)),
                                                       to_integer(unsigned(pf_first_rotate_bits)) * 8));
                     end case;
                     -- If ram_done already returned slot 0, do not replay it
                     -- when the full line arrives.  Non-slot-0 cold misses
                     -- still receive their first response here.
                     if (pf_first_returned = '0') then
                        mem_done_buf <= '1';
                     end if;
                     pf_first_returned <= '0';
                     state        <= IDLE;
                  end if;

               when BUSWRITE =>
                  state        <= IDLE;

               when BUSREAD_CDSTUB =>
                  mem_dataRead_buf <= x"FFFFFFFF";
                  mem_done_buf     <= '1';
                  state            <= IDLE;

               when BUSREAD_UNKNOWNIO =>
                  mem_dataRead_buf <= x"0000FFFF";
                  mem_done_buf     <= '1';
                  state            <= IDLE;

               when BUSREAD_SNDSTUB =>
                  -- Taito FX-1B/1Z sound-comm read stub: return 0 so the main-CPU sound
                  -- dispatcher sees "sound not busy" (0x1FBC0000 bit0=0) and an M66220 status
                  -- byte != 0x55 (0x1FBE00xx), letting it drain its command queue instead of
                  -- wedging on the absent MN10200 sound CPU.  Mirrors MAME sound_irq_r()==0.
                  mem_dataRead_buf <= x"00000000";
                  mem_done_buf     <= '1';
                  state            <= IDLE;

               when FRAMWAIT =>
                  -- M10K registered fram_addr this cycle; q_a valid next cycle (BUSREAD_FRAM).
                  state <= BUSREAD_FRAM;

               when BUSREAD_FRAM =>
                  -- fram_q is the FRAM word at fram_addr (registered in IDLE, one FRAMWAIT cycle
                  -- ago), byte-rotated by the request offset like any 32-bit peripheral so
                  -- that lhu/lbu at odd halfword/byte offsets land in the low bits.
                  case (addressData_buf(1 downto 0)) is
                     when "00"   => mem_dataRead_buf <=                fram_q;
                     when "01"   => mem_dataRead_buf <= x"00"       & fram_q(31 downto  8);
                     when "10"   => mem_dataRead_buf <= x"0000"     & fram_q(31 downto 16);
                     when others => mem_dataRead_buf <= x"000000"   & fram_q(31 downto 24);
                  end case;
                  mem_done_buf     <= '1';
                  state            <= IDLE;

               when BUSWRITEEXTERNAL => 
                  if (ext_state = EXT_IDLE) then
                     state          <= IDLE;
                  end if;
                  
               when BUSREADEXTERNAL => 
                  if (ext_done = '1') then
                     state          <= IDLE;
                     ext_lastactive <= '1';
                  end if;
                  
               when BUSREADREQUEST =>
                  -- EEPROM reads: hold one extra cycle so the zn1_io altsyncram output settles
                  -- (registered address = +1 cycle latency vs the combinational znio registers).
                  if (ee_read_wait = '1') then
                     ee_read_wait <= '0';
                     state <= BUSREADREQUEST;   -- stay: enableRead/address held, altsyncram settles
                  else
                     state <= BUSREAD;
                  end if;
                  rotate32       <= '0';
                  rotate16       <= '0';
                  if (bus_memc_read  = '1') then rotate32 <= '1'; end if;
                  if (bus_pad_read   = '1') then rotate16 <= '1'; end if;
                  if (bus_sio_read   = '1') then rotate16 <= '1'; end if;
                  if (bus_memc2_read = '1') then rotate32 <= '1'; end if;
                  if (bus_dma_read   = '1') then rotate32 <= '1'; end if;
                  if (bus_tmr_read   = '1') then rotate32 <= '1'; end if;
                  if (bus_irq_read   = '1') then rotate32 <= '1'; end if;
                  if (bus_gpu_read   = '1') then rotate32 <= '1'; end if;
                  if (bus_mdec_read  = '1') then rotate32 <= '1'; end if;
                  if (bus_znio_read  = '1') then rotate32 <= '1'; end if;
                  if (bus_pr2_read   = '1') then rotate32 <= '1'; end if;

               when BUSREAD =>
                  if (bus_stall = '0') then
                     if (rotate32 = '1') then
                        case (addressData_buf(1 downto 0)) is
                           when "00" => mem_dataRead_buf <= dataFromBusses;
                           when "01" => mem_dataRead_buf <= x"00" & dataFromBusses(31 downto 8);
                           when "10" => mem_dataRead_buf <= x"0000" & dataFromBusses(31 downto 16);
                           when "11" => mem_dataRead_buf <= x"000000" & dataFromBusses(31 downto 24);
                           when others => null;
                        end case;
                     elsif (rotate16 = '1') then
                        if (addressData_buf(0) = '1') then
                           mem_dataRead_buf <= x"00" & dataFromBusses(31 downto 8);
                        else
                           mem_dataRead_buf <= dataFromBusses;
                        end if;
                     else
                        mem_dataRead_buf <= dataFromBusses;
                     end if;
                     mem_done_buf <= '1';
                     state        <= IDLE;
                  end if;
                  
               when WAITING =>
                  if (waitcnt > 0) then
                     waitcnt <= waitcnt - 1;
                  else
                     mem_done_buf <= '1';
                     state        <= IDLE;
                  end if;
                  
-- #################################################
-- ##################### EXE loading 
-- #################################################
                  
               when EXEPATCHBIOSWRITE =>
                  state       <= EXEPATCHBIOSWAIT;
                  ram_ena     <= '1';
                  ram_cache   <= '0';
                  ram_rnw     <= '0';
                  ram_be      <= "1111";
                  case (exestep) is
                     -- load PC
                     when 0 => ram_Adr <= "00001000" & std_logic_vector(to_unsigned(16#6FF0#, 17)) & "00"; ram_dataWrite <= x"3C08" & std_logic_vector(exe_initial_pc(31 downto 16));
                     when 1 => ram_Adr <= "00001000" & std_logic_vector(to_unsigned(16#6FF4#, 17)) & "00"; ram_dataWrite <= x"3508" & std_logic_vector(exe_initial_pc(15 downto  0));
                     when 2 => ram_Adr <= "00001000" & std_logic_vector(to_unsigned(16#6FF8#, 17)) & "00"; ram_dataWrite <= x"3C1C" & std_logic_vector(exe_initial_gp(31 downto 16));
                     when 3 => ram_Adr <= "00001000" & std_logic_vector(to_unsigned(16#6FFC#, 17)) & "00"; ram_dataWrite <= x"379C" & std_logic_vector(exe_initial_gp(15 downto  0));
                     -- load sp
                     when 4 => ram_Adr <= "00001000" & std_logic_vector(to_unsigned(16#7000#, 17)) & "00"; ram_dataWrite <= x"3C1D" & std_logic_vector(exe_stackpointer(31 downto 16));
                     when 5 => ram_Adr <= "00001000" & std_logic_vector(to_unsigned(16#7004#, 17)) & "00"; ram_dataWrite <= x"37BD" & std_logic_vector(exe_stackpointer(15 downto  0));
                     -- load fp
                     when 6 => ram_Adr <= "00001000" & std_logic_vector(to_unsigned(16#7008#, 17)) & "00"; ram_dataWrite <= x"3C1E" & std_logic_vector(exe_stackpointer(31 downto 16));
                     when 7 => ram_Adr <= "00001000" & std_logic_vector(to_unsigned(16#700C#, 17)) & "00"; ram_dataWrite <= x"01000008";
                     when 8 => ram_Adr <= "00001000" & std_logic_vector(to_unsigned(16#7010#, 17)) & "00"; ram_dataWrite <= x"37DE" & std_logic_vector(exe_stackpointer(15 downto  0));
                     when others => null;
                  end case;
                  if (exe_stackpointer = 0 and (exestep = 4 or exestep = 5 or exestep = 6 or exestep = 8)) then
                     ram_dataWrite <= (others => '0');
                  end if;
                  
                  if (exestep < 8) then
                     state   <= EXEPATCHBIOSWAIT;
                     exestep <= exestep + 1;
                  else
                     state <= EXECOPYREAD;
                  end if;
                  
               when EXEPATCHBIOSWAIT =>
                  if (ram_done = '1') then
                     state   <= EXEPATCHBIOSWRITE;
                  end if;
                  
               when EXECOPYREAD =>
                  if (ram_done = '1') then
                     if (execopycnt >= (exe_file_size + 3)) then
                        state           <= IDLE;
                        reset_exe       <= '1';
                        loadExe_latched <= '0';
                     else
                        state      <= EXECOPYWRITE;
                        ram_ena    <= '1';
                        ram_rnw    <= '1';
                        ram_Adr    <= "0010" & std_logic_vector(to_unsigned(16#800#, 23) + execopycnt(22 downto 0));
                     end if;
                  end if;
                  
               when EXECOPYWRITE =>
                  if (ram_done = '1') then
                     state         <= EXECOPYREAD;
                     ram_ena       <= '1';
                     ram_rnw       <= '0';
                     ram_Adr       <= "0000" & std_logic_vector(exe_load_address(22 downto 0) + execopycnt(22 downto 0));
                     ram_dataWrite <= ram_dataRead(31 downto 0);
                     execopycnt    <= execopycnt + 4;
                  end if;
                  
               when others => null;
            
            end case;
            end if;
            
         else
         
            case (state) is
               when IDLE =>
                  if (SS_wren_SDRam = '1') then
                     ram_ena       <= '1';
                     ram_cache     <= '0';
                     ram_rnw       <= '0';
                     ram_Adr       <= "000000" & std_logic_vector(SS_Adr(18 downto 0)) & "00";
                     ram_be        <= "1111";
                     ram_dataWrite <= SS_DataWrite;
                  end if;
                  if (SS_rden_SDRam = '1') then
                     ram_ena       <= '1';
                     ram_cache     <= '0';
                     ram_rnw       <= '1';
                     ram_Adr       <= "000000" & std_logic_vector(SS_Adr(18 downto 0)) & "00";
                  end if;
            
               when others => null;
            end case;

         end if;
      end if;
   end process;
   
--##############################################################
--############################### external busses
--##############################################################
   
   
   ext_memctrl <= spu_memctrl when (ext_select_spu = '1') else
                  cd_memctrl  when (ext_select_cd  = '1') else
                  ex1_memctrl when (ext_select_ex1 = '1') else
                  ex2_memctrl when (ext_select_ex2 = '1') else
                  ex3_memctrl when (ext_select_ex3 = '1') else
                  (others => '0');
   
   
   bus_spu_addr      <= ext_bus_addr(9 downto 0);
   bus_spu_write     <= '1' when (ext_write_ena = '1' and ext_select_spu_saved = '1') else '0';
   bus_spu_read      <= '1' when (ext_state = EXT_READ_NEXT and ext_select_spu_saved = '1') else '0';
   bus_spu_dataWrite <= ext_dataWrite;
   
   bus_cd_addr       <= ext_bus_addr(3 downto 0);
   bus_cd_write      <= '1' when (ext_write_ena = '1' and ext_select_cd_saved = '1') else '0';
   bus_cd_read       <= '1' when (ext_state = EXT_READ_NEXT and ext_select_cd_saved = '1') else '0';
   bus_cd_dataWrite  <= ext_dataWrite(7 downto 0);
   
   bus_exp2_addr      <= ext_bus_addr;
   bus_exp2_write     <= '1' when (ext_write_ena = '1' and ext_select_ex2_saved = '1') else '0';
   bus_exp2_read      <= '1' when (ext_state = EXT_READ_NEXT and ext_select_ex2_saved = '1') else '0';
   bus_exp2_dataWrite <= ext_dataWrite(7 downto 0);
   
   -- busses EXP1+3 are stubs that are working in general, but there is nothing connected to them, so unused parts are not implemented
   bus_exp1_read     <= '1' when (ext_state = EXT_READ_NEXT and ext_select_ex1_saved = '1') else '0';
   bus_exp3_read     <= '1' when (ext_state = EXT_READ_NEXT and ext_select_ex3_saved = '1') else '0';
   
   ext_done          <= '1' when (ext_state = EXT_READ and ext_finished = '1') else '0';
   
   
   process (ext_select_spu_saved, ext_select_cd_saved, ext_select_ex1_saved, ext_select_ex2_saved, ext_select_ex3_saved,
            bus_spu_dataRead, bus_cd_dataRead, bus_exp1_dataRead, bus_exp2_dataRead, bus_exp3_dataRead,
            ext_byteStep, addressData_buf, ext_data)
   begin
   
      ext_data_new <= ext_data;
   
      if (ext_select_spu_saved = '1') then
         case (ext_byteStep) is
            when "00" => 
               if (addressData_buf(0) = '1') then 
                  ext_data_new( 7 downto  0) <= bus_spu_dataRead(15 downto 8); 
               else 
                  ext_data_new(15 downto  0) <= bus_spu_dataRead; 
               end if;
            when "10" => 
               if (addressData_buf(0) = '1') then 
                  ext_data_new(23 downto  8) <= bus_spu_dataRead;
               else 
                  ext_data_new(31 downto 16) <= bus_spu_dataRead; 
               end if;  
            when others => null;
         end case;
      elsif (ext_select_cd_saved = '1') then
         case (ext_byteStep) is
            when "00" => ext_data_new( 7 downto  0) <= bus_cd_dataRead;
            when "01" => ext_data_new(15 downto  8) <= bus_cd_dataRead;
            when "10" => ext_data_new(23 downto 16) <= bus_cd_dataRead;
            when "11" => ext_data_new(31 downto 24) <= bus_cd_dataRead;
            when others => null;
         end case;                 
      elsif (ext_select_ex1_saved = '1') then
         case (ext_byteStep) is
            when "00" => ext_data_new( 7 downto  0) <= bus_exp1_dataRead;
            when "01" => ext_data_new(15 downto  8) <= bus_exp1_dataRead;
            when "10" => ext_data_new(23 downto 16) <= bus_exp1_dataRead;
            when "11" => ext_data_new(31 downto 24) <= bus_exp1_dataRead;
            when others => null;
         end case;
      elsif (ext_select_ex2_saved = '1') then
         case (ext_byteStep) is
            when "00" => ext_data_new( 7 downto  0) <= bus_exp2_dataRead;
            when "01" => ext_data_new(15 downto  8) <= bus_exp2_dataRead;
            when "10" => ext_data_new(23 downto 16) <= bus_exp2_dataRead;
            when "11" => ext_data_new(31 downto 24) <= bus_exp2_dataRead;
            when others => null;
         end case;
      elsif (ext_select_ex3_saved = '1') then
         case (ext_byteStep) is
            when "00" => 
               if (addressData_buf(0) = '1') then 
                  ext_data_new( 7 downto  0) <= bus_exp3_dataRead(15 downto 8); 
               else 
                  ext_data_new(15 downto  0) <= bus_exp3_dataRead; 
               end if;
            when "10" => 
               if (addressData_buf(0) = '1') then 
                  ext_data_new(23 downto  8) <= bus_exp3_dataRead;
               else 
                  ext_data_new(31 downto 16) <= bus_exp3_dataRead; 
               end if;  
            when others => null;
         end case;
      end if;
 
   end process;
   
   
   process (clk1x)
      variable newWait : integer range 0 to 63;
   begin
      if rising_edge(clk1x) then
      
         ext_write_ena        <= '0';
         ext_recovered        <= '0';
         
         if (reset = '1') then

            ext_state     <= EXT_IDLE;
            ext_reccount  <= 0;

         elsif (ce = '1') then
         
            if (ext_reccount > 0) then
               ext_reccount  <= ext_reccount - 1;
               ext_recovered <= '1';
            end if;
         
            case (ext_state) is
            
               when EXT_IDLE =>
                  ext_finished         <= '0';
                  ext_dataWrite_buf    <= dataWrite_buf;
                  ext_writeMask_buf    <= writeMask_buf;
                  ext_byteStep         <= (others => '0');
                  ext_data             <= (others => '0');
                  ext_bus_addr         <= addressData_buf(12 downto 0);
                  
                  ext_select_spu_saved <= ext_select_spu;
                  ext_select_cd_saved  <= ext_select_cd;
                  ext_select_ex1_saved <= ext_select_ex1;
                  ext_select_ex2_saved <= ext_select_ex2;
                  ext_select_ex3_saved <= ext_select_ex3;

                  ext_memctrl_WDelay   <= ext_memctrl(3 downto 0);
                  ext_memctrl_RDelay   <= ext_memctrl(7 downto 4);
                  ext_memctrl_RecP     <= ext_memctrl(8);
                  ext_memctrl_Hold     <= ext_memctrl(9);
                  ext_memctrl_Float    <= ext_memctrl(10);
                  ext_memctrl_PStrobe  <= ext_memctrl(11);
                  ext_memctrl_width    <= ext_memctrl(12);
                  ext_memctrl_autoinc  <= ext_memctrl(13);
                  
                  if (state = BUSWRITEEXTERNAL) then
                  
                     ext_state  <= EXT_WRITE;
                     if (ext_reccount > 1) then
                        ext_state   <= EXE_WRITE_PREWAIT;
                        ext_waitcnt <= ext_reccount - 1;
                     end if;
                     
                     if (ext_memctrl(12) = '0' and writeMask_buf(2 downto 0) = "000") then
                        ext_byteStep                   <= "11";
                        ext_bus_addr(1 downto 0)       <= "11";
                     elsif (writeMask_buf(1 downto 0) = "00") then
                        ext_byteStep                   <= "10";
                        ext_bus_addr(1 downto 0)       <= "10";
                     elsif (ext_memctrl(12) = '0' and writeMask_buf(0) = '0') then
                        ext_byteStep                   <= "01";
                        ext_bus_addr(1 downto 0)       <= "01";
                     end if;

                  elsif (state = BUSREADEXTERNAL and ext_reccount = 0) then
                  
                     newWait := 0;
                     if (ext_lastactive = '1' and ext_recovered = '0') then
                        newWait := 1;
                     end if;
                     if (ext_memctrl(7 downto 4) > 0) then
                        newWait := newWait + to_integer(ext_memctrl(7 downto 4));
                     end if;
                     if (ext_memctrl(11) = '1' and com3_delay > ext_memctrl(7 downto 4)) then -- assumption from cd test! 
                        newWait := newWait + to_integer(com3_delay) - to_integer(ext_memctrl(7 downto 4));
                     end if;
                     ext_waitcnt <= newWait;
                     
                     if (newWait > 0) then
                        ext_state    <= EXT_READ_WAIT;
                     else
                        ext_state    <= EXT_READ_NEXT;
                     end if;
                        
                  end if;
                  
               -- write
               when EXE_WRITE_PREWAIT =>
                  if (ext_waitcnt > 0) then
                     ext_waitcnt    <= ext_waitcnt - 1;
                  else
                     ext_state  <= EXT_WRITE; 
                  end if;
               
               when EXT_WRITE =>
                  case (ext_byteStep) is
                     when "00" => if (ext_writeMask_buf(0) = '1') then ext_write_ena <= '1'; ext_dataWrite <=         ext_dataWrite_buf(15 downto  0); end if;
                     when "01" => if (ext_writeMask_buf(1) = '1') then ext_write_ena <= '1'; ext_dataWrite <= x"00" & ext_dataWrite_buf(15 downto  8); end if;
                     when "10" => if (ext_writeMask_buf(2) = '1') then ext_write_ena <= '1'; ext_dataWrite <=         ext_dataWrite_buf(31 downto 16); end if;
                     when "11" => if (ext_writeMask_buf(3) = '1') then ext_write_ena <= '1'; ext_dataWrite <= x"00" & ext_dataWrite_buf(31 downto 24); end if;
                     when others => null;
                  end case;
                  ext_state   <= EXT_WRITE_WAIT;
                  
                  newWait := to_integer(ext_memctrl_WDelay);
                  if (ext_memctrl_PStrobe = '1' and com3_delay > ext_memctrl_WDelay) then -- assumption from cd test! 
                     newWait := newWait + to_integer(com3_delay) - to_integer(ext_memctrl_WDelay);
                  end if;
                  if (ext_memctrl_Hold = '1') then
                     newWait := newWait + to_integer(com1_delay);
                  end if;
                  ext_waitcnt <= newWait;
                  
                  if (ext_memctrl_width = '0' and ext_byteStep = "11") then
                     ext_finished       <= '1';
                  elsif (ext_memctrl_width = '0' and ext_byteStep = "01" and ext_writeMask_buf(3 downto 2) = "00") then
                     ext_finished       <= '1';
                  elsif (ext_memctrl_width = '0' and ext_byteStep = "00" and ext_writeMask_buf(3 downto 1) = "000") then
                     ext_finished       <= '1';
                  elsif (ext_memctrl_width = '1' and (ext_byteStep = "10" or ext_writeMask_buf(2) = '0')) then
                     ext_finished       <= '1';
                  end if;
                  
                  if (ext_memctrl_RecP = '1') then 
                     if (ext_memctrl_PStrobe = '1') then  -- assumption from cd test! 
                        ext_reccount <= to_integer(com0_delay) + to_integer(ext_memctrl_WDelay);
                     else
                        ext_reccount <= to_integer(com0_delay);
                     end if;
                  end if;
                  
               when EXT_WRITE_WAIT =>
                  if (ext_waitcnt > 0) then
                     ext_waitcnt    <= ext_waitcnt - 1;
                  elsif (ext_finished = '1') then
                     ext_state      <= EXT_IDLE;
                  else
                     
                     if (ext_memctrl_RecP = '1' and com0_delay > 1) then 
                        ext_state   <= EXE_WRITE_PREWAIT;
                        ext_waitcnt <= to_integer(com0_delay) - 2; 
                     else
                        ext_state   <= EXT_WRITE;
                     end if;
                     
                     if (ext_memctrl_width = '1') then
                        ext_byteStep             <= ext_byteStep + 2;
                        if (ext_memctrl_autoinc = '1') then
                           ext_bus_addr(1 downto 0) <= ext_bus_addr(1 downto 0) + 2;
                        end if;
                     else
                        ext_byteStep             <= ext_byteStep + 1;
                        if (ext_memctrl_autoinc = '1') then
                           ext_bus_addr(1 downto 0) <= ext_bus_addr(1 downto 0) + 1;
                        end if;
                     end if;
                  end if;
                  
               -- read
               when EXT_READ_NEXT =>
                  ext_state <= EXT_READ;
                  
                  if (ext_memctrl_width = '0' and ext_byteStep = "11") then
                     ext_finished       <= '1';
                  elsif (ext_memctrl_width = '0' and ext_byteStep = "01" and reqsize_buf = "01") then
                     ext_finished       <= '1';
                  elsif (ext_memctrl_width = '0' and ext_byteStep = "00" and reqsize_buf = "00") then
                     ext_finished       <= '1';
                  elsif (ext_memctrl_width = '1' and (ext_byteStep = "10" or reqsize_buf /= "10")) then
                     ext_finished       <= '1';
                  end if;
                  
                  newWait := 0;
                  if (ext_memctrl_RecP = '1') then 
                     newWait := newWait + to_integer(com0_delay);
                  end if;
                  if (ext_memctrl_Float = '1') then 
                     newWait := newWait + to_integer(com2_delay) + 1;
                  end if;
                  ext_reccount <= newWait;
                  
               when EXT_READ =>
               
                  ext_data <= ext_data_new;
               
                  if (ext_finished = '1') then
                     ext_state      <= EXT_IDLE;
                  else
                  
                     newWait  := to_integer(ext_memctrl_RDelay);
                     if (ext_memctrl_RecP = '1' and com0_delay > 0) then 
                        newWait := newWait + (to_integer(com0_delay) - 1); 
                     end if;
                     if (ext_memctrl_PStrobe = '1') then 
                        if (ext_memctrl_RecP = '0') then
                           newWait := newWait + to_integer(com3_delay);
                        elsif (com3_delay > com0_delay) then
                           newWait := newWait + to_integer(com3_delay) - to_integer(com0_delay);  -- assumption from cd test! 
                        end if;
                     end if;
                     if (ext_memctrl_Float = '1') then 
                        newWait := newWait + to_integer(com2_delay);
                     end if;
                     if (ext_memctrl_RecP = '1' and ext_memctrl_Float = '1') then -- assumption from exp2 read test! 
                        newWait := newWait + 1;
                     end if;
                     ext_waitcnt  <= newWait;
                  
                     if (newWait > 0) then
                        ext_state    <= EXT_READ_WAIT;
                     else
                        ext_state    <= EXT_READ_NEXT;
                     end if;
                     
                     if (ext_memctrl_width = '1') then
                        ext_byteStep             <= ext_byteStep + 2;
                        if (ext_memctrl_autoinc = '1') then
                           ext_bus_addr(1 downto 0) <= ext_bus_addr(1 downto 0) + 2;
                        end if;
                     else
                        ext_byteStep             <= ext_byteStep + 1;
                        if (ext_memctrl_autoinc = '1') then
                           ext_bus_addr(1 downto 0) <= ext_bus_addr(1 downto 0) + 1;
                        end if;
                     end if;
                  end if;
                  
               when EXT_READ_WAIT =>
                  if (ext_waitcnt > 1) then
                     ext_waitcnt <= ext_waitcnt - 1;
                  else
                     ext_state   <= EXT_READ_NEXT;
                  end if;
            
            end case;
   
         end if;
         
      end if;
   end process;
   
--##############################################################
--############################### debug
--##############################################################

   process (clk1x)
   begin
      if (rising_edge(clk1x)) then
      
         if (reset = '1') then
         
            stallcountRead    <= 0;
            stallcountReadC    <= 0;
            stallcountWrite   <= 0;
            stallcountWriteF  <= 0;
            stallcountIntBus  <= 0;
      
         elsif (ce = '1') then
         
            if (stallcountRead = 0 and stallcountReadC = 0 and stallcountWrite = 0 and stallcountIntBus = 0 and stallcountWriteF = 0) then
               stallcountRead <= 0;
            end if;
            
            if (readram = '1') then
               stallcountRead <= stallcountRead + 1;
               if (ram_cache = '1') then
                  stallcountReadC <= stallcountReadC + 1;
               end if;
            end if;            
            
            if (writeram = '1') then
               stallcountWrite <= stallcountWrite + 1;
               if (addressDataF = '1') then
                  stallcountWriteF <= stallcountWriteF + 1;
               end if;
            end if;
            
            if (mem_request = '1') then
               addressDataF <= '0';
               if (mem_addressData(30) = '0' and mem_rnw = '0' and mem_addressData(28 downto 0) < 16#800000#) then
                  addressDataF <= '1';
               end if;
            end if;
            
            --if (state = BUSREAD or state = BUSWRITE or state = SPU_WRITE or state = SPU_READ or state = SPU_READ_WAIT or state = CD_READ or state = CD_READ_WAIT or state = CD_WRITE) then
            --   stallcountIntBus <= stallcountIntBus + 1;
            --end if;

         end if;
      end if;
   end process;

   -- build #39: expose Tecmo bank register for debug instrumentation
   zn_bank_8mb_out <= zn_bank_8mb;

   -- Taito FX-1B/1Z FM1208S FRAM storage: 256 x 32-bit M10K, 4-bit byte-enable,
   -- UNREGISTERED output (q valid the cycle after the registered address). The FSM
   -- (process above) drives fram_addr/fram_din/fram_be/fram_wren in IDLE and reads
   -- fram_q in the BUSREAD_FRAM state one cycle later. Implemented as block RAM (not
   -- logic registers) to avoid an ~2000-ALM device overflow.
   ifram : altsyncram
   generic map (
      operation_mode                => "SINGLE_PORT",
      width_a                       => 32,
      widthad_a                     => 8,
      numwords_a                    => 256,
      width_byteena_a               => 4,
      byte_size                     => 8,
      outdata_reg_a                 => "UNREGISTERED",
      ram_block_type                => "M10K",
      read_during_write_mode_port_a => "NEW_DATA_NO_NBE_READ",
      init_file                     => "fram_ff.mif",  -- #291: blank FM1208S = 0xFF, not 0x00
      lpm_type                      => "altsyncram"
   )
   port map (
      clock0    => clk1x,
      address_a => fram_addr,
      wren_a    => fram_wren,
      byteena_a => fram_be,
      data_a    => fram_din,
      q_a       => fram_q
   );

end architecture;





