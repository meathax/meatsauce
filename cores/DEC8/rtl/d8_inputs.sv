// MiSTer pad bits to the pinned MAME port wiring. Vblank is merged in d8_sys.
module d8_inputs (
    input logic [3:0] i_machine,
    input logic i_ghost3,
    input logic i_ghost_no_start,
    input logic [11:0] i_joy0, i_joy1, i_joy2,
    output logic [7:0] o_in0, o_in1, o_in2, o_in3, o_coin
);
  wire [3:0] d0 = {i_joy0[0],i_joy0[1],i_joy0[2],i_joy0[3]};
  wire [3:0] d1 = {i_joy1[0],i_joy1[1],i_joy1[2],i_joy1[3]};
  wire [3:0] d2 = {i_joy2[0],i_joy2[1],i_joy2[2],i_joy2[3]};
  always_comb begin
    o_in0=8'hff; o_in1=8'hff; o_in2=8'hff; o_in3=8'hff; o_coin=8'hff;
    case (i_machine)
      4'd0: begin
        o_in0=~{1'b0,i_joy0[6:4],d0}; o_in1=~{1'b0,i_joy1[6:4],d1};
        o_in2={4'hf,~i_joy1[9],~i_joy0[9],2'b11};
        o_coin={~i_joy0[11],~i_joy0[10],~i_joy1[10],5'h1f};
      end
      4'd1: begin
        o_in0={4'h0,~d0}; o_in1={4'h0,~d1};
        o_in2={4'hf,~i_joy1[5],~i_joy1[4],~i_joy0[5],~i_joy0[4]};
        o_in3={6'h3f,~i_joy1[9],~i_joy0[9]};
        o_coin={1'b1,~i_joy1[10],~i_joy0[10],~i_joy0[11],4'hf};
      end
      4'd2: begin
        o_in0=~{i_joy1[9],i_joy0[9],i_joy0[5:4],i_joy0[2],i_joy0[3],i_joy0[1:0]};
        o_in1=~{2'b00,i_joy1[5:4],i_joy1[2],i_joy1[3],i_joy1[1:0]};
        o_coin={~i_joy0[11],~i_joy0[10],~i_joy1[10],5'h1f};
      end
      4'd3: begin
        o_in0=~{2'b00,i_joy0[5:4],d0}; o_in1=~{2'b00,i_joy1[5:4],d1};
        o_in2={4'hf,~i_joy1[9],~i_joy0[9],2'b11};
        o_coin={~i_joy0[11],~i_joy1[10],~i_joy0[10],5'h1f};
      end
      4'd4: begin
        o_in0=~{i_joy1[9],i_joy0[9],i_joy0[5:4],d0};
        o_in1=~{2'b00,i_joy1[5:4],d1};
        o_coin={1'b1,~i_joy1[10],~i_joy0[10],~i_joy0[11],4'hf};
      end
      4'd5,4'd6: begin
        o_in0=~{2'b00,i_joy0[5:4],d0}; o_in1=~{2'b00,i_joy1[5:4],d1};
        if (i_machine==4'd6 || !i_ghost_no_start)
          o_in3={6'h3f,~i_joy1[9],~i_joy0[9]}; // starts are read through DSW0
        if (i_machine==4'd6)
          o_coin={~i_joy0[10],~i_joy1[10],1'b1,~i_joy0[11],4'hf};
        else begin
          o_coin={i_ghost3 ? ~i_joy2[10] : 1'b1,~i_joy1[10],~i_joy0[10],~i_joy0[11],4'hf};
          if (i_ghost3) o_in2=~{2'b00,i_joy2[5:4],d2};
        end
      end
      4'd7: begin
        o_in0=~{2'b00,i_joy0[5:4],d0}; o_in1=~{2'b00,i_joy1[5:4],d1};
        o_in2={4'hf,~i_joy1[9],~i_joy0[9],2'b11};
        o_coin={1'b1,~i_joy0[10],~i_joy1[10],~i_joy0[11],4'hf};
      end
      4'd8: begin                       // Psycho-Nics Oscar (dec8.cpp INPUT_PORTS oscar)
        o_in0=~{i_joy0[9],i_joy0[6:4],d0}; o_in1=~{i_joy1[9],i_joy1[6:4],d1};
        o_in2={5'h1f,~i_joy0[11],~i_joy0[10],~i_joy1[10]};   // service, coin 1, coin 2
      end
      4'd9: begin   // Cobra-Command: IN0/IN1 up,down,left,right,fire,missile,-,start; IN2 coin1,coin2,service
        o_in0=~{i_joy0[9],1'b0,i_joy0[5:4],d0}; o_in1=~{i_joy1[9],1'b0,i_joy1[5:4],d1};
        o_in2={5'h1f,~i_joy0[11],~i_joy1[10],~i_joy0[10]};
      end
    endcase
  end
endmodule
