// DFJail OSD layout mapped to the JTFRAME 64-bit MiSTer status contract.
// status[48] is the CRT Adjust master: the DFJail status decoder bypasses
// H-size and zeros both resync offsets while it is off.
localparam DFJAIL_CONF_STR = {
    "From Jail;;",
    "P1,Video Settings;",
    "H0P1O[17:16],Aspect ratio,Original,Full screen,[ARC1],[ARC2];",
    "P1O[40:39],Rotate screen,Normal,90 CW,90 CCW,180;",
    "P1O[47:46],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
`ifdef JTFRAME_NOHQ2X
    "d3P1O[5:3],Scandoubler Fx,None,N/A,CRT 25%,CRT 50%,CRT 75%;",
`else
    "d3P1O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
`endif
    "P1O[48],CRT Adjust,Off,On;",
    "H2P1O[51:49],CRT H-Size,0,+1,+2,-2,-1;",
    "H2P1O[56:52],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "H2P1O[61:57],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "P2,Game Settings;",
`ifdef JTFRAME_OSD_TEST
    "P2O[10],Service mode,Off,On;",
`endif
`ifdef JTFRAME_CREDITS
    "P2O[12],Show credits in pause,On,Off;",
`endif
`ifdef DFJAIL_HISCORE
    "P2O[62],Autosave Hiscores,On,Off;",
`endif
    "-;",
    "DIP;",
    "R[0],Reset;",
    "v,1;V,v"
};
