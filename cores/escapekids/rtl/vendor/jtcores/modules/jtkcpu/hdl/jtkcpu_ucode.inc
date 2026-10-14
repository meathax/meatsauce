localparam UCODE_DW = 60;
localparam OPCAT_AW = 6;
localparam UCODE_AW = OPCAT_AW+3;

reg [UCODE_DW-1:0] mem[0:2**(UCODE_AW-1)], ucode;
reg [UCODE_AW-1:0] addr; // current ucode position read
reg [OPCAT_AW-1:0] opcat, post_idx, nx_cat, idx_cat;

localparam [OPCAT_AW-1:0] 
        RESET            = 'o0,
        FIRQ             = 'o1,
        IRQ              = 'o2,
        NMI              = 'o3,
        BRSWI            = 'o4,
        BUSERROR         = 'o5,
        PARSE_IDX        = 'o6,
        IDX_R            = 'o7,
        IDX_RINC         = 'o10,
        IDX_RINC2        = 'o11,
        IDX_RDEC         = 'o12,
        IDX_RDEC2        = 'o13,
        IDX_OFFSET8      = 'o14,
        IDX_OFFSET16     = 'o15,
        IDX_IND          = 'o16,
        IDX_EXT          = 'o17,
        IDX_DP           = 'o20,
        IDX_ACC          = 'o21,
        IDX_UNK          = 'o22,
        SINGLE_ALU       = 'o23,
        CMP8             = 'o24,
        CMP8_IDX         = 'o25,
        SINGLE_ALU_16    = 'o26,
        SINGLE_ALUD      = 'o27,
        SINGLE_ALUD_IDX  = 'o30,
        CMP16            = 'o31,
        CMP16_IDX        = 'o32,
        SINGLE_A_INH     = 'o33,
        SINGLE_B_INH     = 'o34,
        SINGLE_ALU_INH16 = 'o35,
        SINGLE_ABX       = 'o36,
        SINGLE_ALU_IDX   = 'o37,
        SINGLE_ALU_IDX16 = 'o40,
        SHIFTD           = 'o41,
        SHIFTD_IDX       = 'o42,
        NOPE             = 'o43,
        MEM_ALU_IDX      = 'o44,
        DIVIDE           = 'o45,
        WMEM_ALU         = 'o46,
        MULTIPLY         = 'o47,
        LMULTIPLY        = 'o50,
        LOOPX            = 'o51,
        LOOPB            = 'o52,
        MOVE             = 'o53,
        BMOVE            = 'o54,
        BSETA            = 'o55,
        BSETD            = 'o56,
        STORE8           = 'o57,
        STORE16          = 'o60,
        LEA              = 'o61,
        SETLNS           = 'o62,
        SETLNS_IDX       = 'o63,
        EXCHANGE         = 'o64,
        TRANSFER         = 'o65,
        SBRANCH          = 'o66,
        SBSR             = 'o67,
        BSRL             = 'o70,
        LBRANCH          = 'o71,
        JUMP             = 'o72,
        JMSR             = 'o73,
        RTIT             = 'o74,
        RTSR             = 'o75,
        PSH              = 'o76,
        PUL              = 'o77;

assign { 
        we, 
        up_tfr, 
        up_move, 
        up_lmul, 
        up_lines, 
        up_lea, 
        up_ldb, 
        up_lda, 
        up_ld8, 
        up_ld16, 
        up_exg, 
        up_div, 
        up_cc, 
        up_abx, 
        up_ab, 
        uc_loop, 
        shd_en, 
        rti_other, 
        rti_cc, 
        pul_go, 
        psh_pc, 
        psh_go, 
        psh_cc, 
        psh_all, 
        pc_jmp, 
        set_pc_branch8, 
        set_pc_branch16, 
        set_opn0_mem, 
        opd, 
        niuz, 
        ni, 
        memhi, 
        int_en, 
        incx, 
        idx_ret, 
        idx_pre, 
        set_idx_post, 
        idx_jmp, 
        idx_ind, 
        idx_en, 
        idx_dp, 
        idx_adv, 
        set_idx_acc, 
        idx_8, 
        idx_16, 
        set_idxw, 
        set_i, 
        set_fake_irq, 
        set_f, 
        set_e, 
        clr_e, 
        div_en, 
        decx, 
        decu, 
        decb, 
        data2addr, 
        buserror, 
        branch_bnz, 
        addry, 
        addrx
    } = ucode;


