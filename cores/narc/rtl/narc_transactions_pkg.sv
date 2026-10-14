`default_nettype none
package narc_transactions_pkg;
  typedef enum logic [1:0] {
    VRAM_OWNER_CPU,
    VRAM_OWNER_DMA,
    VRAM_OWNER_TRANSFER,
    VRAM_OWNER_NONE
  } vram_owner_t;

  typedef struct packed {
    logic        valid;
    vram_owner_t owner;
    logic        write;
    logic [17:0] pixel_addr;
    logic [15:0] write_data;
    logic [1:0]  byte_enable;
  } vram_random_req_t;

  typedef struct packed {
    logic        ready;
    logic [15:0] read_data;
  } vram_random_rsp_t;

  typedef enum logic [1:0] {
    ROW_LOAD_SCANOUT,
    ROW_LOAD_SRT,
    ROW_STORE_SRT,
    ROW_AUTOERASE
  } vram_row_operation_t;

  typedef struct packed {
    logic                valid;
    vram_row_operation_t operation;
    logic [8:0]          source_row;
    logic [8:0]          destination_row;
  } vram_row_transfer_t;

  typedef struct packed {
    logic        valid;
    logic [23:0] word_addr;
    logic [1:0]  direction;
    logic        row_start;
  } u77_image_fetch_req_t;

  typedef struct packed {
    logic        ready;
    logic [31:0] data;
  } u77_image_fetch_rsp_t;

  typedef struct packed {
    logic        valid;
    logic        aborted;
    logic [31:0] dma_clocks;
    logic        assert_int1;
  } u77_dma_completion_t;
endpackage
`default_nettype wire
