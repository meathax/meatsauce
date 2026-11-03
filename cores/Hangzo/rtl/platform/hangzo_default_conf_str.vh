`ifndef HANGZO_DEFAULT_CONF_STR_VH
`define HANGZO_DEFAULT_CONF_STR_VH
// Default OSD content. Runtime masks gate scaling, aspect, framebuffer
// rotation, direct rotation, scandoubler FX, CRT adjustment, and autosave.
`define HANGZO_DEFAULT_CONF_STR { \
  "Hangzo;;", \
  "J1,Sword,Jump,Shuriken,-,-,-,Start,Coin,Pause,Service;", \
  "P1,Video Settings;", \
  "H8P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];", \
  "H6P1O[45:44],Rotation,Normal,90 CW,90 CCW,180;", \
  "H2P1O[53],Direct Video Rotation,Normal,180;", \
  "H7P1O[47:46],Scaling,Normal,V-Integer,HV-Integer;", \
  "H0P1O[52:50],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;", \
  "H3P1-;", \
  "H3P1O[54],CRT Adjust,Off,On;", \
  "H3H4P1O[66:60],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;", \
  "H3H4P1O[71:67],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-8,-7,-6,-5,-4,-3,-2,-1;", \
  "P2,Game Settings;", \
  "P2O[41],OSD Pause,Off,On;", \
  "H5P2O[42],Autosave Scores,Off,On;", \
  "-;DIP;-;R[0],Reset;" \
}
`endif
