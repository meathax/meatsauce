// Shared menu for the candidate platform and native HPS menu test.
// HQ2x is intentionally absent: it violates clock-plan R2.
`ifndef SPINAL_MISTER_MENU_SVH
`define SPINAL_MISTER_MENU_SVH
`define SPINAL_CONF_STR { \
    "SpinalBreakers;;", \
    "P1,Video Settings;", \
    "H0P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];", \
    "H0P1O[6:5],Scale,Normal,V-Integer,HV-Integer;", \
    "H0P1O[4:3],Rotation,Off,Clockwise,Counterclockwise;", \
    "P1O[2:1],Scandoubler Fx,None,CRT 25%,CRT 50%,CRT 75%;", \
    "H2P1O[54],CRT Adjust,Off,On;", \
    "H1H2P1O[57:55],CRT H-Size,0,+16,+32,-32,-16;", \
    "H1H2P1O[62:58],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;", \
    "H1H2P1O[67:63],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;", \
    "O[7],Autosave Scores,On,Off;", \
    "O[8],Pause,Off,On;", \
    "O[9],Service Credit,Off,On;", \
    "O[10],Test Switch,Off,On;", \
    "J1,Shot,Dodge,Bazooka,-,-,-,Start,Coin,Pause;", \
    "-;DIP;R[0],Reset;" \
}
`endif
