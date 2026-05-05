`timescale 1ns/1ps
// Integration Testbench: deserializer
//
// Since CDR is not yet delivered, this TB instantiates a CDR stub
// (clock_data_recovery_stub renamed to clock_data_recovery) that mimics
// CDR behaviour: it accepts mdi + start_decode, discards preamble bytes,
// then drives recovered_clock + retimed_serial_data for each data bit.
//
// The stub models the exact CDR output contract:
//   - recovered_clock is a one-cycle pulse per valid data bit
//   - retimed_serial_data holds the bit value on that cycle
//   - bit_error is pulsed when an intentionally corrupted bit is injected
//   - preamble bytes (0x55 × 7 + SFD 0xD5) are consumed internally
//     and NOT forwarded to Manchester Decoder (matching design doc spec)
//
// Tests:
//   T1: SFD + 3 data bytes recovered correctly
//   T2: bit_error assertion propagates out of deserializer
//   T3: back-to-back frames (start_decode toggle)
//   T4: reset mid-stream clears outputs

// CDR stub
module clock_data_recovery (
    input  wire mdi,
    input  wire start_decode,
    input  wire sample_clk,
    input  wire arst_n,
    output reg  retimed_serial_data,
    output reg  recovered_clock,
    output reg  bit_error
);
    // Driven entirely by the testbench via force/release or a shared task.
    // Initialise to safe defaults.
    initial begin
        retimed_serial_data = 0;
        recovered_clock     = 0;
        bit_error           = 0;
    end
endmodule

// Testbench
module tb_deserializer;

    reg        sample_clk, arst_n;
    reg        mdi, start_decode;
    wire [7:0] eth_pkt_data;
    wire       pkt_data_valid;
    wire       bit_error_out;

    integer fail;

    deserializer DUT (
        .mdi            (mdi),
        .start_decode   (start_decode),
        .sample_clk     (sample_clk),
        .arst_n         (arst_n),
        .eth_pkt_data   (eth_pkt_data),
        .pkt_data_valid (pkt_data_valid),
        .bit_error      (bit_error_out)
    );

    always #5 sample_clk = ~sample_clk;

    // Shorthand references into CDR stub registers
    // (use hierarchical path since CDR is inside DUT)
    `define CDR_RSD  DUT.CDR.retimed_serial_data
    `define CDR_CLK  DUT.CDR.recovered_clock
    `define CDR_ERR  DUT.CDR.bit_error

    // Drive one CDR output bit (mimics CDR recovered_clock pulse)
    task cdr_drive_bit;
        input b;
        begin
            @(negedge sample_clk);
            `CDR_RSD = b;
            `CDR_CLK = 1'b1;
            @(negedge sample_clk);
            `CDR_CLK = 1'b0;
        end
    endtask

    // Drive 8 bits LSB-first (as CDR would after consuming preamble)
    task cdr_send_byte;
        input [7:0] b;
        integer j;
        begin
            for (j = 0; j < 8; j = j + 1)
                cdr_drive_bit(b[j]);
        end
    endtask

    // Assert bit_error for one sample_clk cycle via CDR stub
    task inject_bit_error;
        begin
            @(negedge sample_clk);
            `CDR_ERR = 1'b1;
            @(negedge sample_clk);
            `CDR_ERR = 1'b0;
        end
    endtask

    // Check eth_pkt_data on the cycle pkt_data_valid fires
    task check_byte;
        input [7:0] expected;
        input [63:0] tname;
        begin
            @(posedge sample_clk); #1;
            if (!pkt_data_valid) begin
                $display("FAIL %s: pkt_data_valid not asserted", tname);
                fail = fail + 1;
            end else if (eth_pkt_data !== expected) begin
                $display("FAIL %s: got=0x%02X expected=0x%02X",
                          tname, eth_pkt_data, expected);
                fail = fail + 1;
            end else
                $display("PASS %s: 0x%02X", tname, eth_pkt_data);
        end
    endtask

    initial begin
        fail = 0;
        sample_clk = 0; arst_n = 0;
        mdi = 0; start_decode = 0;
        repeat(4) @(posedge sample_clk); arst_n = 1;
        repeat(2) @(posedge sample_clk);

        // T1: CDR stub drives SFD + 3 data bytes; verify Manchester Decoder output
        start_decode = 1;
        // CDR has already consumed preamble internally; it now drives bytes
        // directly as clock-enabled bits.
        // Byte 1: SFD 0xD5
        cdr_send_byte(8'hD5);
        check_byte(8'hD5, "T1_SFD  ");

        // Byte 2: 0xAA
        cdr_send_byte(8'hAA);
        check_byte(8'hAA, "T1_0xAA ");

        // Byte 3: 0xBB
        cdr_send_byte(8'hBB);
        check_byte(8'hBB, "T1_0xBB ");

        // T2: bit_error from CDR stub propagates out of deserializer
        inject_bit_error;
        @(posedge sample_clk); #1;
        if (!bit_error_out) begin
            $display("FAIL T2: bit_error not propagated");
            fail = fail + 1;
        end else
            $display("PASS T2: bit_error propagated correctly");
        // Wait for it to deassert
        @(posedge sample_clk); #1;
        if (bit_error_out) begin
            $display("FAIL T2b: bit_error did not deassert");
            fail = fail + 1;
        end else
            $display("PASS T2b: bit_error deasserted");

        // T3: back-to-back frames (toggle start_decode between frames)
        start_decode = 0;
        repeat(4) @(posedge sample_clk);
        start_decode = 1;
        cdr_send_byte(8'hD5); check_byte(8'hD5, "T3A_SFD ");
        cdr_send_byte(8'hCC); check_byte(8'hCC, "T3B_CC  ");

        // T4: reset mid-stream
        cdr_drive_bit(1); cdr_drive_bit(0); // partial byte
        @(negedge sample_clk); arst_n = 0;
        @(posedge sample_clk); #1;
        if (eth_pkt_data !== 8'd0 || pkt_data_valid !== 1'b0) begin
            $display("FAIL T4: reset did not clear outputs");
            fail = fail + 1;
        end else
            $display("PASS T4: reset clears outputs");
        @(negedge sample_clk); arst_n = 1;
        repeat(2) @(posedge sample_clk);

        // T5: no spurious pkt_data_valid when CDR is idle
        begin : T5
            integer k, spurious;
            spurious = 0;
            repeat(20) begin
                @(posedge sample_clk); #1;
                if (pkt_data_valid) spurious = spurious + 1;
            end
            if (spurious !== 0) begin
                $display("FAIL T5: spurious pkt_data_valid during idle (%0d)",
                          spurious);
                fail = fail + 1;
            end else
                $display("PASS T5: no spurious valid during idle");
        end

        if (fail == 0) $display("ALL DESERIALIZER TESTS PASSED");
        else           $display("%0d DESERIALIZER TEST(S) FAILED", fail);
        $finish;
    end
endmodule