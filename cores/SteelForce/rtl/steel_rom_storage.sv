// Shared serialized ROM load/read path. The owner and payload are registered.
// Raw IOCTL bytes enter the verified scatter mapper; SDRAM writes are whole words.
module steel_rom_storage(
    input wire clk,reset,mortalr,
    input wire ioctl_download,ioctl_wr,
    input wire [15:0] ioctl_index,
    input wire [24:0] ioctl_addr,
    input wire [7:0] ioctl_din,
    output wire ioctl_wait,image_valid,image_mortalr,download_active,error,
    input wire read_request,
    input wire [24:0] read_address,
    output reg read_accepted,read_acknowledged,
    output wire [63:0] read_data,
    output wire read_ready,
    output wire [12:0] sdram_address,
    output wire [1:0] sdram_bank,sdram_dqm,
    output wire sdram_cs_n,sdram_ras_n,sdram_cas_n,sdram_we_n,sdram_drive,
    output wire [15:0] sdram_data_out,
    input wire [15:0] sdram_data_in
);
    localparam IDLE=0,WAIT_DONE=1,DROP=2;
    reg [1:0] state;
    reg request,owner_write,loader_ack;
    reg [24:0] address;
    reg [15:0] data;
    reg [1:0] strobes;
    wire loader_write,loader_error,backend_ready,backend_ack,backend_error;
    wire [22:0] loader_address;
    wire [15:0] loader_data;
    wire loader_ready=state==IDLE && backend_ready;
    assign read_ready=loader_ready && image_valid && !download_active;
    assign error=loader_error || backend_error;
    steel_rom_download loader(.clk(clk),.reset(reset),.mortalr(mortalr),
        .memory_ready(loader_ready),.ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),
        .ioctl_index(ioctl_index),.ioctl_addr(ioctl_addr),.ioctl_din(ioctl_din),
        .ioctl_wait(ioctl_wait),.memory_write(loader_write),
        .memory_addr(loader_address),.memory_data(loader_data),.memory_ack(loader_ack),
        .image_valid(image_valid),.download_error(loader_error),
        .active(download_active),.image_mortalr(image_mortalr));
    steel_sdram_backend backend(.clk(clk),.reset(reset),.request(request),.write(owner_write),
        .address(address),.write_data(data),.write_strobes(strobes),.accepted(),
        .acknowledged(backend_ack),.protocol_error(backend_error),.ready(backend_ready),
        .busy(),.read_data(read_data),.sdram_address(sdram_address),.sdram_bank(sdram_bank),
        .sdram_dqm(sdram_dqm),.sdram_cs_n(sdram_cs_n),.sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n),.sdram_we_n(sdram_we_n),.sdram_drive(sdram_drive),
        .sdram_data_out(sdram_data_out),.sdram_data_in(sdram_data_in));
    always @(posedge clk) begin
        if(reset)begin
            state<=IDLE;request<=0;owner_write<=0;loader_ack<=0;
            address<=0;data<=0;strobes<=0;read_accepted<=0;read_acknowledged<=0;
        end else begin
            loader_ack<=0;read_accepted<=0;read_acknowledged<=0;
            case(state)
                IDLE:if(backend_ready)begin
                    if(loader_write)begin
                        // Whole-word writes only: DQM is not honoured on every MiSTer SDRAM module.
                        address<={2'b00,loader_address[22:1],1'b0};
                        data<=loader_data;
                        strobes<=2'b11;
                        owner_write<=1;request<=1;state<=WAIT_DONE;
                    end else if(read_request && image_valid && !download_active)begin
                        address<=read_address;data<=0;strobes<=0;owner_write<=0;
                        request<=1;read_accepted<=1;state<=WAIT_DONE;
                    end
                end
                WAIT_DONE:if(backend_ack)begin
                    request<=0;state<=DROP;
                    if(owner_write)loader_ack<=1;else read_acknowledged<=1;
                end
                DROP:if(backend_ready && (owner_write || !read_request))state<=IDLE;
            endcase
        end
    end
endmodule
