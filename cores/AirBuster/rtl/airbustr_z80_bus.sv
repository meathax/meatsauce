// SPDX-License-Identifier: GPL-3.0-or-later
// One board transaction per physical Z80 cycle, including writes held by WAIT.
module airbustr_z80_bus (
 input logic clk, reset, cpu_reset,
 input logic m1_n,mreq_n,iorq_n,rd_n,wr_n,rfsh_n,
 input logic [15:0] addr, input logic [7:0] data_out,irq_vector,
 output logic [7:0] data_in, output logic wait_n,irq_ack,
 output logic transaction_idle, loan_safe,
 output logic req_valid, input logic req_ready,
 output logic req_io,req_write, output logic [15:0] req_addr,
 output logic [7:0] req_data, input logic rsp_valid,
 input logic [7:0] rsp_data
);
 typedef enum logic [1:0] {IDLE,SEND,RESPONSE,DONE} state_t;
 state_t state;
 logic ack_seen;
 logic [7:0] read_data, vector_data;
 wire acknowledge = !m1_n && !iorq_n;
 wire access_cycle = (!rd_n || !wr_n) &&
     ((!mreq_n && rfsh_n) || (!iorq_n && m1_n));
 assign transaction_idle = state==IDLE && !access_cycle && !acknowledge;
    // Requires CPU pause and cleared adapter/cache/board ownership at admission.
    assign loan_safe = (state == IDLE && !access_cycle) || state == DONE;
 assign req_valid = state==SEND && !reset && !cpu_reset;
 wire accepted_response = state==RESPONSE && rsp_valid;
 assign wait_n = !access_cycle || state==DONE || accepted_response;
 assign data_in = acknowledge ? (ack_seen ? vector_data : irq_vector) :
                  accepted_response ? rsp_data : read_data;
 always_ff @(posedge clk) begin
  irq_ack <= 0;
  if(reset) begin
   state<=IDLE; ack_seen<=0; read_data<=8'hff; vector_data<=8'hff;
   req_io<=0; req_write<=0; req_addr<=0; req_data<=0;
  end else begin
   if(!acknowledge) ack_seen<=0;
   else if(!ack_seen && !cpu_reset) begin
    irq_ack<=1; ack_seen<=1; vector_data<=irq_vector;
   end
   case(state)
    IDLE: if(access_cycle && !cpu_reset) begin
     req_io<=!iorq_n; req_write<=!wr_n; req_addr<=addr;
     req_data<=data_out; state<=SEND;
    end
    SEND: if(cpu_reset) state<=IDLE;
      else if(req_ready) state<=RESPONSE;
    RESPONSE: if(rsp_valid) begin read_data<=rsp_data; state<=DONE; end
    DONE: if(!access_cycle) state<=IDLE;
    default: state<=IDLE;
   endcase
  end
 end
endmodule
