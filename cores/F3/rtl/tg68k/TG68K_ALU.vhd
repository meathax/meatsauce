------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- Copyright (c) 2009-2020 Tobias Gubener                                   -- 
-- Patches by MikeJ, Till Harbaum, Rok Krajnk, ...                          --
-- Subdesign fAMpIGA by TobiFlex                                            --
--                                                                          --
-- This source file is free software: you can redistribute it and/or modify --
-- it under the terms of the GNU Lesser General Public License as published --
-- by the Free Software Foundation, either version 3 of the License, or     --
-- (at your option) any later version.                                      --
--                                                                          --
-- This source file is distributed in the hope that it will be useful,      --
-- but WITHOUT ANY WARRANTY; without even the implied warranty of           --
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the            --
-- GNU General Public License for more details.                             --
--                                                                          --
-- You should have received a copy of the GNU General Public License        --
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.    --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use IEEE.numeric_std.all;
use work.TG68K_Pack.all;

entity TG68K_ALU is
generic(
		MUL_Mode : integer;			--0=>16Bit,	1=>32Bit,	2=>switchable with CPU(1),	3=>no MUL,  
		MUL_Hardware : integer;		--0=>no,		1=>yes,  
		DIV_Mode : integer;			--0=>16Bit,	1=>32Bit,	2=>switchable with CPU(1),	3=>no DIV,  
		BarrelShifter :integer		--0=>no,		1=>yes,		2=>switchable with CPU(1)  
		);
	port(clk						: in std_logic;
		Reset						: in std_logic;
		clkena_lw				: in std_logic:='1';
		CPU						: in std_logic_vector(1 downto 0):="00";  -- 00->68000  01->68010  11->68020(only some parts - yet)
		execOPC					: in bit;
		decodeOPC				: in bit;
		exe_condition			: in std_logic;
		exec_tas					: in std_logic;
		long_start				: in bit;
		non_aligned				: in std_logic;
		check_aligned			: in std_logic;
		movem_presub			: in bit;
		set_stop					: in bit;
		Z_error 					: in bit;
		rot_bits					: in std_logic_vector(1 downto 0);
		exec						: in bit_vector(lastOpcBit downto 0);
		OP1out					: in std_logic_vector(31 downto 0);
		OP2out					: in std_logic_vector(31 downto 0);
		reg_QA					: in std_logic_vector(31 downto 0);
		reg_QB					: in std_logic_vector(31 downto 0);
		opcode					: in std_logic_vector(15 downto 0);
		exe_opcode				: in std_logic_vector(15 downto 0);
		exe_datatype			: in std_logic_vector(1 downto 0);
		sndOPC					: in std_logic_vector(15 downto 0);
		last_data_read			: in std_logic_vector(15 downto 0);
		data_read				: in std_logic_vector(15 downto 0);
		FlagsSR					: in std_logic_vector(7 downto 0);
		micro_state				: in micro_states;  
		bf_ext_in				: in std_logic_vector(7 downto 0);
		bf_ext_out				: out std_logic_vector(7 downto 0);
		bf_shift					: in std_logic_vector(5 downto 0);
		bf_width					: in std_logic_vector(5 downto 0);
		bf_ffo_offset			: in std_logic_vector(31 downto 0);
		bf_loffset				: in std_logic_vector(4 downto 0);

		set_V_Flag				: buffer bit;
		Flags						: buffer std_logic_vector(7 downto 0);
		c_out						: buffer std_logic_vector(2 downto 0);
		addsub_q					: buffer std_logic_vector(31 downto 0);
		ALUout					: out std_logic_vector(31 downto 0);
		-- BFFFO write-back reads a registered bit count: the parent must not
		-- enable the CPU on a clock directly after an enabled clock while
		-- this is high (rf_main: !(bfffo_hold && cpu_fresh)).
		bfffo_hold				: out std_logic
	);
end TG68K_ALU;

