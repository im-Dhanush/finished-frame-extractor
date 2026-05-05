// Ethernet Decoder Over Manchester - Project Top-Level
// Corresponds to Figure 1 of the decoder architecture document.
//
// Connects:
//   Deserializer (Dev A CDR + Dev B Manchester Decoder)
//     → Ethernet Frame Extractor (Dev C FSM + CRC + FIFO + Output Logic)
//
// Port list matches Table 1 of the decoder architecture doc exactly.
//
// Clock domains:
//   sample_clk  - CDR oversampling clock (16× bit rate, ~160 MHz for 10 Mbps)
//   arst_n      - async reset for sample_clk domain
//   clk125      - 125 MHz output clock driving frame extractor read side
//   arst125_n   - async reset for clk125 domain
//
// All sof/data/data_id/eof/status outputs are synchronous to clk125.

module ethernet_decoder_over_manchester (
    input  wire        mdi,          // Manchester Data Input (serial line from PHY)
    input  wire        start_decode, // async enable: start CDR decoding
    input  wire        sample_clk,   // 16× oversampling clock for CDR
    input  wire        arst_n,       // active-low async reset (sample_clk domain)
    input  wire        clk125,       // 125 MHz clock for output interface
    input  wire        arst125_n,    // active-low async reset (clk125 domain)

    output wire        sof,          // start-of-frame pulse (one clk125 cycle)
    output wire [7:0]  data,         // Ethernet byte (valid when data_id changes)
    output wire [2:0]  data_id,      // field identifier:
                                     //   0x0=SFD, 0x1=DST, 0x2=SRC,
                                     //   0x3=LEN, 0x4=PAYLOAD, 0x5=CRC
    output wire        eof,          // end-of-frame pulse (one clk125 cycle)
    output wire [15:0] status        // frame status on eof:
                                     //   0x0000=OK, 0x0001=timeout,
                                     //   0x0002=CRC error, 0x0004=bit error
);

    // Internal wires between Deserializer and Frame Extractor
    wire [7:0] eth_pkt_data;    // recovered byte (sample_clk domain)
    wire       pkt_data_valid;  // byte valid, one-cycle pulse
    wire       bit_error;       // CDR bit-error flag

    // Deserializer - Dev A (CDR) + Dev B (Manchester Decoder)
    deserializer DESER (
        .mdi             (mdi),
        .start_decode    (start_decode),
        .sample_clk      (sample_clk),
        .arst_n          (arst_n),
        .eth_pkt_data    (eth_pkt_data),
        .pkt_data_valid  (pkt_data_valid),
        .bit_error       (bit_error)
    );
    // Ethernet Frame Extractor - Dev C
    // Async FIFO bridges sample_clk (write) → clk125 (read).
    ethernet_frame_extractor FRAME_EXT (
        .pkt_data_valid  (pkt_data_valid),
        .eth_pkt_data    (eth_pkt_data),
        .bit_error       (bit_error),
        .sample_clk      (sample_clk),
        .arst_n          (arst_n),
        .clk125          (clk125),
        .arst125_n       (arst125_n),
        .sof             (sof),
        .data            (data),
        .data_id         (data_id),
        .eof             (eof),
        .status          (status)
    );

endmodule