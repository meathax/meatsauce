// Real RTL miter for scaled legacy versus aligned read/control pipelines.
// This is not a CPU, game, fitted timing or full-size resource test.
module SoundInferenceTB;
    logic clk=0, load_wr=0, sound_io_rd=0;
    logic [24:0] load_addr=0;
    logic [15:0] load_data=0, za=0;
    logic [7:0] sound_io_read_data=0, ram_data=0, sound_latch=0;
    wire [7:0] legacy, aligned;
    logic [31:0] random_state=32'h9d270321;
    integer checked=0, collisions=0;
    SoundLegacy old_model (.zdin(legacy),.*);
    SoundAligned new_model (.zdin(aligned),.*);
    task tick(input bit compare_output);
        clk=0; #1; clk=1; #1;
        if (compare_output) begin
            checked++;
            if (legacy !== aligned)
                $fatal(1,"DI mismatch at check %0d addr=%h old=%h new=%h",checked,za,legacy,aligned);
        end
    endtask
    initial begin
        // Initialize every location through the real write port before comparison.
        load_wr=1;
        for (integer i=0;i<1024;i++) begin
            load_addr=25'h20100+25'(i*2);
            load_data=16'((i*197)^16'h9531);
            tick(0);
        end
        load_wr=0;
        for (integer i=0;i<60000;i++) begin
            random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
            za=random_state[15:0];
            case (i%7)
                0:za=16'hc000+16'(random_state[10:0]);
                1:za=16'he000;
                2:za=16'hf123;
                default:za={1'b0,random_state[14:0]};
            endcase
            sound_io_rd=random_state[16];
            sound_io_read_data=random_state[24:17];
            ram_data=random_state[31:24];
            sound_latch=random_state[11:4];
            load_wr=(i%5==0);
            // Exercise same-address read/write collisions as well as unrelated writes.
            if (i%10==0) begin
                load_addr=25'h20100+25'({za[10:1],1'b0});
                collisions++;
            end else load_addr=25'h20100+25'({random_state[9:0],1'b0});
            load_data=random_state[31:16];
            tick(1);
        end
        $display("PASS checked=%0d explicit_same_address_writes=%0d",checked,collisions);
        $finish;
    end
endmodule
