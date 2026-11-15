// Shared actual native T80pa pair and six original 16K program ROM slots.
// Control/reset/enables come unchanged from the selected board controller.
module snk_main_cpu_pair(
input wire clk,input wire [24:0] ioctl_addr,input wire [7:0] ioctl_data,input wire ioctl_wr,
input wire pair_a_reset_n,
input wire pair_a_cen_p,
input wire pair_a_cen_n,
input wire pair_a_wait_n,
input wire pair_a_int_n,
input wire pair_a_nmi_n,
input wire [7:0] pair_a_din,
output wire cpuA_nM1,
output wire cpuA_nMR,
output wire cpuA_nIO,
output wire cpuA_nRD,
output wire cpuA_nWR,
output wire cpuA_nRFSH,
output wire cpuA_nHALT,
output wire cpuA_nBUSACK,
output wire [15:0] cpuA_A,
output wire [7:0] cpuA_Dout,
output wire [7:0] pair_rom_a0,
output wire [7:0] pair_rom_a1,
output wire [7:0] pair_rom_a2,
input wire pair_b_reset_n,
input wire pair_b_cen_p,
input wire pair_b_cen_n,
input wire pair_b_wait_n,
input wire pair_b_int_n,
input wire pair_b_nmi_n,
input wire [7:0] pair_b_din,
output wire cpuB_nM1,
output wire cpuB_nMR,
output wire cpuB_nIO,
output wire cpuB_nRD,
output wire cpuB_nWR,
output wire cpuB_nRFSH,
output wire cpuB_nHALT,
output wire cpuB_nBUSACK,
output wire [15:0] cpuB_A,
output wire [7:0] cpuB_Dout,
output wire [7:0] pair_rom_b0,
output wire [7:0] pair_rom_b1,
output wire [7:0] pair_rom_b2
);
T80pa cpu_a(.CLK(clk),.R800_mode(1'b0),.REG(),.DIRSet(1'b0),.DIR(212'b0),.BUSRQ_n(1'b1),.OUT0(1'b0),.RESET_n(pair_a_reset_n),.CEN_p(pair_a_cen_p),.CEN_n(pair_a_cen_n),.WAIT_n(pair_a_wait_n),.INT_n(pair_a_int_n),.NMI_n(pair_a_nmi_n),.DI(pair_a_din),.M1_n(cpuA_nM1),.MREQ_n(cpuA_nMR),.IORQ_n(cpuA_nIO),.RD_n(cpuA_nRD),.WR_n(cpuA_nWR),.RFSH_n(cpuA_nRFSH),.HALT_n(cpuA_nHALT),.BUSAK_n(cpuA_nBUSACK),.A(cpuA_A),.DO(cpuA_Dout));
eprom_16K rom_a0(.CLK(clk),.ADDR(cpuA_A[13:0]),.DATA(pair_rom_a0),.CLK_DL(clk),.ADDR_DL(ioctl_addr[19:0]),.DATA_IN(ioctl_data),.WR(ioctl_wr),.CS_DL(ioctl_addr>=25'h00000 && ioctl_addr<25'h04000));
eprom_16K rom_a1(.CLK(clk),.ADDR(cpuA_A[13:0]),.DATA(pair_rom_a1),.CLK_DL(clk),.ADDR_DL(ioctl_addr[19:0]),.DATA_IN(ioctl_data),.WR(ioctl_wr),.CS_DL(ioctl_addr>=25'h04000 && ioctl_addr<25'h08000));
eprom_16K rom_a2(.CLK(clk),.ADDR(cpuA_A[13:0]),.DATA(pair_rom_a2),.CLK_DL(clk),.ADDR_DL(ioctl_addr[19:0]),.DATA_IN(ioctl_data),.WR(ioctl_wr),.CS_DL(ioctl_addr>=25'h08000 && ioctl_addr<25'h0c000));
T80pa cpu_b(.CLK(clk),.R800_mode(1'b0),.REG(),.DIRSet(1'b0),.DIR(212'b0),.BUSRQ_n(1'b1),.OUT0(1'b0),.RESET_n(pair_b_reset_n),.CEN_p(pair_b_cen_p),.CEN_n(pair_b_cen_n),.WAIT_n(pair_b_wait_n),.INT_n(pair_b_int_n),.NMI_n(pair_b_nmi_n),.DI(pair_b_din),.M1_n(cpuB_nM1),.MREQ_n(cpuB_nMR),.IORQ_n(cpuB_nIO),.RD_n(cpuB_nRD),.WR_n(cpuB_nWR),.RFSH_n(cpuB_nRFSH),.HALT_n(cpuB_nHALT),.BUSAK_n(cpuB_nBUSACK),.A(cpuB_A),.DO(cpuB_Dout));
eprom_16K rom_b0(.CLK(clk),.ADDR(cpuB_A[13:0]),.DATA(pair_rom_b0),.CLK_DL(clk),.ADDR_DL(ioctl_addr[19:0]),.DATA_IN(ioctl_data),.WR(ioctl_wr),.CS_DL(ioctl_addr>=25'h10000 && ioctl_addr<25'h14000));
eprom_16K rom_b1(.CLK(clk),.ADDR(cpuB_A[13:0]),.DATA(pair_rom_b1),.CLK_DL(clk),.ADDR_DL(ioctl_addr[19:0]),.DATA_IN(ioctl_data),.WR(ioctl_wr),.CS_DL(ioctl_addr>=25'h14000 && ioctl_addr<25'h18000));
eprom_16K rom_b2(.CLK(clk),.ADDR(cpuB_A[13:0]),.DATA(pair_rom_b2),.CLK_DL(clk),.ADDR_DL(ioctl_addr[19:0]),.DATA_IN(ioctl_data),.WR(ioctl_wr),.CS_DL(ioctl_addr>=25'h18000 && ioctl_addr<25'h1c000));
endmodule
