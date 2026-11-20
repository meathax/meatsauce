// SPDX-License-Identifier: BSD-3-Clause
// Native MAME ES5510 instruction ordering; copyright Christian Brunschen.
// External synchronous instruction/GPR/delay stores. A step retires one native
// instruction, including the N-2 read and N-1 writes. Host/serial integration
// and sample throughput are separate gates; this is not the host-only donor.
module gs_es5510_execute(
    input wire clk,cold_reset,reset,step,halt_asserted,
    output wire ready,
    output reg done,halted,fault,
    output reg [7:0] pc,
    output wire ir_req, output wire [7:0] ir_addr,
    input wire ir_ack,input wire [47:0] ir_data,
    output wire rf_req,output reg [7:0] rf_a,rf_b,
    input wire rf_ack,input wire [23:0] rf_data_a,rf_data_b,
    output wire rf_we,output wire [7:0] rf_waddr,
    output wire [23:0] rf_wdata,input wire rf_wack,
    output wire dram_req,dram_write,output wire [19:0] dram_addr,
    output wire [15:0] dram_wdata,input wire dram_ack,
    input wire [15:0] dram_rdata,
    input wire host_we,host_halt,input wire [7:0] host_reg,
    input wire [23:0] host_data,input wire [7:0] inspect_reg,
    output wire [31:0] inspect_data,
    input wire serial_we,input wire [127:0] serial_input,
    output wire [127:0] serial_output,
    output wire [63:0] debug_accumulator,
    output wire [7:0] debug_ccr,debug_cmr,
    output wire [31:0] debug_dol,
    output wire [1:0] debug_dol_count,
    output wire [15:0] debug_dil,
    output wire [23:0] debug_dbase,debug_dlength,
    output wire [4:0] debug_memshift
);
    typedef enum logic [3:0] {IDLE,FETCH,READ2,ADDRESS,ADDRESS_WAIT,
        MAC_START,MAC_WAIT,MAC_RETIRE,MAC_CAPTURE,ALU_RESULT,ALU_RETIRE,
        ALU_CAPTURE,WRITE1,FINISH} phase_t;
    phase_t phase;
    reg insn_seen,offset_seen;
    reg address_started,address_done,mac_started,mac_done;
    reg [47:0] insn;
    reg [23:0] offset;
    reg skip;
    reg [1:0] next_cycle,prev_cycle,read_cycle,write_cycle;
    reg next_io,prev_io,read_io,write_io;
    reg [23:0] next_addr,prev_addr,read_addr,write_addr;
    reg signed [15:0] dil;
    reg [15:0] dol0,dol1;
    reg [1:0] dol_count;
    reg [7:0] ccr,cmr;
    reg signed [63:0] machl;
    reg mac_overflow;
    reg [23:0] dbase,dlength,abase,bbase,sigreg;
    reg [4:0] memshift;
    reg [1:0] mulshift;
    reg [15:0] serial [0:7];
    reg mac_write,mac_accumulate;
    reg [1:0] mac_dst;
    reg [7:0] mac_c_reg;
    reg [23:0] mac_c,mac_d;
    reg alu_write,alu_update;
    reg [1:0] alu_dst;
    reg [7:0] alu_a_reg;
    reg [3:0] alu_op;
    reg [31:0] alu_a,alu_b;
    reg [31:0] alu_saved_result;
    reg [7:0] alu_saved_flags;
    reg end_in_step;
    wire [23:0] memmask=24'hffffff << memshift;
    wire [24:0] increment=25'd1 << memshift;
    wire address_valid,address_supported,address_io;
    wire [1:0] address_cycle;
    wire [23:0] address_result;
    wire mac_valid,mac_result_overflow;
    wire signed [63:0] mac_result;
    wire [23:0] mac_value;
    wire [31:0] alu_result;
    wire [7:0] alu_flags;
    wire [7:0] select=operand_select(insn[11:8]);
    wire [31:0] rf_read_a=read_register(rf_a,rf_data_a);
    wire [31:0] rf_read_b=read_register(rf_b,rf_data_b);
    // {ALU source, ALU destination, MAC source, MAC destination}
    function automatic [7:0] operand_select(input [3:0] value);
        case(value)
        0:operand_select=8'b01_01_01_01;
        1:operand_select=8'b01_01_01_10;
        2:operand_select=8'b01_01_01_11;
        3:operand_select=8'b01_01_10_01;
        4:operand_select=8'b01_01_10_11;
        5:operand_select=8'b01_10_01_01;
        6:operand_select=8'b01_10_10_01;
        7:operand_select=8'b01_11_01_01;
        8:operand_select=8'b01_11_10_01;
        9:operand_select=8'b10_01_01_01;
        10:operand_select=8'b10_01_01_10;
        11:operand_select=8'b10_01_01_11;
        12:operand_select=8'b10_01_10_01;
        13:operand_select=8'b10_01_10_11;
        14:operand_select=8'b10_11_01_01;
        default:operand_select=8'b10_11_10_01;
        endcase
    endfunction
    function automatic [31:0] read_register(input [7:0] addr,input [23:0] gpr);
        if(addr<192) read_register={8'b0,gpr};
        else case(addr)
        234,235,236,237,238,239,240,241:
            read_register={{8{serial[addr-234][15]}},serial[addr-234],8'b0};
        242:read_register=mac_overflow ? (machl[63] ? 0:32'h00ffffff) : {8'b0,machl[23:0]};
        243:read_register=mac_overflow ? (machl[63] ? 32'h00800000:32'h007fffff) : {8'b0,machl[47:24]};
        244:read_register={{8{dil[15]}},dil,8'b0};
        245:read_register={8'b0,dlength};
        246:read_register={8'b0,abase};
        247:read_register={8'b0,bbase};
        248:read_register={8'b0,dbase};
        249:read_register={8'b0,sigreg};
        250:read_register={{8{ccr[7]}},ccr,16'b0};
        251:read_register={{8{cmr[7]}},cmr,16'b0};
        252:read_register=32'h00ffffff;
        253:read_register=32'h00800000;
        254:read_register=32'h007fffff;
        default:read_register=0;
        endcase
    endfunction
    function automatic [4:0] trailing_ones(input [23:0] value);
        // Mutually exclusive low-zero patterns form a parallel encoder.
        // The previous incremental loop put24 dependent additions on MEMSIZ.
        casez(value)
        24'b???????????????????????0:trailing_ones=5'd0;
        24'b??????????????????????01:trailing_ones=5'd1;
        24'b?????????????????????011:trailing_ones=5'd2;
        24'b????????????????????0111:trailing_ones=5'd3;
        24'b???????????????????01111:trailing_ones=5'd4;
        24'b??????????????????011111:trailing_ones=5'd5;
        24'b?????????????????0111111:trailing_ones=5'd6;
        24'b????????????????01111111:trailing_ones=5'd7;
        24'b???????????????011111111:trailing_ones=5'd8;
        24'b??????????????0111111111:trailing_ones=5'd9;
        24'b?????????????01111111111:trailing_ones=5'd10;
        24'b????????????011111111111:trailing_ones=5'd11;
        24'b???????????0111111111111:trailing_ones=5'd12;
        24'b??????????01111111111111:trailing_ones=5'd13;
        24'b?????????011111111111111:trailing_ones=5'd14;
        24'b????????0111111111111111:trailing_ones=5'd15;
        24'b???????01111111111111111:trailing_ones=5'd16;
        24'b??????011111111111111111:trailing_ones=5'd17;
        24'b?????0111111111111111111:trailing_ones=5'd18;
        24'b????01111111111111111111:trailing_ones=5'd19;
        24'b???011111111111111111111:trailing_ones=5'd20;
        24'b??0111111111111111111111:trailing_ones=5'd21;
        24'b?01111111111111111111111:trailing_ones=5'd22;
        24'b011111111111111111111111:trailing_ones=5'd23;
        default:trailing_ones=5'd24;
        endcase
    endfunction
    function automatic [23:0] low_ones_mask(input [23:0] value);
        integer i;reg prefix;
        begin
            prefix=1;
            for(i=0;i<24;i=i+1)begin
                prefix=prefix && value[i];low_ones_mask[i]=!prefix;
            end
        end
    endfunction
    task automatic write_special(input [7:0] addr,input [23:0] value,
                                 input signed [63:0] accumulator);
        reg [47:0] masked;reg [4:0] shift;
        begin
            case(addr)
            234,235,236,237,238,239,240,241:serial[addr-234]<=value[23:8];
            242:begin
                masked={accumulator[47:24],value};
                machl<={{16{masked[47]}},masked};
            end
            243:begin
                masked={value,accumulator[23:0]};
                machl<={{16{masked[47]}},masked};mac_overflow<=0;
            end
            244:begin shift=trailing_ones(value);memshift<=shift;dbase<=dbase & low_ones_mask(value);end
            245:dlength<=value;
            246:abase<=value;
            247:bbase<=value;
            248:dbase<=value;
            249:begin sigreg<=value;mulshift<=value[22] ? 1:2;end
            250:ccr<=value[23:16] & 8'hf8;
            251:cmr<=value[23:16] & 8'hfc;
            default:begin end
            endcase
        end
    endtask
    task automatic push_dol(input [23:0] value);
        begin
            if(dol_count==0)begin dol0<=value[23:8];dol_count<=1;end
            else begin if(dol_count==2)dol0<=dol1;dol1<=value[23:8];dol_count<=2;end
        end
    endtask
    assign ready=phase==IDLE && !reset && !cold_reset;
    assign ir_req=phase==FETCH && !insn_seen;
    assign ir_addr=pc;
    assign rf_req=(phase==FETCH && !offset_seen) || phase==MAC_CAPTURE || phase==ALU_CAPTURE;
    always @* begin
        rf_a=pc;rf_b=pc;
        if(phase==MAC_RETIRE || phase==MAC_CAPTURE)begin rf_a=insn[39:32];rf_b=insn[47:40];end
        if(phase==ALU_RETIRE || phase==ALU_CAPTURE)begin rf_a=insn[23:16];rf_b=insn[31:24];end
    end
    wire mac_reg_write=phase==MAC_RETIRE && mac_write && mac_dst[0];
    wire alu_reg_write=phase==ALU_RETIRE && alu_write && alu_op!=4 && alu_dst[0];
    wire [7:0] retire_addr=mac_reg_write ? mac_c_reg:alu_a_reg;
    wire [23:0] retire_value=mac_reg_write ? mac_value:alu_saved_result[23:0];
    assign rf_we=(mac_reg_write || alu_reg_write) && retire_addr<192;
    assign rf_waddr=retire_addr;
    assign rf_wdata=retire_value;
    wire retire_ready=!rf_we || rf_wack;
    // These phases are mutually exclusive. Share one special-register decoder
    // and one DOL push path instead of synthesizing each task at every call site.
    // MAC special writes deliberately retain the original ungated mac_dst rule.
    wire host_special=host_we && ready;
    wire mac_special=phase==MAC_RETIRE && retire_ready && mac_dst[0];
    wire alu_special=phase==ALU_RETIRE && retire_ready && alu_write && alu_op!=4 && alu_dst[0];
    wire [7:0] special_addr=host_special ? host_reg : mac_special ? mac_c_reg : alu_a_reg;
    wire [23:0] special_value=host_special ? host_data : mac_special ? mac_value : alu_saved_result[23:0];
    wire mac_push=phase==MAC_RETIRE && retire_ready && mac_dst[1];
    wire alu_push=phase==ALU_RETIRE && retire_ready && alu_write && alu_op!=4 && alu_dst[1];
    assign dram_req=(phase==READ2 && read_cycle!=1 && !read_io) ||
                    (phase==WRITE1 && write_cycle==1 && !write_io);
    assign dram_write=phase==WRITE1;
    assign dram_addr=phase==READ2 ? read_addr[19:0]:write_addr[19:0];
    assign dram_wdata=dol0;
    assign inspect_data=read_register(inspect_reg,rf_data_a);
    genvar j;
    generate for(j=0;j<8;j=j+1)begin:serial_ports
        assign serial_output[16*j +:16]=serial[j];
    end endgenerate
    assign debug_accumulator=machl;
    assign debug_ccr=ccr;assign debug_cmr=cmr;
    assign debug_dol={dol1,dol0};assign debug_dol_count=dol_count;
    assign debug_dil=dil;assign debug_dbase=dbase;assign debug_dlength=dlength;
    assign debug_memshift=memshift;
    wire address_start=phase==FETCH && !address_started &&
        (insn_seen || ir_ack) && (offset_seen || rf_ack);
    gs_es5510_address addressing(
        .clk(clk),.reset(reset || cold_reset),.start(address_start),.ready(),
        .control(insn_seen ? insn[5:3]:ir_data[5:3]),.offset(offset_seen ? offset:rf_data_a),.dbase(dbase),.dlength(dlength),
        .abase(abase),.bbase(bbase),.memshift(memshift),.valid(address_valid),
        .supported(address_supported),.io(address_io),.cycle(address_cycle),.address(address_result)
    );
    gs_es5510_mac multiplier(
        .clk(clk),.reset(reset || cold_reset),.start(phase==FETCH && !mac_started && mac_write),.ready(),
        .c(mac_c),.d(mac_d),.shift(mulshift),.accumulate(mac_accumulate),
        .accumulator(machl),.valid(mac_valid),.overflow(mac_result_overflow),
        .result(mac_result),.value(mac_value)
    );
    gs_es5510_alu arithmetic(.op(alu_op),.a(alu_a),.b(alu_b),.flags_in(ccr),
        .result(alu_result),.flags_out(alu_flags));
    integer k;
    always @(posedge clk) begin
        done<=0;
        if(serial_we && ready)for(k=0;k<8;k=k+1)serial[k]<=serial_input[16*k +:16];
        if(host_special || mac_special || alu_special)write_special(special_addr,special_value,machl);
        if(mac_push || alu_push)push_dol(mac_push ? mac_value : alu_saved_result[23:0]);
        if(host_halt && ready && halt_asserted)halted<=1;
        // Address arithmetic and the prior MAC are independent of the current
        // N-2 delay read. Compute early; retire them at their native positions.
        if(phase==FETCH && !mac_started && mac_write)mac_started<=1;
        if(address_start)address_started<=1;
        if(mac_valid)mac_done<=1;
        if(address_valid)begin
            next_cycle<=address_cycle;next_io<=address_io;next_addr<=address_result;
            address_done<=1;if(!address_supported)fault<=1;
        end
        case(phase)
        IDLE:if(step && !host_we && !serial_we && !host_halt)begin
            address_started<=0;address_done<=0;mac_started<=0;mac_done<=0;
            if(halted)begin
                // A native halted-cycle wake resets PC without executing IRAM.
                done<=1;
                if(!halt_asserted)begin pc<=0;halted<=0;end
            end else begin
                insn_seen<=0;offset_seen<=0;end_in_step<=0;phase<=FETCH;
            end
        end
        FETCH:begin
            if(pc>=160)begin fault<=1;phase<=IDLE;done<=1;end
            else begin
                if(ir_ack && !insn_seen)begin insn<=ir_data;insn_seen<=1;end
                if(rf_ack && !offset_seen)begin offset<=rf_data_a;offset_seen<=1;end
                if((insn_seen || ir_ack) && (offset_seen || rf_ack))begin
                    read_cycle<=prev_cycle;read_addr<=prev_addr;read_io<=prev_io;
                    write_cycle<=next_cycle;write_addr<=next_addr;write_io<=next_io;
                    prev_cycle<=next_cycle;prev_addr<=next_addr;prev_io<=next_io;
                    phase<=READ2;
                end
            end
        end
        READ2:if(read_cycle==1 || read_io || dram_ack)begin
            if(read_cycle!=1)dil<=read_io ? 16'd0:dram_rdata;
            phase<=ADDRESS_WAIT;
        end
        ADDRESS:phase<=ADDRESS_WAIT;
        ADDRESS_WAIT:if(address_done || address_valid)begin
            skip<=insn[7] && (((ccr & cmr & 8'hf8)!=0) ^ cmr[2]);
            // The previous MAC already runs during fetch/address work.
            // Join its completed result here instead of spending a bubble
            // in MAC_START; retirement and operand-read ordering are unchanged.
            if(!mac_write)phase<=MAC_CAPTURE;
            else if(mac_done || mac_valid)begin machl<=mac_result;mac_overflow<=mac_result_overflow;phase<=MAC_RETIRE;end
            else phase<=MAC_START;
        end
        MAC_START:begin
            if(!mac_write)phase<=MAC_CAPTURE;
            else if(mac_done || mac_valid)begin machl<=mac_result;mac_overflow<=mac_result_overflow;phase<=MAC_RETIRE;end
            else phase<=MAC_WAIT;
        end
        MAC_WAIT:if(mac_done || mac_valid)begin machl<=mac_result;mac_overflow<=mac_result_overflow;phase<=MAC_RETIRE;end
        MAC_RETIRE:if(retire_ready)begin
            phase<=MAC_CAPTURE;
        end
        MAC_CAPTURE:if(rf_ack)begin
            mac_c_reg<=insn[39:32];mac_dst<=select[1:0];mac_accumulate<=insn[6];mac_write<=!skip;
            mac_c<=select[3:2]==1 ? rf_read_a[23:0]:{dil,8'b0};
            mac_d<=rf_read_b[23:0];
            // MAC retirement occurred before this operand-read phase. The
            // prior ALU therefore sees the same settled CCR as ALU_RESULT did.
            alu_saved_result<=alu_result;alu_saved_flags<=alu_flags;
            phase<=ALU_RETIRE;
        end
        // Capture after MAC special-register retirement; native ALU observes
        // that CCR, then writes its result before any current ALU operands.
        // Separating arithmetic from MEMSIZ masking cuts the measured path.
        ALU_RESULT:begin alu_saved_result<=alu_result;alu_saved_flags<=alu_flags;phase<=ALU_RETIRE;end
        ALU_RETIRE:if(retire_ready)begin
            if(alu_write)begin
                if(alu_update)ccr<=alu_saved_flags;
            end
            alu_a_reg<=insn[23:16];alu_op<=insn[15:12];alu_dst<=select[5:4];
            alu_write<=!skip || insn[15:12]==4;alu_update<=!insn[7] || insn[15:12]==4;
            if(insn[15:12]==15)begin
                end_in_step<=1;
                if(halt_asserted)halted<=1;
                if({1'b0,dbase}<increment)dbase<=dlength;
                else dbase<=24'({1'b0,dbase}-increment);
            end
            phase<=ALU_CAPTURE;
        end
        ALU_CAPTURE:if(rf_ack)begin
            if(insn[15:12]==15)begin
                // Native END preserves the pending operand latches.
            end else if(insn[15:12]>=8)begin
                alu_b<=select[7:6]==1 ? rf_read_b:{{8{dil[15]}},dil,8'b0};
            end else begin
                alu_a<=select[7:6]==1 ? rf_read_a:{{8{dil[15]}},dil,8'b0};
                alu_b<=rf_read_b;
            end
            // Without a physical delay write, operand capture is the last
            // operation of this instruction. Retire without a WRITE1 bubble.
            if(write_cycle==0 || write_cycle==2 || write_io)begin
                if(write_cycle!=0)begin dol0<=dol1;if(dol_count!=0)dol_count<=dol_count-1'b1;end
                pc<=end_in_step && !halted ? 8'd1:pc+1'b1;phase<=IDLE;done<=1;
            end else phase<=WRITE1;
        end
        WRITE1:if(write_cycle==0 || write_cycle==2 || write_io || dram_ack)begin
            if(write_cycle!=0)begin dol0<=dol1;if(dol_count!=0)dol_count<=dol_count-1'b1;end
            // Publish completion only after the exact write acknowledgement;
            // no extra state is needed to retire the already stable next PC.
            pc<=end_in_step && !halted ? 8'd1:pc+1'b1;phase<=IDLE;done<=1;
        end
        FINISH:begin pc<=end_in_step && !halted ? 8'd1:pc+1'b1;phase<=IDLE;done<=1;end
        default:phase<=IDLE;
        endcase
        if(reset || cold_reset)begin
            phase<=IDLE;pc<=0;halted<=0;fault<=0;done<=0;
            insn_seen<=0;offset_seen<=0;insn<=0;offset<=0;skip<=0;end_in_step<=0;
            address_started<=0;address_done<=0;mac_started<=0;mac_done<=0;
            next_cycle<=0;prev_cycle<=0;read_cycle<=0;write_cycle<=0;
            next_io<=0;prev_io<=0;read_io<=0;write_io<=0;
            next_addr<=0;prev_addr<=0;read_addr<=0;write_addr<=0;
            sigreg<=0;mulshift<=2;
            alu_saved_result<=0;alu_saved_flags<=0;
        end
        // Native device_reset preserves all of these after construction.
        if(cold_reset)begin
            machl<=0;mac_overflow<=0;ccr<=0;cmr<=0;dil<=0;dol0<=0;dol1<=0;dol_count<=0;
            dbase<=0;dlength<=0;abase<=0;bbase<=0;memshift<=24;
            mac_write<=0;mac_accumulate<=0;mac_dst<=0;mac_c_reg<=0;mac_c<=0;mac_d<=0;
            alu_write<=0;alu_update<=0;alu_dst<=0;alu_a_reg<=0;alu_op<=0;alu_a<=0;alu_b<=0;
            for(k=0;k<8;k=k+1)serial[k]<=0;
        end
    end
endmodule
