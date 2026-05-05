module ethernet_frame_extractor(
    input  wire        pkt_data_valid,   // byte valid from s2p / Manchester decoder
    input  wire [7:0]  eth_pkt_data,     // recovered byte from s2p
    input  wire        bit_error,        // CDR bit-error flag
    input  wire        sample_clk,       // write-side clock (CDR recovered ~10 MHz)
    input  wire        arst_n,           // async reset for sample_clk domain
    input  wire        clk125,           // read-side clock (125 MHz output clock)
    input  wire        arst125_n,        // async reset for clk125 domain
    output wire        sof,
    output wire [7:0]  data,
    output wire [2:0]  data_id,
    output wire        eof,
    output wire [15:0] status
);
    wire        crc_init_w;
    wire        crc_en_w;
    wire [31:0] crc_residue_w;
    wire [31:0] fifo_din_w;
    wire        fifo_wr_en_w;
    wire [31:0] fifo_dout_w;
    wire        fifo_full_w;
    wire        fifo_empty_w;
    wire        fifo_rd_en_w;
 
    // CRC-32 calculator (clocked by sample_clk, same domain as FSM)
    crc32_eth_parallel #(.FINAL_XOR(1)) CRC (
        .clk        (sample_clk),
        .rst_n      (arst_n),
        .data_valid (crc_en_w),
        .crc_init   (crc_init_w),
        .data_in    (eth_pkt_data),
        .crc_out    (),
        .crc_residue(crc_residue_w)
    );
 
    // Ethernet receiver FSM (sample_clk domain)
    eth_rx_fsm #(.BYTE_TIMEOUT(9'd200)) FSM (
        .clk        (sample_clk),
        .rst_n      (arst_n),
        .data_valid (pkt_data_valid),
        .data_in    (eth_pkt_data),
        .bit_error  (bit_error),
        .fifo_full  (fifo_full_w),      // FIX: was unconnected in original
        .crc_init   (crc_init_w),
        .crc_en     (crc_en_w),
        .crc_residue(crc_residue_w),
        .fifo_din   (fifo_din_w),
        .fifo_wr_en (fifo_wr_en_w),
        .status     ()
    );
 
    // Async FIFO: 32-bit wide, 2048 deep (ADDR_WIDTH=11)
    // Write side: sample_clk / arst_n
    // Read  side: clk125    / arst125_n
    async_fifo #(.DATA_WIDTH(32), .ADDR_WIDTH(11)) FIFO (
        .wr_clk    (sample_clk),
        .rd_clk    (clk125),
        .wr_arst_n (arst_n),
        .rd_arst_n (arst125_n),
        .wr_en     (fifo_wr_en_w),
        .rd_en     (fifo_rd_en_w),
        .din       (fifo_din_w),
        .dout      (fifo_dout_w),
        .full      (fifo_full_w),
        .empty     (fifo_empty_w)
    );
 
    // Output logic (clk125 domain)
    eth_output_logic OUT (
        .clk125     (clk125),
        .arst125_n  (arst125_n),
        .fifo_rdata (fifo_dout_w),
        .fifo_empty (fifo_empty_w),
        .fifo_rd_en (fifo_rd_en_w),
        .sof        (sof),
        .data       (data),
        .data_id    (data_id),
        .eof        (eof),
        .status     (status)
    );
endmodule