architecture logic of TG68K_ALU is

	-- Encode the highest selected bit directly as a one-based count.
	-- Decode four bits in parallel with the test for higher groups.
	function bfffo_count(data : std_logic_vector(31 downto 0))
		return std_logic_vector is
		variable count : std_logic_vector(5 downto 0) := (others => '0');
		variable group_bits : std_logic_vector(3 downto 0);
		variable local_count : std_logic_vector(5 downto 0);
	begin
		for group_index in 0 to 7 loop
			group_bits := data(4 * group_index + 3 downto 4 * group_index);
			if group_bits(3 downto 2) /= "00" then
				if group_bits(3) = '0' then
					local_count := std_logic_vector(to_unsigned(4 * group_index + 3, 6));
				else
					local_count := std_logic_vector(to_unsigned(4 * group_index + 4, 6));
				end if;
			elsif group_bits(1) /= '0' then
				local_count := std_logic_vector(to_unsigned(4 * group_index + 2, 6));
			elsif group_bits(0) /= '0' then
				local_count := std_logic_vector(to_unsigned(4 * group_index + 1, 6));
			else
				local_count := (others => '0');
			end if;
			if group_index = 0 or group_bits /= "0000" then
				if group_index = 7 then
					count := count or local_count;
				elsif data(31 downto 4 * group_index + 4) =
					(31 downto 4 * group_index + 4 => '0') then
					count := count or local_count;
				end if;
			end if;
		end loop;
		return count;
	end function;

	-- Only six low bits depend on the late priority result. Form the
	-- upper-word decrement from the registered offset in parallel.
	function bfffo_offset(base : std_logic_vector(31 downto 0);
		count : std_logic_vector(5 downto 0)) return std_logic_vector is
		variable low_difference : std_logic_vector(6 downto 0);
	begin
		-- synthesis translate_off
		if Is_X(base) then
			return base - count;
		end if;
		-- synthesis translate_on
		low_difference := ('0' & base(5 downto 0)) - ('0' & count);
		if low_difference(6) = '1' then
			return (base(31 downto 6) - 1) & low_difference(5 downto 0);
		end if;
		return To_X01(base(31 downto 6)) & low_difference(5 downto 0);
	end function;

	-- Exact six-bit count tables avoid serial compare/subtract depth.
	-- Complementary right counts are evaluated directly, not after a modulo.
	-- Non-binary simulation counts retain the original arithmetic fallback.
	subtype shift_count6 is std_logic_vector(5 downto 0);
	function shift_mod9(value : shift_count6; complement : boolean := false) return shift_count6 is
		variable reduced : shift_count6;
	begin
		case value is
			when "000000" | "001001" | "010010" | "011011" | "100100" | "101101" | "110110" | "111111" => if complement then return "001001"; else return "000000"; end if;
			when "000001" | "001010" | "010011" | "011100" | "100101" | "101110" | "110111" => if complement then return "001000"; else return "000001"; end if;
			when "000010" | "001011" | "010100" | "011101" | "100110" | "101111" | "111000" => if complement then return "000111"; else return "000010"; end if;
			when "000011" | "001100" | "010101" | "011110" | "100111" | "110000" | "111001" => if complement then return "000110"; else return "000011"; end if;
			when "000100" | "001101" | "010110" | "011111" | "101000" | "110001" | "111010" => if complement then return "000101"; else return "000100"; end if;
			when "000101" | "001110" | "010111" | "100000" | "101001" | "110010" | "111011" => if complement then return "000100"; else return "000101"; end if;
			when "000110" | "001111" | "011000" | "100001" | "101010" | "110011" | "111100" => if complement then return "000011"; else return "000110"; end if;
			when "000111" | "010000" | "011001" | "100010" | "101011" | "110100" | "111101" => if complement then return "000010"; else return "000111"; end if;
			when "001000" | "010001" | "011010" | "100011" | "101100" | "110101" | "111110" => if complement then return "000001"; else return "001000"; end if;
			when others =>
				if value = 63 then reduced := "000000";
				elsif value > 53 then reduced := value - 54;
				elsif value > 44 then reduced := value - 45;
				elsif value > 35 then reduced := value - 36;
				elsif value > 26 then reduced := value - 27;
				elsif value > 17 then reduced := value - 18;
				elsif value > 8 then reduced := value - 9;
				else reduced := value;
				end if;
				if complement then return std_logic_vector(to_unsigned(9,6))-reduced;
				else return reduced; end if;
		end case;
	end function;
	function shift_mod17(value : shift_count6; complement : boolean := false) return shift_count6 is
		variable reduced : shift_count6;
	begin
		case value is
			when "000000" | "010001" | "100010" | "110011" => if complement then return "010001"; else return "000000"; end if;
			when "000001" | "010010" | "100011" | "110100" => if complement then return "010000"; else return "000001"; end if;
			when "000010" | "010011" | "100100" | "110101" => if complement then return "001111"; else return "000010"; end if;
			when "000011" | "010100" | "100101" | "110110" => if complement then return "001110"; else return "000011"; end if;
			when "000100" | "010101" | "100110" | "110111" => if complement then return "001101"; else return "000100"; end if;
			when "000101" | "010110" | "100111" | "111000" => if complement then return "001100"; else return "000101"; end if;
			when "000110" | "010111" | "101000" | "111001" => if complement then return "001011"; else return "000110"; end if;
			when "000111" | "011000" | "101001" | "111010" => if complement then return "001010"; else return "000111"; end if;
			when "001000" | "011001" | "101010" | "111011" => if complement then return "001001"; else return "001000"; end if;
			when "001001" | "011010" | "101011" | "111100" => if complement then return "001000"; else return "001001"; end if;
			when "001010" | "011011" | "101100" | "111101" => if complement then return "000111"; else return "001010"; end if;
			when "001011" | "011100" | "101101" | "111110" => if complement then return "000110"; else return "001011"; end if;
			when "001100" | "011101" | "101110" | "111111" => if complement then return "000101"; else return "001100"; end if;
			when "001101" | "011110" | "101111" => if complement then return "000100"; else return "001101"; end if;
			when "001110" | "011111" | "110000" => if complement then return "000011"; else return "001110"; end if;
			when "001111" | "100000" | "110001" => if complement then return "000010"; else return "001111"; end if;
			when "010000" | "100001" | "110010" => if complement then return "000001"; else return "010000"; end if;
			when others =>
				if value > 50 then reduced := value - 51;
				elsif value > 33 then reduced := value - 34;
				elsif value > 16 then reduced := value - 17;
				else reduced := value;
				end if;
				if complement then return std_logic_vector(to_unsigned(17,6))-reduced;
				else return reduced; end if;
		end case;
	end function;
	function shift_mod33(value : shift_count6; complement : boolean := false) return shift_count6 is
		variable reduced : shift_count6;
	begin
		case value is
			when "000000" | "100001" => if complement then return "100001"; else return "000000"; end if;
			when "000001" | "100010" => if complement then return "100000"; else return "000001"; end if;
			when "000010" | "100011" => if complement then return "011111"; else return "000010"; end if;
			when "000011" | "100100" => if complement then return "011110"; else return "000011"; end if;
			when "000100" | "100101" => if complement then return "011101"; else return "000100"; end if;
			when "000101" | "100110" => if complement then return "011100"; else return "000101"; end if;
			when "000110" | "100111" => if complement then return "011011"; else return "000110"; end if;
			when "000111" | "101000" => if complement then return "011010"; else return "000111"; end if;
			when "001000" | "101001" => if complement then return "011001"; else return "001000"; end if;
			when "001001" | "101010" => if complement then return "011000"; else return "001001"; end if;
			when "001010" | "101011" => if complement then return "010111"; else return "001010"; end if;
			when "001011" | "101100" => if complement then return "010110"; else return "001011"; end if;
			when "001100" | "101101" => if complement then return "010101"; else return "001100"; end if;
			when "001101" | "101110" => if complement then return "010100"; else return "001101"; end if;
			when "001110" | "101111" => if complement then return "010011"; else return "001110"; end if;
			when "001111" | "110000" => if complement then return "010010"; else return "001111"; end if;
			when "010000" | "110001" => if complement then return "010001"; else return "010000"; end if;
			when "010001" | "110010" => if complement then return "010000"; else return "010001"; end if;
			when "010010" | "110011" => if complement then return "001111"; else return "010010"; end if;
			when "010011" | "110100" => if complement then return "001110"; else return "010011"; end if;
			when "010100" | "110101" => if complement then return "001101"; else return "010100"; end if;
			when "010101" | "110110" => if complement then return "001100"; else return "010101"; end if;
			when "010110" | "110111" => if complement then return "001011"; else return "010110"; end if;
			when "010111" | "111000" => if complement then return "001010"; else return "010111"; end if;
			when "011000" | "111001" => if complement then return "001001"; else return "011000"; end if;
			when "011001" | "111010" => if complement then return "001000"; else return "011001"; end if;
			when "011010" | "111011" => if complement then return "000111"; else return "011010"; end if;
			when "011011" | "111100" => if complement then return "000110"; else return "011011"; end if;
			when "011100" | "111101" => if complement then return "000101"; else return "011100"; end if;
			when "011101" | "111110" => if complement then return "000100"; else return "011101"; end if;
			when "011110" | "111111" => if complement then return "000011"; else return "011110"; end if;
			when "011111" => if complement then return "000010"; else return "011111"; end if;
			when "100000" => if complement then return "000001"; else return "100000"; end if;
			when others =>
				if value > 32 then reduced := value - 33;
				else reduced := value;
				end if;
				if complement then return std_logic_vector(to_unsigned(33,6))-reduced;
				else return reduced; end if;
		end case;
	end function;
	function shift_right_mask(value : shift_count6; width : positive; bias : natural) return shift_count6 is
	begin
		case value is
			when "000000" => return std_logic_vector(to_unsigned(bias-(0 mod width),6));
			when "000001" => return std_logic_vector(to_unsigned(bias-(1 mod width),6));
			when "000010" => return std_logic_vector(to_unsigned(bias-(2 mod width),6));
			when "000011" => return std_logic_vector(to_unsigned(bias-(3 mod width),6));
			when "000100" => return std_logic_vector(to_unsigned(bias-(4 mod width),6));
			when "000101" => return std_logic_vector(to_unsigned(bias-(5 mod width),6));
			when "000110" => return std_logic_vector(to_unsigned(bias-(6 mod width),6));
			when "000111" => return std_logic_vector(to_unsigned(bias-(7 mod width),6));
			when "001000" => return std_logic_vector(to_unsigned(bias-(8 mod width),6));
			when "001001" => return std_logic_vector(to_unsigned(bias-(9 mod width),6));
			when "001010" => return std_logic_vector(to_unsigned(bias-(10 mod width),6));
			when "001011" => return std_logic_vector(to_unsigned(bias-(11 mod width),6));
			when "001100" => return std_logic_vector(to_unsigned(bias-(12 mod width),6));
			when "001101" => return std_logic_vector(to_unsigned(bias-(13 mod width),6));
			when "001110" => return std_logic_vector(to_unsigned(bias-(14 mod width),6));
			when "001111" => return std_logic_vector(to_unsigned(bias-(15 mod width),6));
			when "010000" => return std_logic_vector(to_unsigned(bias-(16 mod width),6));
			when "010001" => return std_logic_vector(to_unsigned(bias-(17 mod width),6));
			when "010010" => return std_logic_vector(to_unsigned(bias-(18 mod width),6));
			when "010011" => return std_logic_vector(to_unsigned(bias-(19 mod width),6));
			when "010100" => return std_logic_vector(to_unsigned(bias-(20 mod width),6));
			when "010101" => return std_logic_vector(to_unsigned(bias-(21 mod width),6));
			when "010110" => return std_logic_vector(to_unsigned(bias-(22 mod width),6));
			when "010111" => return std_logic_vector(to_unsigned(bias-(23 mod width),6));
			when "011000" => return std_logic_vector(to_unsigned(bias-(24 mod width),6));
			when "011001" => return std_logic_vector(to_unsigned(bias-(25 mod width),6));
			when "011010" => return std_logic_vector(to_unsigned(bias-(26 mod width),6));
			when "011011" => return std_logic_vector(to_unsigned(bias-(27 mod width),6));
			when "011100" => return std_logic_vector(to_unsigned(bias-(28 mod width),6));
			when "011101" => return std_logic_vector(to_unsigned(bias-(29 mod width),6));
			when "011110" => return std_logic_vector(to_unsigned(bias-(30 mod width),6));
			when "011111" => return std_logic_vector(to_unsigned(bias-(31 mod width),6));
			when "100000" => return std_logic_vector(to_unsigned(bias-(32 mod width),6));
			when "100001" => return std_logic_vector(to_unsigned(bias-(33 mod width),6));
			when "100010" => return std_logic_vector(to_unsigned(bias-(34 mod width),6));
			when "100011" => return std_logic_vector(to_unsigned(bias-(35 mod width),6));
			when "100100" => return std_logic_vector(to_unsigned(bias-(36 mod width),6));
			when "100101" => return std_logic_vector(to_unsigned(bias-(37 mod width),6));
			when "100110" => return std_logic_vector(to_unsigned(bias-(38 mod width),6));
			when "100111" => return std_logic_vector(to_unsigned(bias-(39 mod width),6));
			when "101000" => return std_logic_vector(to_unsigned(bias-(40 mod width),6));
			when "101001" => return std_logic_vector(to_unsigned(bias-(41 mod width),6));
			when "101010" => return std_logic_vector(to_unsigned(bias-(42 mod width),6));
			when "101011" => return std_logic_vector(to_unsigned(bias-(43 mod width),6));
			when "101100" => return std_logic_vector(to_unsigned(bias-(44 mod width),6));
			when "101101" => return std_logic_vector(to_unsigned(bias-(45 mod width),6));
			when "101110" => return std_logic_vector(to_unsigned(bias-(46 mod width),6));
			when "101111" => return std_logic_vector(to_unsigned(bias-(47 mod width),6));
			when "110000" => return std_logic_vector(to_unsigned(bias-(48 mod width),6));
			when "110001" => return std_logic_vector(to_unsigned(bias-(49 mod width),6));
			when "110010" => return std_logic_vector(to_unsigned(bias-(50 mod width),6));
			when "110011" => return std_logic_vector(to_unsigned(bias-(51 mod width),6));
			when "110100" => return std_logic_vector(to_unsigned(bias-(52 mod width),6));
			when "110101" => return std_logic_vector(to_unsigned(bias-(53 mod width),6));
			when "110110" => return std_logic_vector(to_unsigned(bias-(54 mod width),6));
			when "110111" => return std_logic_vector(to_unsigned(bias-(55 mod width),6));
			when "111000" => return std_logic_vector(to_unsigned(bias-(56 mod width),6));
			when "111001" => return std_logic_vector(to_unsigned(bias-(57 mod width),6));
			when "111010" => return std_logic_vector(to_unsigned(bias-(58 mod width),6));
			when "111011" => return std_logic_vector(to_unsigned(bias-(59 mod width),6));
			when "111100" => return std_logic_vector(to_unsigned(bias-(60 mod width),6));
			when "111101" => return std_logic_vector(to_unsigned(bias-(61 mod width),6));
			when "111110" => return std_logic_vector(to_unsigned(bias-(62 mod width),6));
			when "111111" => return std_logic_vector(to_unsigned(bias-(63 mod width),6));
			when others =>
				case width is
					when 8 => return std_logic_vector(to_unsigned(bias,6))-("000"&value(2 downto 0));
					when 16 => return std_logic_vector(to_unsigned(bias,6))-("00"&value(3 downto 0));
					when 32 => return std_logic_vector(to_unsigned(bias,6))-('0'&value(4 downto 0));
					when others => return std_logic_vector(to_unsigned(bias,6))-value;
				end case;
		end case;
	end function;

-----------------------------------------------------------------------------
-----------------------------------------------------------------------------
-- ALU and more
-----------------------------------------------------------------------------
-----------------------------------------------------------------------------
	signal OP1in				: std_logic_vector(31 downto 0);
	signal addsub_a			: std_logic_vector(31 downto 0);
	signal addsub_b			: std_logic_vector(31 downto 0);
	signal notaddsub_b		: std_logic_vector(33 downto 0);
	signal add_result			: std_logic_vector(33 downto 0);
	signal addsub_ofl			: std_logic_vector(2 downto 0);
	signal opaddsub			: bit;
	signal c_in					: std_logic_vector(3 downto 0);
	signal flag_z				: std_logic_vector(2 downto 0);
	signal op1_zero : std_logic_vector(2 downto 0);
	-- Z for flag branches whose ELSIF chain already excludes the MUL/DIV/logic/shift arms.
	signal sf2_rot, sf2_bs, sf2_chk2 : std_logic;
	signal bs_zero : std_logic_vector(2 downto 0);
	-- Reduce each operation before the wide result mux; preserve exact equality semantics.
	function result_zero(value : std_logic_vector(31 downto 0)) return std_logic_vector is
		variable z : std_logic_vector(2 downto 0) := "000";
	begin
		if value(7 downto 0)=X"00" then z(0):='1'; end if;
		if value(15 downto 0)=X"0000" then z(1):='1'; end if;
		if value=X"00000000" then z(2):='1'; end if;
		return z;
	end function;
	signal set_Flags			: std_logic_vector(3 downto 0);	--NZVC
	signal CCRin				: std_logic_vector(7 downto 0);
	signal last_Flags1		: std_logic_vector(3 downto 0);	--NZVC
    
