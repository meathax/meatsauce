#!/usr/bin/env python3
"""Prove actual sprite tile arithmetic and packed ROM addressing bit for bit."""
import pathlib
import re
import subprocess

root=pathlib.Path(__file__).resolve().parent.parent
build=pathlib.Path("/mnt/r/Verilator/zero-sprite-address-checks")
build.mkdir(parents=True,exist_ok=True)
source=(root/"rtl/Raiden2/Raiden2_sprite_renderer.sv").read_text()
function=re.search(r"function automatic \[15:0\] sprite_tile_code;.*?endfunction",source,re.S)
target=re.search(r"function automatic \[8:0\] sprite_target_row;.*?endfunction",source,re.S)
address=re.search(r"rom_addr\s*<=\s*(\{1'b0,\s*cur_tile,.*?\});",source,re.S)
if function is None or address is None or target is None:
    raise RuntimeError("Actual RTL sprite arithmetic/address expression missing")
harness=build/"sprite_address_checks.sv"
harness.write_text("""module sprite_address_checks(
input [15:0] code_value,input [3:0] tile_x,tile_height,tile_y,eff_row,
input pf_side,input [8:0] raster_y,input flipped,output [8:0] target_y,
output [15:0] cur_tile,output [23:0] address);
"""+function.group()+"\n"+target.group()+"\nassign target_y=sprite_target_row(raster_y,flipped);\n"
                  +"assign cur_tile=sprite_tile_code(code_value,tile_x,tile_height,tile_y);\n"
                  +"assign address="+address.group(1)+";\nendmodule\n")
log=root/"sim/results/sprite-address-build.log"
log.parent.mkdir(parents=True,exist_ok=True)
with log.open("w") as output:
    subprocess.run(["verilator","--cc","--exe","--build","-j","4","--no-timing",
                    "--top-module","sprite_address_checks","--Mdir",str(build),
                    str(harness),str(root/"sim/sprite_address_checks.cpp"),
                    "-CFLAGS","-std=c++17 -O3"],stdout=output,stderr=subprocess.STDOUT,check=True)
subprocess.run([str(build/"Vsprite_address_checks")],check=True)