always @(posedge clk,posedge rst) begin
	if(rst) begin
		ucode <= 0;
	end else if(cen) begin
	    case( addr )	        9'o000: ucode <= 60'h8002800;    // RESET
	        9'o004: ucode <= 60'h20000000;
	        9'o010: ucode <= 60'h6000000200;    // FIRQ
	        9'o011: ucode <= 60'h2800;
	        9'o013: ucode <= 60'h8002A00;
	        9'o015: ucode <= 60'h20000000;
	        9'o020: ucode <= 60'h5000000400;    // IRQ
	        9'o021: ucode <= 60'h2000;
	        9'o023: ucode <= 60'h8002400;
	        9'o025: ucode <= 60'h20000000;
	        9'o030: ucode <= 60'h5000000400;    // NMI
	        9'o031: ucode <= 60'h2800;
	        9'o033: ucode <= 60'h8002C00;
	        9'o035: ucode <= 60'h20000000;
	        9'o040: ucode <= 60'h80000000;    // BRSWI
	        9'o041: ucode <= 60'h400000000;
	        9'o043: ucode <= 60'h1000;
	        9'o045: ucode <= 60'h20000000;
	        9'o050: ucode <= 60'h008;    // BUSERROR
	        9'o060: ucode <= 60'h80000000;    // PARSE_IDX
	        9'o061: ucode <= 60'h400000;
	        9'o071: ucode <= 60'h200000;
	        9'o100: ucode <= 60'h800000;    // IDX_RINC
	        9'o101: ucode <= 60'h200000;
	        9'o110: ucode <= 60'h804000;    // IDX_RINC2
	        9'o111: ucode <= 60'h200000;
	        9'o120: ucode <= 60'h1000000;    // IDX_RDEC
	        9'o121: ucode <= 60'h200000;
	        9'o130: ucode <= 60'h4000;    // IDX_RDEC2
	        9'o131: ucode <= 60'h1000000;
	        9'o132: ucode <= 60'h200000;
	        9'o140: ucode <= 60'h80000000;    // IDX_OFFSET8
	        9'o141: ucode <= 60'h210000;
	        9'o150: ucode <= 60'h90000000;    // IDX_OFFSET16
	        9'o151: ucode <= 60'h80000000;
	        9'o152: ucode <= 60'h208000;
	        9'o160: ucode <= 60'h10100000;    // IDX_IND
	        9'o161: ucode <= 60'h140000;
	        9'o162: ucode <= 60'h2000010;
	        9'o170: ucode <= 60'h90000000;    // IDX_EXT
	        9'o171: ucode <= 60'h80000000;
	        9'o172: ucode <= 60'h200010;
	        9'o200: ucode <= 60'h80000000;    // IDX_DP
	        9'o201: ucode <= 60'h280000;
	        9'o211: ucode <= 60'h220000;
	        9'o220: ucode <= 60'h200000;    // IDX_UNK
	        9'o230: ucode <= 60'h80000000;    // SINGLE_ALU
	        9'o231: ucode <= 60'h8800000000000;
	        9'o232: ucode <= 60'h20000000;
	        9'o240: ucode <= 60'h80000000;    // CMP8
	        9'o241: ucode <= 60'h800000000000;
	        9'o242: ucode <= 60'h20000000;
	        9'o250: ucode <= 60'h100000;    // CMP8_IDX
	        9'o251: ucode <= 60'h800000000000;
	        9'o252: ucode <= 60'h20000000;
	        9'o260: ucode <= 60'h90000000;    // SINGLE_ALU_16
	        9'o261: ucode <= 60'h80000000;
	        9'o262: ucode <= 60'h4800000000000;
	        9'o263: ucode <= 60'h20000000;
	        9'o270: ucode <= 60'h90000000;    // SINGLE_ALUD
	        9'o271: ucode <= 60'h80000000;
	        9'o272: ucode <= 60'hA00000000000;
	        9'o273: ucode <= 60'h20000000;
	        9'o300: ucode <= 60'h10100000;    // SINGLE_ALUD_IDX
	        9'o301: ucode <= 60'h140000;
	        9'o302: ucode <= 60'hA00000000000;
	        9'o303: ucode <= 60'h20000000;
	        9'o310: ucode <= 60'h90000000;    // CMP16
	        9'o311: ucode <= 60'h80000000;
	        9'o312: ucode <= 60'h800000000000;
	        9'o313: ucode <= 60'h20000000;
	        9'o320: ucode <= 60'h10100000;    // CMP16_IDX
	        9'o321: ucode <= 60'h140000;
	        9'o322: ucode <= 60'h800000000000;
	        9'o323: ucode <= 60'h20000000;
	        9'o330: ucode <= 60'h10800000000000;    // SINGLE_A_INH
	        9'o331: ucode <= 60'h20000000;
	        9'o340: ucode <= 60'h20800000000000;    // SINGLE_B_INH
	        9'o341: ucode <= 60'h20000000;
	        9'o350: ucode <= 60'hA00000000000;    // SINGLE_ALU_INH16
	        9'o351: ucode <= 60'h20000000;
	        9'o360: ucode <= 60'h400000000000;    // SINGLE_ABX
	        9'o361: ucode <= 60'h20000000;
	        9'o370: ucode <= 60'h100000;    // SINGLE_ALU_IDX
	        9'o371: ucode <= 60'h8800000000000;
	        9'o372: ucode <= 60'h20000000;
	        9'o400: ucode <= 60'h10100000;    // SINGLE_ALU_IDX16
	        9'o401: ucode <= 60'h140000;
	        9'o402: ucode <= 60'h4800000000000;
	        9'o403: ucode <= 60'h20000000;
	        9'o410: ucode <= 60'h80000000;    // SHIFTD
	        9'o411: ucode <= 60'h80000000000;
	        9'o413: ucode <= 60'hA00000000000;
	        9'o414: ucode <= 60'h20000000;
	        9'o420: ucode <= 60'h10100000;    // SHIFTD_IDX
	        9'o421: ucode <= 60'h140000;
	        9'o422: ucode <= 60'h80000140000;
	        9'o424: ucode <= 60'h800100000000;
	        9'o425: ucode <= 60'h800000010100000;
	        9'o426: ucode <= 60'h800000000140000;
	        9'o430: ucode <= 60'h20000000;    // NOPE
	        9'o440: ucode <= 60'h100000;    // MEM_ALU_IDX
	        9'o441: ucode <= 60'h800800100100000;
	        9'o442: ucode <= 60'h20000000;
	        9'o450: ucode <= 60'h100;    // DIVIDE
	        9'o453: ucode <= 60'h1800000000000;
	        9'o454: ucode <= 60'h20000000;
	        9'o460: ucode <= 60'h10100000;    // WMEM_ALU
	        9'o461: ucode <= 60'h140000;
	        9'o462: ucode <= 60'h800000110100000;
	        9'o463: ucode <= 60'h800800100140000;
	        9'o464: ucode <= 60'h20000000;
	        9'o474: ucode <= 60'hA00000000000;
	        9'o475: ucode <= 60'h20000000;
	        9'o504: ucode <= 60'h100800000000000;
	        9'o505: ucode <= 60'h20000000;
	        9'o510: ucode <= 60'h80000000;    // LOOPX
	        9'o511: ucode <= 60'h800000000080;
	        9'o512: ucode <= 60'h004;
	        9'o513: ucode <= 60'h20000000;
	        9'o520: ucode <= 60'h80000000;    // LOOPB
	        9'o521: ucode <= 60'h800000000020;
	        9'o522: ucode <= 60'h004;
	        9'o523: ucode <= 60'h20000000;
	        9'o530: ucode <= 60'h002;    // MOVE
	        9'o531: ucode <= 60'hA00000000000001;
	        9'o532: ucode <= 60'h20000000;
	        9'o540: ucode <= 60'h40000000;    // BMOVE
	        9'o542: ucode <= 60'h002;
	        9'o543: ucode <= 60'hA00000000000001;
	        9'o544: ucode <= 60'h100000000000;
	        9'o550: ucode <= 60'h40000000;    // BSETA
	        9'o552: ucode <= 60'h800000004000041;
	        9'o553: ucode <= 60'h100000000000;
	        9'o560: ucode <= 60'h40000000;    // BSETD
	        9'o562: ucode <= 60'h800000004000041;
	        9'o563: ucode <= 60'h800000004000001;
	        9'o564: ucode <= 60'h100000000000;
	        9'o570: ucode <= 60'h800800000100000;    // STORE8
	        9'o571: ucode <= 60'h20000000;
	        9'o600: ucode <= 60'h800000010100000;    // STORE16
	        9'o601: ucode <= 60'h800800000140000;
	        9'o602: ucode <= 60'h20000000;
	        9'o610: ucode <= 60'h40800000000000;    // LEA
	        9'o611: ucode <= 60'h20000000;
	        9'o620: ucode <= 60'h80000000;    // SETLNS
	        9'o621: ucode <= 60'h80000020000000;
	        9'o630: ucode <= 60'h100000;    // SETLNS_IDX
	        9'o631: ucode <= 60'h80000020000000;
	        9'o640: ucode <= 60'h80000000;    // EXCHANGE
	        9'o641: ucode <= 60'h2000000000000;
	        9'o642: ucode <= 60'h20000000;
	        9'o650: ucode <= 60'h80000000;    // TRANSFER
	        9'o651: ucode <= 60'h400000000000000;
	        9'o652: ucode <= 60'h20000000;
	        9'o660: ucode <= 60'h80000000;    // SBRANCH
	        9'o661: ucode <= 60'h400000000;
	        9'o662: ucode <= 60'h20000000;
	        9'o670: ucode <= 60'h80000000;    // SBSR
	        9'o671: ucode <= 60'hC000000000;
	        9'o673: ucode <= 60'h400000000;
	        9'o674: ucode <= 60'h20000000;
	        9'o700: ucode <= 60'h90000000;    // BSRL
	        9'o701: ucode <= 60'h80000000;
	        9'o702: ucode <= 60'hC000000000;
	        9'o704: ucode <= 60'h200000000;
	        9'o705: ucode <= 60'h20000000;
	        9'o710: ucode <= 60'h90000000;    // LBRANCH
	        9'o711: ucode <= 60'h80000000;
	        9'o712: ucode <= 60'h200000000;
	        9'o713: ucode <= 60'h20000000;
	        9'o720: ucode <= 60'h800000000;    // JUMP
	        9'o721: ucode <= 60'h20000000;
	        9'o730: ucode <= 60'hC000000000;    // JMSR
	        9'o732: ucode <= 60'h800000000;
	        9'o733: ucode <= 60'h20000000;
	        9'o740: ucode <= 60'h30000000000;    // RTIT
	        9'o742: ucode <= 60'h50000000000;
	        9'o744: ucode <= 60'h20000000;
	        9'o750: ucode <= 60'h18000000000;    // RTSR
	        9'o753: ucode <= 60'h20000000;
	        9'o760: ucode <= 60'h80000000;    // PSH
	        9'o761: ucode <= 60'h4000000000;
	        9'o764: ucode <= 60'h20000000;
	        9'o770: ucode <= 60'h80000000;    // PUL
	        9'o771: ucode <= 60'h10000000000;
	        9'o774: ucode <= 60'h20000000;
	        default: ucode <= 0;
	    endcase
	end
end