--BCD
	signal bcd_pur				: std_logic_vector(9 downto 0);
	signal bcd_kor				: std_logic_vector(8 downto 0);
	signal halve_carry		: std_logic;
	signal Vflag_a				: std_logic;
	signal bcd_a_carry		: std_logic;
	signal bcd_a				: std_logic_vector(8 downto 0);
	signal result_mulu		: std_logic_vector(127 downto 0);
	signal result_div			: std_logic_vector(63 downto 0);
	signal result_div_pre	: std_logic_vector(31 downto 0);
	-- For sign-extended32 operands, reconstruct the exact unsigned128 product
	-- from one signed33 product. Upper correction remains exact but is unused
	-- by this ALU; low64 has no explicit sign-extension correction carry chain.
	function extended_product(a,b : std_logic_vector(63 downto 0)) return std_logic_vector is
		variable sa,sb : ieee.numeric_std.signed(32 downto 0);
		variable product : ieee.numeric_std.signed(65 downto 0);
		variable r : ieee.numeric_std.unsigned(127 downto 0);
	begin
		sa := ieee.numeric_std.signed(a(63)&a(31 downto 0));
		sb := ieee.numeric_std.signed(b(63)&b(31 downto 0));
		product := ieee.numeric_std."*"(sa,sb);
		r := ieee.numeric_std.unsigned(ieee.numeric_std.resize(product,128));
		if To_X01(a(63))='1' then
			r(127 downto 64) := ieee.numeric_std."+"(r(127 downto 64),ieee.numeric_std.unsigned(ieee.numeric_std.resize(sb,64)));
		end if;
		if To_X01(b(63))='1' then
			r(127 downto 64) := ieee.numeric_std."+"(r(127 downto 64),ieee.numeric_std.unsigned(ieee.numeric_std.resize(sa,64)));
		end if;
		return std_logic_vector(r);
	end function;
	signal set_mV_Flag		: std_logic;
	signal V_Flag				: bit;
	
	signal rot_rot				: std_logic;
	signal rot_lsb				: std_logic;
	signal rot_msb				: std_logic;
	signal rot_X				: std_logic;
	signal rot_C				: std_logic;
	signal rot_out				: std_logic_vector(31 downto 0);
	signal asl_VFlag			: std_logic;
	signal bit_bits			: std_logic_vector(1 downto 0);
	signal bit_number			: std_logic_vector(4 downto 0);
	signal bits_out			: std_logic_vector(31 downto 0);
	signal one_bit_in			: std_logic;
	signal bchg					: std_logic;
	signal bset					: std_logic;
	
	signal mulu_sign			: std_logic;
	signal mulu_signext		: std_logic_vector(16 downto 0);
	signal muls_msb			: std_logic;
	signal mulu_reg			: std_logic_vector(63 downto 0);
	signal FAsign				: std_logic;
	signal faktorA				: std_logic_vector(31 downto 0);
	signal faktorB				: std_logic_vector(31 downto 0);
	
	signal div_reg				: std_logic_vector(63 downto 0);
	signal div_quot			: std_logic_vector(63 downto 0);
	signal div_ovl				: std_logic;
	signal div_neg				: std_logic;
	signal div_bit				: std_logic;
	signal div_sub				: std_logic_vector(32 downto 0);
	signal div_over			: std_logic_vector(32 downto 0);
	signal nozero				: std_logic;
	signal div_qsign			: std_logic;
	signal dividend			: std_logic_vector(63 downto 0);
	signal divs					: std_logic;
	signal signedOP			: std_logic;
	signal OP1_sign			: std_logic;
	signal OP2_sign			: std_logic;
	signal OP2outext			: std_logic_vector(15 downto 0);

	signal in_offset			: std_logic_vector(5 downto 0);
	signal datareg				: std_logic_vector(31 downto 0);
	signal insert				: std_logic_vector(31 downto 0);
	signal bf_datareg			: std_logic_vector(31 downto 0);
	signal result				: std_logic_vector(39 downto 0);
	signal result_tmp			: std_logic_vector(39 downto 0);
	signal unshifted_bitmask: std_logic_vector(31 downto 0);
	signal bf_set1				: std_logic_vector(39 downto 0);
	signal inmux0				: std_logic_vector(39 downto 0);
	signal inmux1				: std_logic_vector(39 downto 0);
	signal inmux2				: std_logic_vector(39 downto 0);
	signal inmux3				: std_logic_vector(31 downto 0);
	signal shifted_bitmask	: std_logic_vector(39 downto 0);
	signal bitmaskmux0		: std_logic_vector(37 downto 0);
	signal bitmaskmux1		: std_logic_vector(35 downto 0);
	signal bitmaskmux2		: std_logic_vector(31 downto 0);
	signal bitmaskmux3		: std_logic_vector(31 downto 0);
	signal bf_set2				: std_logic_vector(31 downto 0);
	signal shift				: std_logic_vector(39 downto 0);
	signal bf_firstbit		: std_logic_vector(5 downto 0);

	signal bf_bset				: std_logic;
	signal bf_NFlag			: std_logic;
	signal bf_bchg				: std_logic;
	signal bf_ins				: std_logic;
	signal bf_exts				: std_logic;
	signal bf_fffo				: std_logic;
	signal bf_d32				: std_logic;
	signal bf_s32				: std_logic;
	signal index				: std_logic_vector(4 downto 0);
--	signal i						: integer range 0 to 31;
--	signal i						: integer range 0 to 31;
--	signal i						: std_logic_vector(5 downto 0);

	signal hot_msb				: std_logic_vector(33 downto 0);
	signal vector				: std_logic_vector(32 downto 0);
	signal result_bs			: std_logic_vector(65 downto 0);
	signal bit_nr				: std_logic_vector(5 downto 0);
	signal bit_msb				: std_logic_vector(5 downto 0);
	signal bs_shift			: std_logic_vector(5 downto 0);

	signal asl_over			: std_logic_vector(32 downto 0);
	signal asl_over_xor		: std_logic_vector(32 downto 0);
	signal asr_sign			: std_logic_vector(32 downto 0);
	signal msb					: std_logic;  
	signal ring					: std_logic_vector(5 downto 0);
	signal ALU					: std_logic_vector(31 downto 0);
	signal BSout				: std_logic_vector(31 downto 0);
	signal bs_V					: std_logic;  
	signal bs_C					: std_logic;  
	signal bs_X					: std_logic;  



	-- Normalize each count source before the register/immediate selection.
	-- The immediate and implicit-one paths only need their constant range.
	function normalize_shift(value : shift_count6; ring : shift_count6;
		rightward : boolean; simple_shift : boolean) return shift_count6 is
		variable wrapped, count : shift_count6;
	begin
		CASE ring IS
			WHEN "001001" => wrapped := shift_mod9(value);
			WHEN "010001" => wrapped := shift_mod17(value);
			WHEN "100001" => wrapped := shift_mod33(value);
			WHEN "001000" => wrapped := "000" & value(2 downto 0);
			WHEN "010000" => wrapped :=  "00" & value(3 downto 0);
			WHEN "100000" => wrapped :=   "0" & value(4 downto 0);
			WHEN OTHERS => wrapped := (OTHERS => '0');
		END CASE;

		count := wrapped(5 downto 0);
		IF rightward THEN  --right shift
			CASE ring IS
				WHEN "001001" => count := shift_mod9(value,true);
				WHEN "010001" => count := shift_mod17(value,true);
				WHEN "100001" => count := shift_mod33(value,true);
				WHEN "001000" => count := shift_right_mask(value,8,8);
				WHEN "010000" => count := shift_right_mask(value,16,16);
				WHEN "100000" => count := shift_right_mask(value,32,32);
				WHEN OTHERS => count := ring-wrapped;
			END CASE;
		END IF;
		IF simple_shift THEN --only shift
			IF rightward THEN  --right shift
				CASE ring IS
					WHEN "001000" => count := shift_right_mask(value,8,32);
					WHEN "010000" => count := shift_right_mask(value,16,32);
					WHEN "100000" => count := shift_right_mask(value,32,32);
					WHEN OTHERS => count := 32-wrapped;
				END CASE;
			END IF;
			IF value = ring THEN
				IF rightward THEN  --right shift
					count := 32-ring;
				ELSE
					count := ring;
				END IF;
			END IF;
			IF value > ring THEN
				IF rightward THEN  --right shift
					count := "000000";
				ELSE
					count := ring+1;
				END IF;
			END IF;
		END IF;

		return count;
	end function;


BEGIN
	-- Registered every clock (not only on clkena): every BFFFO input is a
	-- register that changes only on an enabled clock, so the count is exact
	-- whenever the previous clock was not enabled; bfffo_hold makes the
	-- parent guarantee that for the write-back. Cuts the regfile -> shift ->
	-- count -> offset subtract -> write-back cone at the count.
	PROCESS (clk)
	BEGIN
		IF rising_edge(clk) THEN
			bf_firstbit <= bfffo_count(datareg);
		END IF;
	END PROCESS;
	bfffo_hold <= '1' WHEN exec(opcBFwb)='1' AND bf_fffo='1' ELSE '0';
-----------------------------------------------------------------------------
-- set OP1in
-----------------------------------------------------------------------------
PROCESS (OP2out, reg_QB, opcode, OP1out, OP1in, exe_datatype, addsub_q, execOPC, exec,
			bcd_a, result_mulu, result_div, exe_condition, bf_shift, bf_ffo_offset, mulu_reg, BSout,
			Flags, FlagsSR, bits_out, exec_tas, rot_out, exe_opcode, result, bf_fffo, bf_firstbit, bf_datareg)
	BEGIN
		ALUout <= OP1in;
		ALUout(7) <= OP1in(7) OR exec_tas;
		IF exec(opcBFwb)='1' THEN
			ALUout <= result(31 downto 0);
			IF bf_fffo='1' THEN
				ALUout <= bfffo_offset(bf_ffo_offset, bf_firstbit);
			END IF;
		END IF;
		
		OP1in <= addsub_q;
		IF exec(opcABCD)='1' OR exec(opcSBCD)='1' THEN	
			OP1in(7 downto 0) <= bcd_a(7 downto 0);
		ELSIF exec(opcMULU)='1' AND MUL_Mode/=3 THEN
			IF MUL_Hardware=0 THEN
				IF exec(write_lowlong)='1' AND (MUL_Mode=1 OR MUL_Mode=2) THEN
					OP1in <= result_mulu(31 downto 0);	
				ELSE	
					OP1in <= result_mulu(63 downto 32);
				END IF;		
			ELSE
				IF exec(write_lowlong)='1' THEN --AND (MUL_Mode=1 OR MUL_Mode=2) THEN
					OP1in <= result_mulu(31 downto 0);	
				ELSE	
