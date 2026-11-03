-- Flat-port wrapper around the T65 6502 core.  T65's DEBUG port is a VHDL
-- record, which cannot be a port of a mixed-language or netlist top level, so
-- the record stays inside and the useful debug registers come out as
-- std_logic_vectors.
--
-- Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
-- GPL-3.0-or-later; see LICENSE, NOTICE.md.  (T65 itself keeps its own
-- licence; see the header of T65.vhd.)

library ieee;
use ieee.std_logic_1164.all;
use work.T65_Pack.all;

entity T65_wrap is
	port(
		Mode   : in  std_logic_vector(1 downto 0);
		Res_n  : in  std_logic;
		Clk    : in  std_logic;
		Enable : in  std_logic;
		Rdy    : in  std_logic;
		IRQ_n  : in  std_logic;
		NMI_n  : in  std_logic;
		DI     : in  std_logic_vector(7 downto 0);
		A      : out std_logic_vector(15 downto 0);
		DO     : out std_logic_vector(7 downto 0);
		R_W_n  : out std_logic;
		Sync   : out std_logic;
		dbg_A  : out std_logic_vector(7 downto 0);
		dbg_X  : out std_logic_vector(7 downto 0);
		dbg_Y  : out std_logic_vector(7 downto 0);
		dbg_S  : out std_logic_vector(7 downto 0);
		dbg_P  : out std_logic_vector(7 downto 0)
	);
end T65_wrap;

architecture rtl of T65_wrap is
	signal fullA : std_logic_vector(23 downto 0);
	signal dbg   : T_t65_dbg;
begin
	A     <= fullA(15 downto 0);
	dbg_A <= dbg.A;
	dbg_X <= dbg.X;
	dbg_Y <= dbg.Y;
	dbg_S <= dbg.S;
	dbg_P <= dbg.P;

	u_t65 : entity work.T65
		port map(
			Mode => Mode, BCD_en => '1',
			Res_n => Res_n, Clk => Clk, Enable => Enable,
			A => fullA, DI => DI, DO => DO,
			Rdy => Rdy, Abort_n => '1', IRQ_n => IRQ_n, NMI_n => NMI_n, SO_n => '1',
			R_W_n => R_W_n, Sync => Sync,
			EF => open, MF => open, XF => open, ML_n => open, VP_n => open,
			VDA => open, VPA => open, DEBUG => dbg, NMI_ack => open
		);
end rtl;
