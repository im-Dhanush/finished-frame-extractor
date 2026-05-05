// Manchester Decoder
// converts CDR-recovered serial bit stream into
// 8-bit Ethernet bytes (serial-to-parallel conversion).
//
// Per design architecture:
//   Inputs : recovered_clock (1-bit clock enable from CDR)
//            retimed_serial_data (1-bit data from CDR synchronizer)
//            sample_clk, arst_n
//   Outputs: pkt_data_valid (1-bit, one-cycle pulse per complete byte)
//            eth_pkt_data   (8-bit recovered byte, LSB-first per IEEE 802.3)
//
// Internally this is a plain serial-to-parallel converter (s2p).
// The CDR block is responsible for clock recovery and data
// retiming before handing off to this module.
//
// Bit ordering: IEEE 802.3 transmits LSB first.  The s2p shifts the
// first received bit into position [0] so that after 8 recovered_clock
// pulses eth_pkt_data[0] holds the first received bit (LSB).

module manchester_decoder (
    input  wire       sample_clk,           // CDR sample clock (16× bit rate)
    input  wire       arst_n,               // active-low async reset
    input  wire       retimed_serial_data,  // retimed serial bit from CDR
    input  wire       recovered_clock,      // 1-cycle clock-enable per bit from CDR
    output wire [7:0] eth_pkt_data,         // recovered Ethernet byte
    output wire       pkt_data_valid        // high for one sample_clk when byte ready
);

    // Instantiate serial-to-parallel converter
    s2p S2P (
        .sample_clk          (sample_clk),
        .arst_n              (arst_n),
        .retimed_serial_data (retimed_serial_data),
        .recovered_clock     (recovered_clock),
        .eth_pkt_data        (eth_pkt_data),
        .pkt_data_valid      (pkt_data_valid)
    );

endmodule