--					OP1in <= result_mulu(63 downto 32);
					OP1in <= mulu_reg(31 downto 0);
				END IF;
			END IF;
		ELSIF exec(opcDIVU)='1' AND DIV_Mode/=3 THEN
			IF exe_opcode(15)='1' OR DIV_Mode=0 THEN
--			IF exe_opcode(15)='1' THEN
				OP1in <= result_div(47 downto 32)&result_div(15 downto 0);	--word 
			ELSE		--64bit
				IF exec(write_reminder)='1' THEN
					OP1in <= result_div(63 downto 32);
				ELSE	
					OP1in <= result_div(31 downto 0);	
				END IF;
			END IF;
		ELSIF exec(opcOR)='1' THEN
			OP1in <= OP2out OR OP1out;
		ELSIF exec(opcAND)='1' THEN
			OP1in <= OP2out AND OP1out;
		ELSIF exec(opcScc)='1' THEN
			OP1in(7 downto 0) <= (others=>exe_condition); 
		ELSIF exec(opcEOR)='1' THEN
			OP1in <= OP2out XOR OP1out;
--		ELSIF exec(alu_move)='1' OR exec(exg)='1' THEN
		ELSIF exec(alu_move)='1' THEN
--			OP1in <= OP2out(31 downto 8)&(OP2out(7)OR exec_tas)&OP2out(6 downto 0);
			OP1in <= OP2out;
		ELSIF exec(opcROT)='1' THEN
			OP1in <= rot_out;
		ELSIF exec(exec_BS)='1' THEN
			OP1in <= BSout;
		ELSIF exec(opcSWAP)='1' THEN	
			OP1in <= OP1out(15 downto 0)& OP1out(31 downto 16);
		ELSIF exec(opcBITS)='1' THEN
			OP1in <= bits_out;	
		ELSIF exec(opcBF)='1' THEN
			OP1in <= bf_datareg;		--new bitfieldvector for bfins - for others the old bitfieldvector
		ELSIF exec(opcMOVESR)='1' THEN
			OP1in(7 downto 0) <= Flags;
			IF exe_opcode(9)='1' THEN
				OP1in(15 downto 8) <= "00000000";
			ELSE	
				OP1in(15 downto 8) <= FlagsSR;
			END IF;
		ELSIF exec(opcPACK)='1' THEN	
			OP1in(7 downto 0) <= addsub_q(11 downto 8) & addsub_q(3 downto 0);
		END IF;
	END PROCESS;
	
-----------------------------------------------------------------------------
-- result_zero(BSout) taken straight from the shifter output windows, without
-- the rotate/shift/size result mux in between. Each window is exactly the
-- set of result_bs bits that BSout(7:0)/(15:0)/(31:0) OR together for the
-- current rot_bits/size/direction; ASR of a negative operand also ORs in the
-- asr_sign fill. Size masking (BSout upper bits forced 0) is applied last.
-----------------------------------------------------------------------------
PROCESS (result_bs, rot_bits, exe_opcode, msb, asr_sign)
	variable w8, w16, w32 : boolean;
	impure function zr(hi, lo : integer) return boolean is
	begin
		return result_bs(hi downto lo) = (hi downto lo => '0');
	end function;
BEGIN
	w8 := true; w16 := true; w32 := true;
	IF rot_bits="11" THEN
		CASE exe_opcode(7 downto 6) IS
			WHEN "00" => w8 := zr(7,0) AND zr(15,8);
			WHEN "01"|"11" => w8 := zr(7,0) AND zr(23,16); w16 := zr(15,0) AND zr(31,16);
			WHEN OTHERS => w8 := zr(7,0) AND zr(39,32); w16 := zr(15,0) AND zr(47,32); w32 := zr(31,0) AND zr(63,32);
		END CASE;
	ELSIF rot_bits="10" THEN
		CASE exe_opcode(7 downto 6) IS
			WHEN "00" => w8 := zr(7,0) AND zr(16,9);
			WHEN "01"|"11" => w8 := zr(7,0) AND zr(24,17); w16 := zr(15,0) AND zr(32,17);
			WHEN OTHERS => w8 := zr(7,0) AND zr(40,33); w16 := zr(15,0) AND zr(48,33); w32 := zr(31,0) AND zr(64,33);
		END CASE;
	ELSIF exe_opcode(8)='0' THEN
		w8 := zr(39,32); w16 := zr(47,32); w32 := zr(63,32);
		IF rot_bits="00" AND msb='1' THEN
			w8 := w8 AND asr_sign(8 downto 1)=x"00";
			w16 := w16 AND asr_sign(16 downto 1)=x"0000";
			w32 := w32 AND asr_sign(32 downto 1)=x"00000000";
		END IF;
	ELSE
		w8 := zr(7,0); w16 := zr(15,0); w32 := zr(31,0);
	END IF;
	CASE exe_opcode(7 downto 6) IS
		WHEN "00" => w16 := w8; w32 := w8;
		WHEN "01"|"11" => w32 := w16;
		WHEN OTHERS => NULL;
	END CASE;
	bs_zero <= (0 => '0', 1 => '0', 2 => '0');
	IF w8 THEN bs_zero(0) <= '1'; END IF;
	IF w16 THEN bs_zero(1) <= '1'; END IF;
	IF w32 THEN bs_zero(2) <= '1'; END IF;
END PROCESS;

-----------------------------------------------------------------------------
-- op1_zero as a flat one-hot AND-OR of the same priority arms as OP1in
-- (each select already contains "no higher arm"), so the Z reduction of a slow
-- arm (barrel shifter) is not pushed through a 16-deep priority chain.
-----------------------------------------------------------------------------
PROCESS (exec, exe_opcode, addsub_q, bcd_a, result_mulu, mulu_reg, result_div, OP2out, OP1out,
	exe_condition, rot_out, BSout, bits_out, bf_datareg, Flags, FlagsSR)
	variable taken : boolean;
	variable z, zd : std_logic_vector(2 downto 0);
	procedure arm(sel : boolean; zv : std_logic_vector(2 downto 0)) is
	begin
		if sel AND NOT taken then z := z OR zv; end if;
		if sel then taken := true; end if;
	end procedure;
