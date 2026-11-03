// SPY's two 256KiB PCM ROMs each mirror bank bit1. Cache both physical bank
// regions ahead of both channels, without changing donor sample/divider state.
module spy_pcm_prefetch(
    input wire clk,reset,pause,
    input wire [16:0] a_addr,b_addr,
    input wire a_cs,b_cs,bank_a,bank_b,a_stride,b_stride,
    output wire [7:0] a_data,b_data,
    output wire a_ready,b_ready,
    output reg pending=1'b0,target,
    output reg [18:0] request_tag,
    input wire [31:0] rom_data,
    input wire rom_ok
);
    // Four block positions per channel and per physical bank. A position is
    // reusable only when its upper address tag also matches.
    reg [15:0] valid;
    reg [14:0] tags[0:15];
    reg [31:0] words[0:15];
    // Nibble-stride mode advances every nibble: four predicted sample addresses
    // have distinct low byte bits, but can share the normal word-index bits.
    wire [3:0] a_slot={1'b0,bank_a,a_stride?a_addr[1:0]:a_addr[3:2]};
    wire [3:0] b_slot={1'b1,bank_b,b_stride?b_addr[1:0]:b_addr[3:2]};
    assign a_ready=!a_cs||(valid[a_slot]&&tags[a_slot]==a_addr[16:2]);
    assign b_ready=!b_cs||(valid[b_slot]&&tags[b_slot]==b_addr[16:2]);
    assign a_data=words[a_slot]>>(a_addr[1:0]*8);
    assign b_data=words[b_slot]>>(b_addr[1:0]*8);
    reg [3:0] rotor,chosen_id,issued_id;
    reg [3:0] chosen_slot,issued_slot;
    reg discard;
    reg choose;
    reg [18:0] chosen_address;
    reg chosen_channel;
    integer n,idx,level;
    reg channel,bank,active,stride;
    reg [16:0] current,lookahead;
    reg [14:0] word_index;
    reg [3:0] slot;
    function automatic [16:0] stride_address(input [16:0] current_address,input [1:0] steps);
        begin
            stride_address[3:0]=current_address[3:0]+steps;
            stride_address[7:4]=current_address[7:4]+steps;
            stride_address[11:8]=current_address[11:8]+steps;
            stride_address[16:12]=current_address[16:12]+steps;
        end
    endfunction
    always @* begin
        choose=0;chosen_address=0;chosen_channel=0;chosen_id=rotor;chosen_slot=0;
        idx=0;level=0;channel=0;bank=0;active=0;stride=0;current=0;lookahead=0;word_index=0;slot=0;
        // Demand bytes take priority, including a cold play/start or bank write.
        if(a_cs&&!a_ready)begin
            choose=1;chosen_address={1'b0,bank_a,a_addr[16:2],2'b00};chosen_channel=0;chosen_slot=a_slot;
        end else if(b_cs&&!b_ready)begin
            choose=1;chosen_address={1'b0,bank_b,b_addr[16:2],2'b00};chosen_channel=1;chosen_slot=b_slot;
        end else begin
            // Round robin across both channels/banks and four lookahead levels.
            // Normal byte mode reserves current block plus the following three.
            for(n=0;n<16;n=n+1)begin
                idx=(rotor+n)&15;level=idx>>2;channel=(idx>>1)&1;bank=idx&1;
                current=channel?b_addr:a_addr;active=channel?b_cs:a_cs;stride=channel?b_stride:a_stride;
                word_index=current[16:2]+15'(level);
                lookahead=stride?stride_address(current,2'(level)):{word_index,2'b00};
                slot={channel,bank,stride?lookahead[1:0]:lookahead[3:2]};
                if(!choose&&active&&(!valid[slot]||tags[slot]!=lookahead[16:2]))begin
                    choose=1;chosen_address={1'b0,bank,lookahead[16:2],2'b00};
                    chosen_channel=channel;chosen_id=4'(idx);chosen_slot=slot;
                end
            end
        end
    end
    integer k;
    always @(posedge clk)begin
        if(reset)begin
            valid<=0;rotor<=0;
            // A watchdog/menu sound reset does not reset the shared ROM backend.
            // Keep its accepted request stable until ACK, then discard the old
            // reply. Power-up pending=0 is a defined FPGA configuration bit.
            if(pending&&rom_ok)pending<=0;
            discard<=pending&&!rom_ok;
            if(!pending)begin target<=0;request_tag<=0;issued_id<=0;issued_slot<=0;end
            for(k=0;k<16;k=k+1)begin tags[k]<=0;words[k]<=32'h40404040;end
        end else if(pending&&rom_ok)begin
            if(!discard)begin
                words[issued_slot]<=rom_data;
                tags[issued_slot]<=request_tag[16:2];
                valid[issued_slot]<=1;
                rotor<=issued_id+1'b1;
            end
            pending<=0;discard<=0;
        end else if(!pending&&!pause&&choose)begin
            request_tag<=chosen_address;target<=chosen_channel;issued_id<=chosen_id;issued_slot<=chosen_slot;pending<=1;
        end
    end
endmodule
