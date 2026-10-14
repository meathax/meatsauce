library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package mdec_color_math_pkg is

	subtype color_product_t is signed(16 downto 0);

	function color_r_product(value : signed(7 downto 0)) return color_product_t;
	function color_g_product(blue : signed(7 downto 0); red : signed(7 downto 0)) return color_product_t;
	function color_b_product(value : signed(7 downto 0)) return color_product_t;

end package;

package body mdec_color_math_pkg is

	function color_r_product(value : signed(7 downto 0)) return color_product_t is
		variable extended : color_product_t;
	begin
		extended := resize(value, extended'length);
		return shift_left(extended, 8) + shift_left(extended, 6) + shift_left(extended, 5) + shift_left(extended, 2) + shift_left(extended, 1) + extended;
	end function;

	function color_g_product(blue : signed(7 downto 0); red : signed(7 downto 0)) return color_product_t is
		variable blue_extended : color_product_t;
		variable red_extended  : color_product_t;
	begin
		blue_extended := resize(blue, blue_extended'length);
		red_extended  := resize(red, red_extended'length);
		return -(shift_left(blue_extended, 6) + shift_left(blue_extended, 4) + shift_left(blue_extended, 3))
		       -(shift_left(red_extended, 7) + shift_left(red_extended, 5) + shift_left(red_extended, 4) + shift_left(red_extended, 2) + shift_left(red_extended, 1) + red_extended);
	end function;

	function color_b_product(value : signed(7 downto 0)) return color_product_t is
		variable extended : color_product_t;
	begin
		extended := resize(value, extended'length);
		return shift_left(extended, 8) + shift_left(extended, 7) + shift_left(extended, 6) + shift_left(extended, 2) + shift_left(extended, 1);
	end function;

end package body;
