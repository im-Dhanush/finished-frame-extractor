// Deserializer
//
//  Inputs:
//    mdi          - Manchester Data Input (serial line)
//    start_decode - asynchronous enable; CDR starts monitoring MDI
//    sample_clk   - 16× oversampling clock for CDR (= 16 × bit_rate)
//    arst_n       - active-low async reset for sample_clk domain
//
//  Outputs:
//    pkt_data_valid - one-cycle pulse per recovered byte
//    eth_pkt_data   - 8-bit recovered Ethernet byte
//    bit_error      - CDR detected invalid Manchester transition
//
// Internal wires between CDR and Manchester Decoder:
//    retimed_serial_data - CDR-reclocked serial bit
//    recovered_clock     - CDR-derived 1-cycle clock-enable per bit
//


module deserializer (
    // Inputs
    input  wire       mdi,               // Manchester Data Input
    input  wire       start_decode,      // async enable to start decoding
    input  wire       sample_clk,        // 16× oversample clock
    input  wire       arst_n,            // active-low async reset
    // Outputs
    output wire [7:0] eth_pkt_data,      // recovered Ethernet byte
    output wire       pkt_data_valid,    // byte valid (one-cycle pulse)
    output wire       bit_error          // CDR bit-error flag
);

    // Internal signals between CDR  and Manchester Decoder 
    wire retimed_serial_data;  // CDR retimed serial bit
    wire recovered_clock;      // CDR 1-cycle clock-enable per recovered bit

    // ----------------------------------------------------------------
    // (1) Clock Data Recovery 
    //     CDR extracts clock + data from MDI, uses preamble for lock.
    //     It outputs retimed_serial_data on the recovered_clock enable.
    // ----------------------------------------------------------------
    clock_data_recovery CDR (
        .mdi                 (mdi),
        .start_decode        (start_decode),
        .sample_clk          (sample_clk),
        .arst_n              (arst_n),
        .retimed_serial_data (retimed_serial_data),
        .recovered_clock     (recovered_clock),
        .bit_error           (bit_error)
    );

    // ----------------------------------------------------------------
    // (2) Manchester Decoder 
    //     Plain serial-to-parallel converter driven by CDR enables.
    // ----------------------------------------------------------------
    manchester_decoder MANCH_DEC (
        .sample_clk          (sample_clk),
        .arst_n              (arst_n),
        .retimed_serial_data (retimed_serial_data),
        .recovered_clock     (recovered_clock),
        .eth_pkt_data        (eth_pkt_data),
        .pkt_data_valid      (pkt_data_valid)
    );

endmodule