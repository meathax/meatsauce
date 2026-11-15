// ES5510 functional execution core, derived from ESP specification Rev.2.4.
// Integrated through rf_es5510_audio in Rayforce.sv. Physical audio remains unqualified.
// The fabric FSM preserves instruction-visible ordering (pp26-30), not the
// pin-level 3T waveform. No timing exceptions or alternate clock are needed.
// External RAM addresses are left-justified 24-bit chip addresses. A board
// adapter, not MEMSIZ, determines physical capacity and aliasing.
module rf_es5510_core(
    input wire clk,reset,
    input wire host_we,input wire [7:0] host_addr,host_wdata,
    output reg [7:0] host_rdata,
    input wire sample_start,halt,
    input wire [127:0] serial_in,
    output wire [127:0] serial_out,
    output reg busy,done,fault,
    output reg [7:0] pc,
    output wire ram_req,ram_write,ram_io,
    output wire [23:0] ram_addr,
    output wire [15:0] ram_wdata,
    input wire ram_ack,input wire [15:0] ram_rdata,
    // for the delay-memory adapter (rf_esp_mem) and the host CPU's wait
    output wire [15:0] dbase_word,
    output wire [16:0] ring_words,
    output wire ram_exec,
    output reg  [7:0] ram_pc,
    output wire host_wait,
    // DIL consumption, for rf_esp_mem to prefetch only reads that are used
    output reg  dil_use,
    output reg  [7:0] dil_pc
);
    reg [23:0] gpr[0:191];
    reg [47:0] program_mem[0:159];
    reg [15:0] serial[0:7];
    reg signed [49:0] accumulator;
    reg [23:0] memsiz,dlength,abase,bbase,dbase,sigreg;
    reg [7:0] ccr,cmr,serial_control;
    reg [15:0] dil,dol_first,dol_second,dol_last;
    reg [1:0] dol_count;
    reg [23:0] host_gpr,host_dadr;
    reg [47:0] host_instruction;
    reg [15:0] host_dol;
    reg [1:0] host_ram_mode;
    reg refresh_disable,clear_busy,host_pending,host_memory_pending;
    reg ram_gap,sample_pending;
    reg [7:0] select_addr,select_command;
    reg [23:0] pending_gpr,host_memory_addr;
    reg [47:0] pending_instruction;
    reg [15:0] host_memory_data;
    reg host_memory_write,host_memory_io,abort_pending;
    reg [23:0] clear_addr;
    reg [2:0] phase;
    reg draining;
    reg [47:0] ir;
    reg [23:0] current_address;
    reg [2:0] current_ram_control;
    reg memory_valid;
    reg [23:0] memory_address;
    reg [2:0] memory_control;
    reg signed [23:0] mul_c,mul_d,alu_a,alu_b;
    reg pending_mul,pending_alu,pending_flags;
    reg mul_accumulate,mul_to_reg,mul_to_fifo,alu_to_reg,alu_to_fifo;
    reg [7:0] mul_dest,alu_dest,alu_ccr;
    reg signed [49:0] mul_product;
    reg [23:0] alu_result_pending;
    reg skip_current;
    reg [7:0] initialize_index;
    reg initializing;
    wire [3:0] mode=ir[11:8];
    wire [3:0] opcode=ir[15:12];
    wire [23:0] alu_result;
    wire [7:0] alu_flags;
    wire alu_writes;
    wire signed [47:0] product=mul_c*mul_d;
    wire signed [49:0] normalized=$signed({{2{product[47]}},product}) <<< (sigreg[22]?1:2);
    wire signed [49:0] next_accumulator=mul_accumulate ? accumulator+mul_product : mul_product;
    wire [23:0] decrement=memsiz+24'd1;
    rf_es5510_alu alu(.opcode(opcode),.a(alu_a),.b(alu_b),.ccr(ccr),
        .result(alu_result),.next_ccr(alu_flags),.write_result(alu_writes));
    genvar lane;
    generate for(lane=0;lane<8;lane=lane+1)begin: lanes
        assign serial_out[lane*16+:16]=serial[lane];
    end endgenerate

    function automatic [47:0] saturated_mac(input signed [49:0] value);
        if(value>50'sh07fffffffffff)saturated_mac=48'h7fffffffffff;
        else if(value < -50'sh0800000000000)saturated_mac=48'h800000000000;
        else saturated_mac=value[47:0];
    endfunction
    reg [47:0] program_read;
    // Explicit synchronous ports with separate forwarding preserve the old
    // instruction schedule. Phase1/3 writes precede phase2/4 operand capture.
    wire selecting=host_we && (host_addr==128 || host_addr==160 || host_addr==192 || host_addr==224);
    wire [7:0] idle_read_addr=selecting?host_wdata:select_addr;
    wire [7:0] read_addr_a=!busy ? idle_read_addr : phase==0 ? pc : phase==1 ? program_read[39:32] : ir[23:16];
    wire [7:0] read_addr_b=phase==1 ? program_read[47:40] : ir[31:24];
    // Select commands commit at END, as the chip does (pp31-32). With the
    // delay RAM on chip a sample takes ~900 clocks, and the host CPU is held
    // on its next ESP access (host_wait) until the command has committed.
    // The GPR/program read ports are addressed by the running program while
    // busy, so a read select may only commit after one idle clock has fetched
    // select_addr (idle_q); otherwise it latches the program's last operand.
    reg idle_q;
    wire host_ready=idle_q;
    wire host_commit=!busy && host_ready && host_pending && !(host_memory_pending && ram_req && ram_ack) && !(!host_memory_pending && clear_busy && ram_req && ram_ack);
    wire host_write_gpr=host_commit && (select_command==8'ha0 || select_command==8'he0) && select_addr<192;
    wire mul_write_gpr=busy && phase==1 && pending_mul && mul_to_reg && mul_dest<192;
    wire alu_write_gpr=busy && phase==3 && pending_alu && alu_to_reg && alu_dest<192;
    wire gpr_we=!reset && (initializing || host_write_gpr || mul_write_gpr || alu_write_gpr);
    wire [7:0] gpr_waddr=initializing?initialize_index:host_write_gpr?select_addr:mul_write_gpr?mul_dest:alu_dest;
    wire [47:0] commit_mac=saturated_mac(next_accumulator);
    wire [23:0] gpr_wdata=initializing?24'd0:host_write_gpr?pending_gpr:mul_write_gpr?commit_mac[47:24]:alu_result_pending;
    wire program_we=!reset && ((initializing && initialize_index<160) || (host_commit && (select_command==8'hc0 || select_command==8'he0) && select_addr<160));
    wire [7:0] program_waddr=initializing?initialize_index:select_addr;
    wire [47:0] program_wdata=initializing?48'd0:pending_instruction;
    reg [23:0] gpr_raw_a,gpr_raw_b,forward_data;
    reg forward_a,forward_b;
    always @(posedge clk) begin
        if(gpr_we)gpr[gpr_waddr]<=gpr_wdata;
        gpr_raw_a<=gpr[read_addr_a];gpr_raw_b<=gpr[read_addr_b];
        forward_a<=gpr_we && gpr_waddr==read_addr_a;
        forward_b<=gpr_we && gpr_waddr==read_addr_b;
        forward_data<=gpr_wdata;
    end
    always @(posedge clk) begin
        if(program_we)program_mem[program_waddr]<=program_wdata;
        program_read<=program_mem[busy?pc:idle_read_addr];
    end
    wire [23:0] gpr_read_a=forward_a?forward_data:gpr_raw_a;
    wire [23:0] gpr_read_b=forward_b?forward_data:gpr_raw_b;
    // Serial registers are live special operands, not part of the GPR RAM.
    wire [7:0] serial_operand_a=!busy?select_addr:phase==2?ir[39:32]:ir[23:16];
    wire [7:0] serial_operand_b=phase==2?ir[47:40]:ir[31:24];
    wire [2:0] serial_addr_a=serial_operand_a-8'd234;
    wire [2:0] serial_addr_b=serial_operand_b-8'd234;
    wire [15:0] serial_read_a=serial[serial_addr_a];
    wire [15:0] serial_read_b=serial[serial_addr_b];

    function automatic [23:0] read_register(input [7:0] addr,input [23:0] gpr_value,input [15:0] serial_value);
        reg [47:0] mac;
        begin
            mac=saturated_mac(accumulator);
            if(addr<192)read_register=gpr_value;
            else if(addr>=234 && addr<=241)read_register={serial_value,8'd0};
            else case(addr)
                242:read_register=mac[23:0];243:read_register=mac[47:24];
                244:read_register={dil,8'd0};245:read_register=dlength;
                246:read_register=abase;247:read_register=bbase;248:read_register=dbase;
                249:read_register=sigreg;250:read_register={ccr,16'd0};251:read_register={cmr,16'd0};
                252:read_register=24'hffffff;253:read_register=24'h800000;
                254:read_register=24'h7fffff;default:read_register=0;
            endcase
        end
    endfunction
    function automatic [23:0] low_ones(input [23:0] v);
        low_ones=(v^(v+24'd1))>>1;      // MAME countLowOnes: 0000FF -> 0000FF
    endfunction
    task write_register(input [7:0] addr,input [23:0] value);
        begin
            if(addr<192)begin end // GPR writes use the single explicit RAM port.
            else if(addr>=234 && addr<=241)serial[addr-234]<=value[23:8];
            else case(addr)
                242:accumulator[23:0]<=value;
                243:accumulator[49:24]<={{2{value[23]}},value};
                // MEMSIZ is the run of low one bits of the value and masks DBASE;
                // DLENGTH/ABASE/BBASE/DBASE keep all 24 bits as written, because
                // the drivers' boot self-test writes FFFFFF to them and reads it
                // back (a mismatch is event 33: "Unexpected EventID", no sound).
                // Address arithmetic masks with MEMSIZ where it uses them.
                244:begin memsiz<=low_ones(value);dbase<=dbase&~low_ones(value);end
                245:dlength<=value;
                246:abase<=value;247:bbase<=value;
                248:dbase<=value;249:sigreg<=value;   // only bit22 (product shift) acts; readback keeps all bits (PB3 driver reads it back)
                250:ccr<=value[23:16]&8'hf8;251:cmr<=value[23:16]&8'hfc;
                default:;
            endcase
        end
    endtask
    task push_dol(input [23:0] value);
        begin
            // p18: retain newest two words on overflow, last word on underflow.
            dol_last<=value[23:8];
            if(dol_count==0)begin dol_first<=value[23:8];dol_count<=1;end
            else if(dol_count==1)begin dol_second<=value[23:8];dol_count<=2;end
            else begin dol_first<=dol_second;dol_second<=value[23:8];end
        end
    endtask
    function automatic [23:0] address_for(input [2:0] control,input [23:0] offset);
        reg [24:0] sum;
        begin
            case(control)
                0,1,5:begin
                    sum={1'b0,dbase}+{1'b0,offset};
                    // p14: delay range includes both address zero and DLENGTH.
                    // Compare physical (integer) bits, ignoring fraction.
                    if((sum & {1'b1,~memsiz}) > {1'b0,(dlength & ~memsiz)})
                        sum=sum-({1'b0,(dlength & ~memsiz)}+{1'b0,decrement});
                    address_for=sum[23:0]&~memsiz;
                end
                2,3:address_for=abase+offset;
                4:address_for=bbase+offset;
                default:address_for=offset;
            endcase
        end
    endfunction
    function automatic mul_uses_dil(input [3:0] sel);
        mul_uses_dil=(sel==3 || sel==4 || sel==6 || sel==8 || sel==12 || sel==13 || sel==15);
    endfunction
    function automatic mul_fifo(input [3:0] sel);
        mul_fifo=(sel==1 || sel==2 || sel==4 || sel==10 || sel==11 || sel==13);
    endfunction
    function automatic alu_fifo(input [3:0] sel);
        alu_fifo=(sel==5 || sel==6 || sel==7 || sel==8 || sel==14 || sel==15);
    endfunction

    // One external request at a time, stable through ACK. Host/clear can only
    // own RAM when execution is idle. Request must fall before another starts.
    wire execution_memory=busy && phase==6 && memory_valid;
    wire host_memory=!busy && host_memory_pending;
    wire clearing=!busy && !host_memory_pending && clear_busy;
    assign ram_req=!reset && !initializing && !ram_gap && (execution_memory || host_memory || clearing);
    assign ram_addr=execution_memory?memory_address:host_memory?host_memory_addr:clear_addr;
    assign ram_write=execution_memory?(memory_control==1 || memory_control==3 || memory_control==7):host_memory?host_memory_write:1'b1;
    assign ram_io=execution_memory?(memory_control>=6):host_memory?host_memory_io:1'b0;
    assign ram_wdata=execution_memory?(dol_count==0?dol_last:dol_first):host_memory?host_memory_data:16'd0;

    always @* begin
        host_rdata=0;
        case(host_addr)
            0:host_rdata=host_gpr[23:16];1:host_rdata=host_gpr[15:8];2:host_rdata=host_gpr[7:0];
            3:host_rdata=host_instruction[47:40];4:host_rdata=host_instruction[39:32];
            5:host_rdata=host_instruction[31:24];6:host_rdata=host_instruction[23:16];
            7:host_rdata=host_instruction[15:8];8:host_rdata=host_instruction[7:0];
            9:host_rdata=dil[15:8];10:host_rdata=dil[7:0];11:host_rdata=0;
            12:host_rdata=host_dol[15:8];13:host_rdata=host_dol[7:0];14:host_rdata=8'hff;
            15:host_rdata=host_dadr[23:16];16:host_rdata=host_dadr[15:8];17:host_rdata=host_dadr[7:0];
            // MAME returns 0 for host control and 0x27 for the PC; the sound
            // drivers poll both and were proven against those answers. The
            // CPU is held (host_wait) while a command is still pending.
            18:host_rdata=8'h00;
            20:host_rdata={host_ram_mode,6'h3f};22:host_rdata=8'h27;
            24:host_rdata=serial_control;128:host_rdata=select_addr;
            default:;
        endcase
    end
    assign dbase_word=dbase[23:8];
    assign ring_words={1'b0,(dlength & ~memsiz)>>8}+17'd1;
    assign ram_exec=execution_memory;
    reg clear_request;
    assign host_wait=host_pending || host_memory_pending || clear_request || initializing;
    integer i;
    reg [47:0] mac_word;
    always @(posedge clk) begin
        done<=0;dil_use<=0;idle_q<=!busy;
        if(reset)begin
            initializing<=1;initialize_index<=0;busy<=0;done<=0;fault<=0;
            phase<=0;pc<=0;draining<=0;pending_mul<=0;pending_alu<=0;pending_flags<=0;
            memory_valid<=0;host_pending<=0;host_memory_pending<=0;abort_pending<=0;clear_busy<=0;
            ram_gap<=0;sample_pending<=0;clear_request<=0;ram_pc<=0;
            host_gpr<=0;host_instruction<=0;host_dadr<=0;host_dol<=0;host_ram_mode<=0;
            select_addr<=255;select_command<=0;refresh_disable<=1;serial_control<=0;
            accumulator<=0;memsiz<=24'h0000ff;dlength<=0;abase<=0;bbase<=0;dbase<=0;sigreg<=0;
            ccr<=0;cmr<=0;dil<=0;dol_count<=0;dol_first<=0;dol_second<=0;dol_last<=0;clear_addr<=0;
            for(i=0;i<8;i=i+1)serial[i]<=0;
        end else if(initializing)begin
            if(initialize_index==191)initializing<=0;
            else initialize_index<=initialize_index+1'b1;
        end else begin
            // ACK retires one command. Leave a full low-request cycle before
            // issuing another, including consecutive clear/host transactions.
            ram_gap<=ram_req && ram_ack;
            if(clear_request && !busy && !host_memory_pending && !clear_busy)begin
                clear_request<=0;clear_busy<=1;clear_addr<=dlength&~memsiz;dbase<=dlength&~memsiz;
            end
            if(halt)sample_pending<=0;
            if(sample_start)begin
                // Serial transfers continue while halted, independent of host
                // access. Only input-configured lanes accept external samples.
                for(i=0;i<8;i=i+1)if(!serial_control[2+(i/2)])serial[i]<=serial_in[i*16+:16];
                if(busy)fault<=1;
                else if(!halt)begin
                    if(sample_pending)fault<=1;
                    sample_pending<=1;
                end
            end
            if(!busy)begin
                if(host_memory_pending && ram_req && ram_ack)begin
                    if(!host_memory_write)dil<=ram_rdata;
                    host_memory_pending<=0;
                end else if(clearing && ram_req && ram_ack)begin
                    // Clear only the configured delay range (p41), not all RAM.
                    if(clear_addr==0)begin clear_busy<=0;dbase<=0;end
                    else begin clear_addr<=clear_addr-decrement;dbase<=clear_addr-decrement;end
                end else if(host_pending)begin
                    // wait one idle clock for the read ports (host_commit)
                    if(host_ready)begin
                    if(select_command==8'h80)begin
                        // A reserved select is also used to park host access
                        // outside the GPR refresh array (p41). It selects no
                        // implemented operand; retain the existing host latch.
                        if(select_addr<192 || select_addr>=234)
                            host_gpr<=read_register(select_addr,gpr_read_a,serial_read_a);
                        if(select_addr<160)host_instruction<=program_read;
                    end else begin
                        if(select_command==8'ha0 || select_command==8'he0)write_register(select_addr,pending_gpr);
                    end
                    host_pending<=0;
                    end
                end else if(sample_pending && !halt && !clear_busy && !host_memory_pending && !ram_gap)begin
                    busy<=1;phase<=0;pc<=0;draining<=0;
                    sample_pending<=0;
                    pending_mul<=0;pending_alu<=0;pending_flags<=0;memory_valid<=0;dol_count<=0;
                end
            end else begin
                case(phase)
                    0:begin
                        if(!draining)begin
                            if(pc>=160)begin fault<=1;abort_pending<=1;end
                            else begin
                                // Synchronous instruction/offset reads occur
                                // on this edge and are consumed in phase1.
                            end
                        end
                        phase<=1;
                    end
                    1:begin
                        if(!draining)begin
                            ir<=program_read;
                            current_ram_control<=program_read[5:3];
                            current_address<=address_for(program_read[5:3],gpr_read_a);
                        end
                        // Commit MUL N-1 before reading MUL N, but ALU N-1
                        // remains pending until after MUL N's operand fetch.
                        if(pending_mul)begin
                            accumulator<=next_accumulator;mac_word=saturated_mac(next_accumulator);
                            if(mul_to_reg)write_register(mul_dest,mac_word[47:24]);
                            if(mul_to_fifo)push_dol(mac_word[47:24]);
                        end
                        phase<=2;
                    end
                    2:begin
                        if(!draining)begin
                            mul_c<=mul_uses_dil(mode)?{dil,8'd0}:read_register(ir[39:32],gpr_read_a,serial_read_a);
                            dil_use<=mul_uses_dil(mode) || ir[39:32]==244 || ir[47:40]==244;
                            mul_d<=read_register(ir[47:40],gpr_read_b,serial_read_b);
                        end
                        phase<=3;
                    end
                    3:begin
                        if(pending_alu)begin
                            if(alu_to_reg)write_register(alu_dest,alu_result_pending);
                            if(alu_to_fifo)push_dol(alu_result_pending);
                        end
                        if(pending_flags)ccr<=alu_ccr;
                        phase<=4;
                    end
                    4:begin
                        if(!draining)begin
                            // Unary DIL operations name F4 explicitly in B
                            // (p20); DIL selection replaces A for binary ops.
                            alu_a<=mode>=9?{dil,8'd0}:read_register(ir[23:16],gpr_read_a,serial_read_a);
                            dil_use<=mode>=9 || ir[23:16]==244 || ir[31:24]==244;
                            alu_b<=read_register(ir[31:24],gpr_read_b,serial_read_b);
                            skip_current<=ir[7] && ((|(ccr[7:3]&cmr[7:3]))^cmr[2]);
                        end
                        phase<=5;
                    end
                    5:begin
                        if(!draining)begin
                            pending_mul<=!skip_current;
                            mul_product<=normalized;mul_accumulate<=ir[6];mul_dest<=ir[39:32];
                            mul_to_reg<=mode!=1 && mode!=10;mul_to_fifo<=mul_fifo(mode);
                            pending_alu<=alu_writes && (!skip_current || opcode==4'h4);
                            alu_result_pending<=alu_result;alu_dest<=ir[23:16];
                            alu_to_reg<=mode!=5 && mode!=6;alu_to_fifo<=alu_fifo(mode);
                            // CMP is unconditional; otherwise a skippable
                            // instruction preserves flags even when executed.
                            pending_flags<=opcode==4'h4 || (!ir[7] && opcode!=9 && opcode!=15);
                            alu_ccr<=alu_flags;
                        end else begin pending_mul<=0;pending_alu<=0;pending_flags<=0;end
                        phase<=6;
                    end
                    6:begin
                        if(!memory_valid || (ram_req && ram_ack))begin
                            if(memory_valid)begin
                                if(!ram_write)begin dil<=ram_rdata;dil_pc<=ram_pc;end
                                if(memory_control[0] && dol_count!=0)begin
                                    dol_first<=dol_second;dol_count<=dol_count-1'b1;
                                end
                            end
                            memory_valid<=0;phase<=7;
                        end
                    end
                    7:begin
                        if(draining)begin
                            busy<=0;done<=1;pc<=0;dol_count<=0;
                            dbase<=(dbase<decrement)?(dlength&~memsiz):(dbase-decrement);
                        end else begin
                            memory_valid<=1;memory_address<=current_address;memory_control<=current_ram_control;
                            ram_pc<=pc;
                            if(opcode==15)draining<=1;
                            else pc<=pc+1'b1;
                        end
                        phase<=0;
                    end
                endcase
                // Do not abandon an external command already presented.
                if(abort_pending && !execution_memory)begin
                    busy<=0;memory_valid<=0;pending_mul<=0;pending_alu<=0;pending_flags<=0;
                    abort_pending<=0;dol_count<=0;
                end
            end
            // Host latches remain accessible during execution. Select commands
            // wait for END; no mid-program register overwrite (pp31-32).
            if(host_we)case(host_addr)
                0:host_gpr[23:16]<=host_wdata;1:host_gpr[15:8]<=host_wdata;2:host_gpr[7:0]<=host_wdata;
                3:host_instruction[47:40]<=host_wdata;4:host_instruction[39:32]<=host_wdata;
                5:host_instruction[31:24]<=host_wdata;6:host_instruction[23:16]<=host_wdata;
                7:host_instruction[15:8]<=host_wdata;8:host_instruction[7:0]<=host_wdata;
                12:host_dol[15:8]<=host_wdata;13:host_dol[7:0]<=host_wdata;
                15:begin
                    host_dadr[23:16]<=host_wdata;
                    // served when execution is idle; never dropped
                    if(!host_memory_pending && !clear_busy && !clear_request)begin
                        host_memory_pending<=1;host_memory_addr<={host_wdata,host_dadr[15:0]};
                        host_memory_data<=host_dol;host_memory_write<=!host_ram_mode[1];host_memory_io<=!host_ram_mode[0];
                    end else fault<=1;
                end
                16:host_dadr[15:8]<=host_wdata;17:host_dadr[7:0]<=host_wdata;
                18:begin
                    refresh_disable<=host_wdata[0];
                    if(host_wdata[1] && !host_wdata[0] && !clear_busy)clear_request<=1;
                end
                20:host_ram_mode<=host_wdata[7:6];24:serial_control<=host_wdata;
                31:if(halt && busy)abort_pending<=1;
                128,160,192,224:begin
                    if(host_pending)fault<=1;
                    else begin
                        host_pending<=1;select_addr<=host_wdata;select_command<=host_addr;
                        pending_gpr<=host_gpr;pending_instruction<=host_instruction;
                    end
                end
                default:;
            endcase
        end
    end
endmodule