BEGIN
	taken := false;
	z := "000";
	arm(exec(opcABCD)='1' OR exec(opcSBCD)='1', result_zero(addsub_q(31 downto 8) & (bcd_a(7 downto 0))));
	IF MUL_Hardware=0 THEN
		IF exec(write_lowlong)='1' AND (MUL_Mode=1 OR MUL_Mode=2) THEN zd := result_zero(result_mulu(31 downto 0));
		ELSE zd := result_zero(result_mulu(63 downto 32)); END IF;
	ELSE
		IF exec(write_lowlong)='1' THEN zd := result_zero(result_mulu(31 downto 0));
		ELSE zd := result_zero(mulu_reg(31 downto 0)); END IF;
	END IF;
	arm(exec(opcMULU)='1' AND MUL_Mode/=3, zd);
	IF exe_opcode(15)='1' OR DIV_Mode=0 THEN zd := result_zero(result_div(47 downto 32)&result_div(15 downto 0));
	ELSIF exec(write_reminder)='1' THEN zd := result_zero(result_div(63 downto 32));
	ELSE zd := result_zero(result_div(31 downto 0)); END IF;
	arm(exec(opcDIVU)='1' AND DIV_Mode/=3, zd);
	arm(exec(opcOR)='1', result_zero(OP2out OR OP1out));
	arm(exec(opcAND)='1', result_zero(OP2out AND OP1out));
	arm(exec(opcScc)='1', result_zero(addsub_q(31 downto 8) & (std_logic_vector'(7 downto 0=>exe_condition))));
	arm(exec(opcEOR)='1', result_zero(OP2out XOR OP1out));
	arm(exec(alu_move)='1', result_zero(OP2out));
	arm(exec(opcROT)='1', result_zero(rot_out));
	arm(exec(exec_BS)='1', bs_zero);
	arm(exec(opcSWAP)='1', result_zero(OP1out(15 downto 0)& OP1out(31 downto 16)));
	arm(exec(opcBITS)='1', result_zero(bits_out));
	arm(exec(opcBF)='1', result_zero(bf_datareg));
	IF exe_opcode(9)='1' THEN zd := result_zero(addsub_q(31 downto 16) & ("00000000") & Flags);
	ELSE zd := result_zero(addsub_q(31 downto 16) & (FlagsSR) & Flags); END IF;
	arm(exec(opcMOVESR)='1', zd);
	arm(exec(opcPACK)='1', result_zero(addsub_q(31 downto 8) & (addsub_q(11 downto 8) & addsub_q(3 downto 0))));
	arm(true, result_zero(addsub_q));
	op1_zero <= z;
END PROCESS;

-----------------------------------------------------------------------------
-- Narrow Z flag for the ROT, BS and CHK2 flag branches. Inside each branch the
-- earlier ELSIF terms already force the MULU/DIVU/OR/AND/EOR (and ROT/BS/BITS/
-- SWAP/BF for CHK2) op1_zero arms false, so dropping them is exact and keeps
-- the barrel-shifter zero reduction off the CHK2 Flags(0)/(2) cone.
-----------------------------------------------------------------------------
PROCESS (exec, addsub_q, bcd_a, exe_condition, OP2out, Flags, FlagsSR, exe_opcode, exe_datatype, BSout, rot_out)
	variable z_pre : std_logic_vector(2 downto 0);
	variable pre : boolean;
	variable z_rot, z_bs, z_chk2 : std_logic_vector(2 downto 0);
	impure function zpick(z : std_logic_vector(2 downto 0)) return std_logic is
		variable fz : std_logic_vector(2 downto 0);
	begin
		fz := z;
		if exec(use_XZFlag)='1' AND Flags(2)='0' then fz := "000"; end if;
		if exe_datatype="00" then return fz(0);
		elsif exe_datatype="10" OR exec(opcCPMAW)='1' then return fz(2);
		else return fz(1);
		end if;
	end function;
BEGIN
	pre := true;
	z_pre := "000";
	IF exec(opcABCD)='1' OR exec(opcSBCD)='1' THEN
		z_pre := result_zero(addsub_q(31 downto 8) & (bcd_a(7 downto 0)));
	ELSIF exec(opcScc)='1' THEN
		z_pre := result_zero(addsub_q(31 downto 8) & (std_logic_vector'(7 downto 0=>exe_condition)));
	ELSIF exec(alu_move)='1' THEN
		z_pre := result_zero(OP2out);
	ELSE
		pre := false;
	END IF;
	IF pre THEN
		z_rot := z_pre; z_bs := z_pre; z_chk2 := z_pre;
	ELSE
		z_rot := result_zero(rot_out);
		z_bs := bs_zero;
		z_chk2 := result_zero(addsub_q);
		IF exec(opcMOVESR)='1' THEN
			z_chk2 := result_zero(addsub_q(31 downto 8) & (Flags));
			IF exe_opcode(9)='1' THEN
				z_chk2 := result_zero(addsub_q(31 downto 16) & ("00000000") & Flags);
			ELSE
				z_chk2 := result_zero(addsub_q(31 downto 16) & (FlagsSR) & Flags);
			END IF;
		ELSIF exec(opcPACK)='1' THEN
			z_chk2 := result_zero(addsub_q(31 downto 8) & (addsub_q(11 downto 8) & addsub_q(3 downto 0)));
		END IF;
	END IF;
	sf2_rot <= zpick(z_rot);
	sf2_bs <= zpick(z_bs);
	sf2_chk2 <= zpick(z_chk2);
END PROCESS;

-----------------------------------------------------------------------------
-- addsub
-----------------------------------------------------------------------------
PROCESS (OP1out, OP2out, execOPC, Flags, long_start, movem_presub, exe_datatype, exec, addsub_a, addsub_b, opaddsub,
	     notaddsub_b, add_result, c_in, sndOPC, non_aligned, check_aligned)
	BEGIN
		addsub_a <= OP1out;
		IF exec(get_bfoffset)='1' THEN	
			IF sndOPC(11)='1' THEN
				addsub_a <= OP1out(31)&OP1out(31)&OP1out(31)&OP1out(31 downto 3);
			ELSE
				addsub_a <= "000000000000000000000000000000"&sndOPC(10 downto 9);
			END IF;	
		END IF;
		
		IF exec(subidx)='1' THEN
			opaddsub <= '1';
		ELSE
			opaddsub <= '0';
		END IF;
		
		c_in(0) <='0';
		addsub_b <= OP2out;
		IF exec(opcUNPACK)='1' THEN
			addsub_b(15 downto 0) <= "0000" & OP2out(7 downto 4) & "0000" & OP2out(3 downto 0);
		ELSIF execOPC='0' AND exec(OP2out_one)='0' AND exec(get_bfoffset)='0'THEN
			IF long_start='0' AND exe_datatype="00" AND exec(use_SP)='0' THEN
				addsub_b <= "00000000000000000000000000000001";
			ELSIF long_start='0' AND exe_datatype="10" AND (exec(presub) OR exec(postadd) OR movem_presub)='1' THEN
				IF exec(movem_action)='1' THEN
					addsub_b <= "00000000000000000000000000000110";
				ELSE
					addsub_b <= "00000000000000000000000000000100";
				END IF;
			ELSE 
				addsub_b <= "00000000000000000000000000000010";
			END IF;
		ELSE	
			IF (exec(use_XZFlag)='1' AND Flags(4)='1') OR exec(opcCHK)='1' THEN 
				c_in(0) <= '1';
			END IF;
			opaddsub <= exec(addsub);
		END IF;

		-- patch for un-aligned movem --mikej
		if exec(movem_action)='1' OR check_aligned='1' then
		  if (movem_presub = '0') then -- up
			if (non_aligned = '1') and (long_start = '0') then -- hold
			  addsub_b <= (others => '0');
			end if;
		  else
			if (non_aligned = '1') and (long_start = '0') then
			  if (exe_datatype = "10") then
				addsub_b <= "00000000000000000000000000001000";
			  else
				addsub_b <= "00000000000000000000000000000100";
			  end if;
			end if;
		  end if;
		end if;

		IF opaddsub='0' OR long_start='1' THEN		--ADD
			notaddsub_b <= '0'&addsub_b&c_in(0);
		ELSE					--SUB
			notaddsub_b <= NOT ('0'&addsub_b&c_in(0));
		END IF;
		add_result <= (('0'&addsub_a&notaddsub_b(0))+notaddsub_b);
		c_in(1) <= add_result(9) XOR addsub_a(8) XOR addsub_b(8);
		c_in(2) <= add_result(17) XOR addsub_a(16) XOR addsub_b(16);
		c_in(3) <= add_result(33);
		addsub_q <= add_result(32 downto 1); 
		addsub_ofl(0) <= (c_in(1) XOR add_result(8) XOR addsub_a(7) XOR addsub_b(7));		--V Byte
		addsub_ofl(1) <= (c_in(2) XOR add_result(16) XOR addsub_a(15) XOR addsub_b(15));	--V Word
		addsub_ofl(2) <= (c_in(3) XOR add_result(32) XOR addsub_a(31) XOR addsub_b(31));	--V Long
		c_out <= c_in(3 downto 1);
	END PROCESS;
	
------------------------------------------------------------------------------
--ALU
------------------------------------------------------------------------------		
PROCESS (OP1out, OP2out, CPU, exec, add_result, bcd_pur, bcd_a, bcd_kor, halve_carry, c_in)
	BEGIN
--BCD_ARITH-------------------------------------------------------------------
--04.04.2017 by Tobiflex - BCD handling with all undefined behavior!
		bcd_pur <= c_in(1)&add_result(8 downto 0);
		bcd_kor <= "000000000";
		halve_carry <= OP1out(4) XOR OP2out(4) XOR bcd_pur(5); 
		IF halve_carry='1' THEN
			bcd_kor(3 downto 0) <= "0110"; --  -6
		END IF;
		IF bcd_pur(9)='1' THEN
			bcd_kor(7 downto 4) <= "0110"; --  -60
		END IF;
		IF exec(opcABCD)='1' THEN	
			Vflag_a <= NOT bcd_pur(8) AND bcd_a(7); 
--			bcd_pur <= ('0'&OP1out(7 downto 0)&'1') + ('0'&OP2out(7 downto 0)&Flags(4));
			bcd_a <= bcd_pur(9 downto 1) + bcd_kor;
			IF (bcd_pur(4) AND (bcd_pur(3) OR bcd_pur(2)))='1' THEN
				bcd_kor(3 downto 0) <= "0110"; --  +6
			END IF;
			IF (bcd_pur(8) AND (bcd_pur(7) OR bcd_pur(6) OR (bcd_pur(5) AND bcd_pur(4) AND (bcd_pur(3) OR bcd_pur(2)))))='1' THEN
				bcd_kor(7 downto 4) <= "0110"; --  +60 
			END IF;
		ELSE --opcSBCD	
			Vflag_a <= bcd_pur(8) AND NOT bcd_a(7); 
--			bcd_pur <= ('0'&OP1out(7 downto 0)&'0') - ('0'&OP2out(7 downto 0)&Flags(4));
			bcd_a <= bcd_pur(9 downto 1) - bcd_kor;
		END IF;
		IF cpu(1)='1' THEN
			Vflag_a <= '0'; --68020
		END IF;
		bcd_a_carry <= bcd_pur(9) OR bcd_a(8);
	END PROCESS;
			
-----------------------------------------------------------------------------
-- Bits
-----------------------------------------------------------------------------
PROCESS (clk, exe_opcode, OP1out, OP2out, reg_QB, one_bit_in, bchg, bset, bit_Number, sndOPC)
	BEGIN
		IF rising_edge(clk) THEN		
	        IF  clkena_lw = '1' THEN
				bchg <= '0';
				bset <= '0';
				CASE opcode(7 downto 6) IS
					WHEN "01" =>					--bchg
						bchg <= '1';
					WHEN "11" =>					--bset
						bset <= '1';
					WHEN OTHERS => NULL;			
				END CASE;
			END IF;
		END IF;		
		
		IF exe_opcode(8)='0' THEN
			IF exe_opcode(5 downto 4)="00" THEN
				bit_number <= sndOPC(4 downto 0);
			ELSE
				bit_number <= "00"&sndOPC(2 downto 0);
			END IF;
		ELSE
			IF exe_opcode(5 downto 4)="00" THEN
				bit_number <= reg_QB(4 downto 0);
			ELSE
				bit_number <= "00"&reg_QB(2 downto 0);
			END IF;
		END IF;
						
		one_bit_in <= OP1out(conv_integer(bit_Number));
		bits_out <= OP1out;
		bits_out(conv_integer(bit_Number)) <= (bchg AND NOT one_bit_in) OR bset ;
	END PROCESS;

-----------------------------------------------------------------------------
-- Bit Field
-----------------------------------------------------------------------------	

PROCESS (clk, bf_ins, bf_bchg, bf_bset, bf_exts, bf_shift, inmux0, inmux1, inmux2, inmux3, bf_set2, OP1out, OP2out, 
			result_tmp, bf_ext_in, exec, shift, datareg, bf_NFlag, result, reg_QB, unshifted_bitmask, bf_d32, bf_s32, 
			shifted_bitmask, bf_loffset, bitmaskmux0, bitmaskmux1, bitmaskmux2, bitmaskmux3, bf_width)
	BEGIN
		IF rising_edge(clk) THEN		
			IF clkena_lw = '1' THEN
				bf_bset <= '0';
				bf_bchg <= '0';
				bf_ins <= '0';
				bf_exts <= '0';
				bf_fffo <= '0';
				bf_d32 <= '0';
				bf_s32 <= '0';
--		000-bftst, 001-bfextu, 010-bfchg, 011-bfexts, 100-bfclr, 101-bfff0, 110-bfset, 111-bfins	
				IF opcode(5 downto 4) ="00" THEN
					  bf_s32 <= '1';
				END IF;
				CASE opcode(10 downto 8) IS
					WHEN "010" => bf_bchg <= '1';					--BFCHG
					WHEN "011" => bf_exts <= '1';					--BFEXTS
--					WHEN "100" => insert <= (OTHERS =>'0');	--BFCLR
					WHEN "101" => bf_fffo <= '1';					--BFFFO
					WHEN "110" => bf_bset <= '1';					--BFSET
					WHEN "111" => bf_ins <= '1';					--BFINS
									  bf_s32 <= '1';
					WHEN OTHERS => NULL;
				END CASE;
				IF opcode(4 downto 3)="00" THEN
					bf_d32 <= '1';
				END IF;
				bf_ext_out <= result(39 downto 32);
			END IF;
		END IF;
		
		IF bf_ins='1' THEN
			datareg <= reg_QB;
		ELSE
			datareg <= bf_set2;
		END IF;
		
		
-- create bitmask for operation
-- unshifted bitmask '0' => bit is in the Bitfieldvector
--					 '1' => bit isn't in the Bitfieldvector
-- Example bf_with=11    => "11111111 11111111 11111000 00000000"
-- datareg 
		unshifted_bitmask <= (OTHERS => '0'); 
		FOR i in 0 to 31 LOOP
			IF i>bf_width(4 downto 0) THEN
				datareg(i) <= '0'; 
				unshifted_bitmask(i) <= '1'; 			 
			END IF;	
		END LOOP;
		
		bf_NFlag <= datareg(conv_integer(bf_width));
		IF bf_exts='1' AND bf_NFlag='1' THEN
			bf_datareg <= datareg OR unshifted_bitmask;
		ELSE	
			bf_datareg <= datareg;
		END IF;	
		
-- shift bitmask for operation
		IF bf_loffset(4)='1' THEN 
			bitmaskmux3 <= unshifted_bitmask(15 downto 0)&unshifted_bitmask(31 downto 16);
		ELSE	
			bitmaskmux3 <= unshifted_bitmask;
		END IF;
		IF bf_loffset(3)='1' THEN 
			bitmaskmux2(31 downto 0) <= bitmaskmux3(23 downto 0)&bitmaskmux3(31 downto 24);
		ELSE	
			bitmaskmux2(31 downto 0) <= bitmaskmux3;
		END IF;
		IF bf_loffset(2)='1' THEN 
			bitmaskmux1 <= bitmaskmux2&"1111";
			IF bf_d32='1' THEN 
				bitmaskmux1(3 downto 0) <= bitmaskmux2(31 downto 28);
			END IF;
		ELSE	
			bitmaskmux1 <= "1111"&bitmaskmux2;
		END IF;
		IF bf_loffset(1)='1' THEN 
			bitmaskmux0 <= bitmaskmux1&"11";
			IF bf_d32='1' THEN 
				bitmaskmux0(1 downto 0) <= bitmaskmux1(31 downto 30);
			END IF;
		ELSE
			bitmaskmux0 <= "11"&bitmaskmux1;
		END IF;
		IF bf_loffset(0)='1' THEN 
			shifted_bitmask <= '1'&bitmaskmux0&'1';
			IF bf_d32='1' THEN 
				shifted_bitmask(0) <= bitmaskmux0(31);
			END IF;
		ELSE
			shifted_bitmask <= "11"&bitmaskmux0;
		END IF;
		
		
-- shift for ins 
		shift <= bf_ext_in&OP2out;
		IF bf_s32='1' THEN 
			shift(39 downto 32) <= OP2out(7 downto 0);
		END IF;
			
		IF bf_shift(0)='1' THEN 
			inmux0 <= shift(0)&shift(39 downto 1);
		ELSE	
			inmux0 <= shift;
		END IF;
		IF bf_shift(1)='1' THEN 
			inmux1 <= inmux0(1 downto 0)&inmux0(39 downto 2);
		ELSE
			inmux1 <= inmux0;
		END IF;
		IF bf_shift(2)='1' THEN 
			inmux2 <= inmux1(3 downto 0)&inmux1(39 downto 4);
		ELSE	
			inmux2 <= inmux1;
		END IF;
		IF bf_shift(3)='1' THEN 
			inmux3 <= inmux2(7 downto 0)&inmux2(31 downto 8);
		ELSE	
			inmux3 <= inmux2(31 downto 0);
		END IF;
		IF bf_shift(4)='1' THEN 
			bf_set2(31 downto 0) <= inmux3(15 downto 0)&inmux3(31 downto 16);
		ELSE	
			bf_set2(31 downto 0) <= inmux3;
		END IF;
		
		IF bf_ins='1' THEN
			result(31 downto 0) <= bf_set2;
			result(39 downto 32) <= bf_set2(7 downto 0);
		ELSIF bf_bchg='1' THEN
			result(31 downto 0) <= NOT OP2out;
			result(39 downto 32) <= NOT bf_ext_in;
		ELSE	
			result <= (OTHERS => '0');
		END IF;
		IF bf_bset='1' THEN
			result <= (OTHERS => '1');
		END IF;
-- 		
		IF bf_ins='1' THEN
			result_tmp <= bf_ext_in&OP1out;
		ELSE	
			result_tmp <= bf_ext_in&OP2out;
		END IF;
		FOR i in 0 to 39 LOOP
			IF shifted_bitmask(i)='1' THEN	
				result(i) <= result_tmp(i);   --restore old data
			END IF;	
		END LOOP;
		
	END PROCESS;

-----------------------------------------------------------------------------
-- Rotation
-----------------------------------------------------------------------------
PROCESS (exe_opcode, OP1out, Flags, rot_bits, rot_msb, rot_lsb, rot_rot, exec, BSout)
	BEGIN
		CASE exe_opcode(7 downto 6) IS
			WHEN "00" =>					--Byte
						rot_rot <= OP1out(7);
			WHEN "01"|"11" =>				--Word
						rot_rot <= OP1out(15);
			WHEN "10" =>					--Long
						rot_rot <= OP1out(31);
			WHEN OTHERS => NULL;
		END CASE;
	
		CASE rot_bits IS
			WHEN "00" =>					--ASL, ASR
						rot_lsb <= '0';
						rot_msb <= rot_rot;
			WHEN "01" =>					--LSL, LSR
						rot_lsb <= '0';
						rot_msb <= '0';
			WHEN "10" =>					--ROXL, ROXR
						rot_lsb <= Flags(4);
						rot_msb <= Flags(4);
			WHEN "11" =>					--ROL, ROR
						rot_lsb <= rot_rot;
						rot_msb <= OP1out(0);
			WHEN OTHERS => NULL;
		END CASE;
	
		IF exec(rot_nop)='1' THEN
			rot_out <= OP1out;
			rot_X <= Flags(4);
			IF rot_bits="10" THEN	--ROXL, ROXR
				rot_C <= Flags(4);
			ELSE	
				rot_C <= '0';
			END IF;
		ELSE
			IF exe_opcode(8)='1' THEN		--left
				rot_out <= OP1out(30 downto 0)&rot_lsb;
				rot_X <= rot_rot;
				rot_C <= rot_rot;
			ELSE						--right
				rot_X <= OP1out(0);
				rot_C <= OP1out(0);
				rot_out <= rot_msb&OP1out(31 downto 1);
				CASE exe_opcode(7 downto 6) IS
					WHEN "00" =>					--Byte
						rot_out(7) <= rot_msb;
					WHEN "01"|"11" =>				--Word
						rot_out(15) <= rot_msb;
					WHEN OTHERS => NULL;	
				END CASE;
			END IF;
			IF BarrelShifter/=0 THEN
			   rot_out <= BSout;
			END IF;
		END IF;
	END PROCESS;
		
-----------------------------------------------------------------------------
-- Barrel Shifter
-----------------------------------------------------------------------------	
process (OP1out, OP2out, opcode, bit_nr, bit_msb, bs_shift, ring, result_bs, exe_opcode, vector, 
         rot_bits, Flags, bs_C, msb, hot_msb, asl_over, asl_over_xor, ALU, asr_sign, exec)
	begin
		ring <= "100000";
		IF rot_bits="10" THEN --ROX L/R
			CASE exe_opcode(7 downto 6) IS
				WHEN "00" =>					--Byte
							ring <= "001001";
				WHEN "01"|"11" =>				--Word
							ring <= "010001";
				WHEN "10" =>					--Long
							ring <= "100001";
				WHEN OTHERS => NULL;
			END CASE;
		ELSE
			CASE exe_opcode(7 downto 6) IS
				WHEN "00" =>					--Byte
							ring <= "001000";
				WHEN "01"|"11" =>				--Word
							ring <= "010000";
				WHEN "10" =>					--Long
							ring <= "100000";
				WHEN OTHERS => NULL;
			END CASE;
		END IF;	
		
		IF exe_opcode(7 downto 6)="11" OR exec(exec_BS)='0' THEN
			bs_shift <="000001";
		ELSIF exe_opcode(5)='1' THEN
			bs_shift <= OP2out(5 downto 0);
		ELSE
			bs_shift(2 downto 0) <= exe_opcode(11 downto 9);
			IF exe_opcode(11 downto 9)="000" THEN
				bs_shift(5 downto 3) <="001";
			ELSE
				bs_shift(5 downto 3) <="000";
			END IF;
		END IF;

-- calc V-Flag by ASL		
		bit_msb <= "000000";
		hot_msb <= (OTHERS =>'0');
		hot_msb(conv_integer(bit_msb)) <= '1';
		IF bs_shift < ring THEN
			bit_msb <= ring-bs_shift;
		END IF;
		asl_over_xor <= (('0'&vector(30 downto 0)) XOR ('0'&vector(31 downto 1)))&msb;
		CASE exe_opcode(7 downto 6) IS
			WHEN "00" =>					--Byte
				asl_over_xor(8) <= '0';
			WHEN "01"|"11" =>				--Word
				asl_over_xor(16) <= '0';
			WHEN OTHERS => NULL;
		END CASE;
		asl_over <= asl_over_xor - ('0'&hot_msb(31 downto 0));	
		bs_V <= '0';
		IF rot_bits="00" AND exe_opcode(8)='1' THEN --ASL
			bs_V <= not asl_over(32);
		END IF;
		
		bs_X <= bs_C;
		IF exe_opcode(8)='0' THEN --right shift
			bs_C <= result_bs(31);
		ELSE                  --left shift
			CASE exe_opcode(7 downto 6) IS
				WHEN "00" =>					--Byte
					bs_C <= result_bs(8);
				WHEN "01"|"11" =>				--Word
					bs_C <= result_bs(16);
				WHEN "10" =>					--Long
					bs_C <= result_bs(32);
				WHEN OTHERS => NULL;
			END CASE;
		END IF;
		
		ALU <= (others=>'-');
		IF rot_bits="11" THEN --RO L/R
			bs_X <= Flags(4);
			CASE exe_opcode(7 downto 6) IS
				WHEN "00" =>					--Byte
					ALU(7 downto 0) <= result_bs(7 downto 0) OR result_bs(15 downto 8);
					bs_C <= ALU(7);
				WHEN "01"|"11" =>				--Word
					ALU(15 downto 0) <= result_bs(15 downto 0) OR result_bs(31 downto 16);
					bs_C <= ALU(15);
				WHEN "10" =>					--Long
					ALU <= result_bs(31 downto 0) OR result_bs(63 downto 32);
					bs_C <= ALU(31);
				WHEN OTHERS => NULL;
			END CASE;
			IF exe_opcode(8)='1' THEN --left shift
				bs_C <= ALU(0);
			END IF;
		ELSIF rot_bits="10" THEN --ROX L/R
			CASE exe_opcode(7 downto 6) IS
				WHEN "00" =>					--Byte
					ALU(7 downto 0) <= result_bs(7 downto 0) OR result_bs(16 downto 9);
					bs_C <= result_bs(8) OR result_bs(17);
				WHEN "01"|"11" =>				--Word
					ALU(15 downto 0) <= result_bs(15 downto 0) OR result_bs(32 downto 17);
					bs_C <= result_bs(16) OR result_bs(33);
				WHEN "10" =>					--Long
					ALU <= result_bs(31 downto 0) OR result_bs(64 downto 33);
					bs_C <= result_bs(32) OR result_bs(65);
				WHEN OTHERS => NULL;
			END CASE;
		ELSE
			IF exe_opcode(8)='0' THEN --right shift
				ALU <= result_bs(63 downto 32);
			ELSE                  --left shift
				ALU <= result_bs(31 downto 0);
			END IF;
		END IF;
		
		IF(bs_shift = "000000") THEN
			IF rot_bits="10" THEN --ROX L/R
				bs_C <= Flags(4);
			ELSE
				bs_C <= '0';
			END IF;
			bs_X <= Flags(4);
			bs_V <= '0';
		END IF;

-- Select the normalized count late on the GPR-to-shifter path.
		IF exe_opcode(7 downto 6)="11" OR exec(exec_BS)='0' THEN
			bit_nr <= normalize_shift("000001", ring, exe_opcode(8)='0', rot_bits(1)='0');
		ELSIF exe_opcode(5)='1' THEN
			bit_nr <= normalize_shift(OP2out(5 downto 0), ring, exe_opcode(8)='0', rot_bits(1)='0');
		ELSIF exe_opcode(11 downto 9)="000" THEN
			bit_nr <= normalize_shift("001000", ring, exe_opcode(8)='0', rot_bits(1)='0');
		ELSE
			bit_nr <= normalize_shift("000" & exe_opcode(11 downto 9), ring, exe_opcode(8)='0', rot_bits(1)='0');
		END IF;
		IF rot_bits(1)='0' AND exe_opcode(8)='0' AND bs_shift > ring THEN
			bs_C <= '0';
		END IF;

-- calc ASR sign		
		BSout <= ALU;
		asr_sign <= (OTHERS =>'0');	
		asr_sign(32 downto 1) <= asr_sign(31 downto 0) OR hot_msb(31 downto 0);	
		IF rot_bits="00" AND exe_opcode(8)='0' AND msb='1' THEN --ASR
			BSout <= ALU or asr_sign(32 downto 1);
			IF bs_shift > ring THEN
				bs_C <= '1';
			END IF;
		END IF;

		vector(32 downto 0) <= '0'&OP1out;
		CASE exe_opcode(7 downto 6) IS
			WHEN "00" =>					--Byte
				msb <= OP1out(7);
				vector(31 downto 8) <= X"000000";
				BSout(31 downto 8) <= X"000000";
				IF rot_bits="10" THEN --ROX L/R
					vector(8) <= Flags(4);
				END IF;
			WHEN "01"|"11" =>				--Word
				msb <= OP1out(15);
				vector(31 downto 16) <= X"0000";
				BSout(31 downto 16) <= X"0000";
				IF rot_bits="10" THEN --ROX L/R
					vector(16) <= Flags(4);
				END IF;
			WHEN "10" =>					--Long
				msb <= OP1out(31);
				IF rot_bits="10" THEN --ROX L/R
					vector(32) <= Flags(4);
				END IF;
			WHEN OTHERS => NULL;
		END CASE;
		result_bs <= std_logic_vector(unsigned('0'&X"00000000"&vector) sll to_integer(unsigned(bit_nr(5 downto 0)))); 

  end process;

  
------------------------------------------------------------------------------
--CCR op
------------------------------------------------------------------------------		
PROCESS (clk, Reset, exe_opcode, exe_datatype, Flags, last_data_read, OP2out, flag_z, OP1IN, c_out, addsub_ofl,
	     bcd_a, bcd_a_carry, Vflag_a, exec, op1_zero)
	BEGIN
		IF exec(andiSR)='1' THEN
			CCRin <= Flags AND last_data_read(7 downto 0);
		ELSIF exec(eoriSR)='1' THEN
			CCRin <= Flags XOR last_data_read(7 downto 0);
		ELSIF exec(oriSR)='1' THEN
			CCRin <= Flags OR last_data_read(7 downto 0);
		ELSE	
			CCRin <= OP2out(7 downto 0);
		END IF;	
		
------------------------------------------------------------------------------
--Flags
------------------------------------------------------------------------------		
		flag_z <= op1_zero;
		IF exec(use_XZFlag)='1' AND flags(2)='0' THEN
			flag_z <= "000";
		END IF;
		
--					--Flags NZVC
		IF exe_datatype="00" THEN 						--Byte
			set_flags <= OP1IN(7)&flag_z(0)&addsub_ofl(0)&c_out(0);
			IF exec(opcABCD)='1' OR exec(opcSBCD)='1' THEN	
				set_flags(0) <= bcd_a_carry;
				set_flags(1) <= Vflag_a;
			END IF;
		ELSIF exe_datatype="10" OR exec(opcCPMAW)='1' THEN 						--Long
			set_flags <= OP1IN(31)&flag_z(2)&addsub_ofl(2)&c_out(2);
		ELSE 						--Word
			set_flags <= OP1IN(15)&flag_z(1)&addsub_ofl(1)&c_out(1);
		END IF;
		
		IF rising_edge(clk) THEN		
			IF Reset='1' THEN
				Flags(7 downto 0) <= "00000000"; 
			ELSIF clkena_lw = '1' THEN
				IF exec(directSR)='1' OR set_stop='1' THEN
					Flags(7 downto 0) <= data_read(7 downto 0);
				END IF;	
				IF exec(directCCR)='1' THEN
					Flags(7 downto 0) <= data_read(7 downto 0);
				END IF;	
				
				IF exec(opcROT)='1' AND decodeOPC='0' THEN
					asl_VFlag <= ((set_flags(3) XOR rot_rot) OR asl_VFlag);	
				ELSE	
					asl_VFlag <= '0';
				END IF;	
				IF exec(to_CCR)='1' THEN
					Flags(7 downto 0) <= CCRin(7 downto 0);			--CCR
				ELSIF Z_error='1' THEN
					IF micro_state = trap0 THEN
						-- Undocumented behavior (flags when div by zero)
						IF exe_opcode(8)='0' THEN
--						Flags(3 downto 0) <= reg_QA(31)&"000";
							Flags(3 downto 0) <= '0'&NOT reg_QA(31)&"00";
						ELSE
							Flags(3 downto 0) <= "0100";
						END IF;
					END IF;
				ELSIF exec(no_Flags)='0' THEN
					last_Flags1 <= Flags(3 downto 0);
					IF exec(opcADD)='1' THEN
						Flags(4) <= set_flags(0);
					ELSIF exec(opcROT)='1' AND rot_bits/="11" AND exec(rot_nop)='0' THEN
						Flags(4) <= rot_X; 	
					ELSIF exec(exec_BS)='1' THEN
						Flags(4) <= BS_X; 	
					END IF;
					
					IF (exec(opcCMP) OR exec(alu_setFlags))='1' THEN
						Flags(3 downto 0) <= set_flags;
					ELSIF exec(opcDIVU)='1' AND DIV_Mode/=3 THEN
						IF V_Flag='1' THEN	
							Flags(3 downto 0) <= "1010";
						ELSIF exe_opcode(15)='1' OR DIV_Mode=0 THEN
							Flags(3 downto 0) <= OP1IN(15)&flag_z(1)&"00";
						ELSE
							Flags(3 downto 0) <= OP1IN(31)&flag_z(2)&"00";
						END IF;
					ELSIF exec(write_reminder)='1' AND MUL_Mode/=3 THEN -- z-flag MULU.l
						Flags(3) <= set_flags(3);
						Flags(2) <= set_flags(2) AND Flags(2);
						Flags(1) <= '0';
						Flags(0) <= '0';
					ELSIF exec(write_lowlong)='1' AND (MUL_Mode=1 OR MUL_Mode=2) THEN  -- flag MULU.l
						Flags(3) <= set_flags(3);
						Flags(2) <= set_flags(2);
						Flags(1) <= set_mV_Flag;	--V
						Flags(0) <= '0';
					ELSIF exec(opcOR)='1' OR exec(opcAND)='1' OR exec(opcEOR)='1' OR exec(opcMOVE)='1' OR exec(opcMOVEQ)='1' OR exec(opcSWAP)='1' OR exec(opcBF)='1' OR (exec(opcMULU)='1' AND MUL_Mode/=3) THEN
						Flags(1 downto 0) <= "00";
						Flags(3 downto 2) <= set_flags(3 downto 2);
						IF exec(opcBF)='1' THEN
							Flags(3) <= bf_NFlag;
						END IF;	
					ELSIF exec(opcROT)='1' THEN
						Flags(3) <= set_flags(3);
						Flags(2) <= sf2_rot;
						Flags(0) <= rot_C;
						IF rot_bits="00" AND ((set_flags(3) XOR rot_rot) OR asl_VFlag)='1' THEN		--ASL/ASR
							Flags(1) <= '1';
						ELSE		
							Flags(1) <= '0';
						END IF;	
					ELSIF exec(exec_BS)='1' THEN
						Flags(3) <= set_flags(3);
						Flags(2) <= sf2_bs;
						Flags(0) <= BS_C;
						Flags(1) <= BS_V;
					ELSIF exec(opcBITS)='1' THEN
						Flags(2) <= NOT one_bit_in;	
					ELSIF exec(opcCHK2)='1' THEN		--micro_state = chk23
--micro_state	 chk21   chk22   chk23
--OP1out      		UB		R			R
--OP2out				LB		LB			UB					
----lower bound first
						IF last_Flags1(0)='0' THEN			--unsigned OP
							Flags(0) <= Flags(0) OR (NOT set_flags(0) AND NOT sf2_chk2);
						ELSE										--signed OP
							Flags(0) <= (Flags(0) XOR set_flags(0)) AND  NOT Flags(2) AND NOT sf2_chk2;
						END IF;
						Flags(1) <= '0';
						Flags(2) <= Flags(2) OR sf2_chk2;
						Flags(3) <= NOT last_Flags1(0); 
					ELSIF exec(opcCHK)='1' THEN
						IF exe_datatype="01" THEN 						--Word
							Flags(3) <= OP1out(15);
						ELSE	
							Flags(3) <= OP1out(31);
						END IF;	
						IF OP1out(15 downto 0)=X"0000" AND (exe_datatype="01" OR OP1out(31 downto 16)=X"0000") THEN
							Flags(2) <='1';
						ELSE	
							Flags(2) <='0';
						END IF;	
						Flags(1) <= '0';
						Flags(0) <= '0';
					END IF;
				END IF;	
			END IF;	
			Flags(7 downto 5) <= "000";
		END IF;	
	END PROCESS;
	
---------------------------------------------------------------------------------
------ MULU/MULS
---------------------------------------------------------------------------------	
PROCESS (exe_opcode, OP2out, muls_msb, mulu_reg, FAsign, mulu_sign, reg_QA, faktorA, faktorB, result_mulu, signedOP)
--PROCESS (exec, reg_QA, OP2out, faktorA, faktorB, signedOP)
	BEGIN
	IF MUL_Hardware=1 THEN
--		IF exe_opcode(15)='1' OR MUL_Mode=0 THEN	-- 16 Bit
		IF MUL_Mode=0 THEN	-- 16 Bit
			IF signedOP='1' AND reg_QA(15)='1' THEN
				faktorA <= X"FFFFFFFF";
			ELSE	
				faktorA <= X"00000000";
			END IF;
			IF signedOP='1' AND OP2out(15)='1' THEN
				faktorB <= X"FFFFFFFF";
			ELSE	
				faktorB <= X"00000000";
			END IF;
			result_mulu(63 downto 0) <= (faktorA(15 downto 0) & reg_QA(15 downto 0)) * (faktorB(15 downto 0) & OP2out(15 downto 0));
		ELSE
			IF exe_opcode(15)='1' THEN	-- 16 Bit
				IF signedOP='1' AND reg_QA(15)='1' THEN
					faktorA <= X"FFFFFFFF";
				ELSE	
					faktorA <= X"00000000";
				END IF;
				IF signedOP='1' AND OP2out(15)='1' THEN
					faktorB <= X"FFFFFFFF";
				ELSE	
					faktorB <= X"00000000";
				END IF;
			ELSE	
				faktorA(15 downto 0) <= reg_QA(31 downto 16);
				faktorB(15 downto 0) <= OP2out(31 downto 16);
				IF signedOP='1' AND reg_QA(31)='1' THEN
					faktorA(31 downto 16) <= X"FFFF";
				ELSE	
					faktorA(31 downto 16) <= X"0000";
				END IF;
				IF signedOP='1' AND OP2out(31)='1' THEN
					faktorB(31 downto 16) <= X"FFFF";
				ELSE	
					faktorB(31 downto 16) <= X"0000";
				END IF;
			END IF;
			result_mulu(127 downto 0) <= extended_product(faktorA(31 downto 16) & faktorA(31 downto 0) & reg_QA(15 downto 0), faktorB(31 downto 16) & faktorB(31 downto 0) & OP2out(15 downto 0));
		END IF;
--	END PROCESS;
-------------------------------------------------------------------------------
---- MULU/MULS
-------------------------------------------------------------------------------	
--PROCESS (exe_opcode, OP2out, muls_msb, mulu_reg, FAsign, mulu_sign, reg_QA, faktorB, result_mulu, signedOP)
--	BEGIN
	ELSE
		IF (signedOP='1' AND faktorB(31)='1') OR FAsign='1' THEN
			muls_msb <= mulu_reg(63);
		ELSE
			muls_msb <= '0';
		END IF;	
		
		IF signedOP='1' AND faktorB(31)='1' THEN
			mulu_sign <= '1';
		ELSE
			mulu_sign <= '0';
		END IF;	
		
		IF MUL_Mode=0 THEN	-- 16 Bit
			result_mulu(63 downto 32) <= muls_msb&mulu_reg(63 downto 33);	
			result_mulu(15 downto 0) <= 'X'&mulu_reg(15 downto 1);	
			IF mulu_reg(0)='1' THEN
				IF FAsign='1' THEN
					result_mulu(63 downto 47) <= (muls_msb&mulu_reg(63 downto 48)-(mulu_sign&faktorB(31 downto 16)));	
				ELSE
					result_mulu(63 downto 47) <= (muls_msb&mulu_reg(63 downto 48)+(mulu_sign&faktorB(31 downto 16)));	
				END IF;
			END IF;	
		ELSE				-- 32 Bit
			result_mulu(63 downto 0) <= muls_msb&mulu_reg(63 downto 1);	
			IF mulu_reg(0)='1' THEN
				IF FAsign='1' THEN
					result_mulu(63 downto 31) <= (muls_msb&mulu_reg(63 downto 32)-(mulu_sign&faktorB));	
				ELSE
					result_mulu(63 downto 31) <= (muls_msb&mulu_reg(63 downto 32)+(mulu_sign&faktorB));	
				END IF;
			END IF;	
		END IF;
		IF exe_opcode(15)='1' OR MUL_Mode=0 THEN
			faktorB(31 downto 16) <= OP2out(15 downto 0);
			faktorB(15 downto 0) <= (OTHERS=>'0');
		ELSE	
			faktorB <= OP2out;
		END IF;
	END IF;
		IF (result_mulu(63 downto 32)=X"00000000" AND (signedOP='0' OR result_mulu(31)='0')) OR
			(result_mulu(63 downto 32)=X"FFFFFFFF" AND signedOP='1' AND result_mulu(31)='1') THEN
			set_mV_Flag <= '0';
		ELSE	
			set_mV_Flag <= '1';
		END IF;
	END PROCESS;
	
PROCESS (clk)
	BEGIN
		IF rising_edge(clk) THEN
			IF clkena_lw='1' THEN
				IF MUL_Hardware=0 THEN
					IF micro_state=mul1 THEN
						mulu_reg(63 downto 32) <= (OTHERS=>'0');
						IF divs='1' AND ((exe_opcode(15)='1' AND reg_QA(15)='1') OR (exe_opcode(15)='0' AND reg_QA(31)='1')) THEN				--MULS Neg faktor
							FAsign <= '1';
							mulu_reg(31 downto 0) <= 0-reg_QA;
						ELSE
							FAsign <= '0';
							mulu_reg(31 downto 0) <= reg_QA;
						END IF;	
					ELSIF exec(opcMULU)='0' THEN
						mulu_reg <= result_mulu(63 downto 0);	
					END IF;
				ELSE	
					mulu_reg(31 downto 0) <= result_mulu(63 downto 32);
				END IF;
			END IF;
		END IF;
	END PROCESS;
		
-------------------------------------------------------------------------------
---- DIVU/DIVS
-------------------------------------------------------------------------------
		
PROCESS (execOPC, OP1out, OP2out, div_reg, div_neg, div_bit, div_sub, div_quot, OP1_sign, div_over, result_div, reg_QA, opcode, sndOPC, divs, exe_opcode, reg_QB, 
	     signedOP, nozero, div_qsign, OP2outext, result_div_pre)
	BEGIN
		divs <= (opcode(15) AND opcode(8)) OR (NOT opcode(15) AND sndOPC(11));
		dividend(15 downto 0) <= (OTHERS=> '0');
		dividend(63 downto 32) <= (OTHERS=> divs AND reg_QA(31));
		IF exe_opcode(15)='1' OR DIV_Mode=0 THEN --DIV.W
			dividend(47 downto 16) <= reg_QA;
			div_qsign <= result_div_pre(15);
		ELSE												  --DIV.l
			dividend(31 downto 0) <= reg_QA;
			IF exe_opcode(14)='1' AND sndOPC(10)='1' THEN
				dividend(63 downto 32) <= reg_QB;
			END IF;
			div_qsign <= result_div_pre(31);
		END IF;
		IF signedOP='1' OR opcode(15)='0' THEN 
			OP2outext <= OP2out(31 downto 16);
		ELSE
			OP2outext <= (OTHERS=> '0');
		END IF;
		IF signedOP='1' AND OP2out(31) ='1' THEN
			div_sub <= (div_reg(63 downto 31))+('1'&OP2out(31 downto 0));
		ELSE
			div_sub <= (div_reg(63 downto 31))-('0'&OP2outext(15 downto 0)&OP2out(15 downto 0));
		END IF;	
		IF DIV_Mode=0 THEN
			div_bit <= div_sub(16);
		ELSE
			div_bit <= div_sub(32);
		END IF;
		IF div_bit='1' THEN
			div_quot(63 downto 32) <= div_reg(62 downto 31);	
		ELSE
			div_quot(63 downto 32) <= div_sub(31 downto 0);	
		END IF;	
		div_quot(31 downto 0) <= div_reg(30 downto 0)&NOT div_bit;
		
		IF div_neg='1' THEN
			result_div_pre(31 downto 0) <= 0-div_quot(31 downto 0);

		ELSE
			result_div_pre(31 downto 0) <= div_quot(31 downto 0);
		END IF;	
		
		IF (((nozero='1' OR div_bit='0') AND signedOP='1' AND (OP2out(31) XOR OP1_sign XOR div_qsign)='1' )	--Overflow DIVS
			OR (signedOP='0' AND div_over(32)='0')) AND DIV_Mode/=3 THEN	--Overflow DIVU
			set_V_Flag <= '1';
		ELSE	
			set_V_Flag <= '0';
		END IF;
	END PROCESS;
	
PROCESS (clk)
	BEGIN
		IF rising_edge(clk) THEN
			IF clkena_lw='1' THEN
				IF micro_state/=div_end2 THEN
					V_Flag <= set_V_Flag;
				END IF;
				signedOP <= divs;
				IF micro_state=div1 THEN
					nozero <= '0';
					IF divs='1' AND dividend(63)='1' THEN				-- Neg dividend
						OP1_sign <= '1';
						div_reg <= 0-dividend;
					ELSE
						OP1_sign <= '0';
						div_reg <= dividend;
					END IF;	
				ELSE
					div_reg <= div_quot;	
					nozero <= NOT div_bit OR nozero;
				END IF;
				IF micro_state=div2 THEN
					div_neg <= signedOP AND (OP2out(31) XOR OP1_sign);
					IF DIV_Mode=0 THEN
						div_over(32 downto 16) <= ('0'&div_reg(47 downto 32))-('0'&OP2out(15 downto 0));
					ELSE	
						div_over <= ('0'&div_reg(63 downto 32))-('0'&OP2outext(15 downto 0)&OP2out(15 downto 0));
					END IF;	
				END IF;
				IF exec(write_reminder)='0' THEN
					result_div(31 downto 0) <= result_div_pre;
					IF OP1_sign='1' THEN
						result_div(63 downto 32) <= 0-div_quot(63 downto 32);
					ELSE
						result_div(63 downto 32) <= div_quot(63 downto 32);
					END IF;	
				END IF;
			END IF;
		END IF;
	END PROCESS;
END;
