`timescale 1ns/1ps
// Unit Testbench: manchester_decoder
// Tests the serial-to-parallel converter driven by CDR-style clock enables.
// Verifies: single byte, back-to-back bytes, one-cycle valid pulse,
//           reset clears outputs, all-zeros, all-ones, SFD byte (0xD5).
module tb_manchester_decoder;

    reg        sample_clk, arst_n;
    reg        retimed_serial_data, recovered_clock;
    wire [7:0] eth_pkt_data;
    wire       pkt_data_valid;

    integer fail;

    manchester_decoder DUT (
        .sample_clk          (sample_clk),
        .arst_n              (arst_n),
        .retimed_serial_data (retimed_serial_data),
        .recovered_clock     (recovered_clock),
        .eth_pkt_data        (eth_pkt_data),
        .pkt_data_valid      (pkt_data_valid)
    );

    always #5 sample_clk = ~sample_clk;

    // Drive one bit: present data, assert recovered_clock for one cycle
    task drive_bit;
        input b;
        begin
            @(negedge sample_clk);
            retimed_serial_data = b;
            recovered_clock     = 1'b1;
            @(negedge sample_clk);
            recovered_clock     = 1'b0;
        end
    endtask

    // Send one byte LSB-first (IEEE 802.3 bit order)
    task send_byte;
        input [7:0] b;
        integer j;
        begin
            for (j = 0; j < 8; j = j + 1)
                drive_bit(b[j]);
        end
    endtask

    // Wait for pkt_data_valid then check eth_pkt_data
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
        retimed_serial_data = 0; recovered_clock = 0;
        repeat(4) @(posedge sample_clk); arst_n = 1;
        repeat(2) @(posedge sample_clk);

        // T1: SFD byte 0xD5 = 8'b1101_0101, LSB-first: 1,0,1,0,1,0,1,1
        send_byte(8'hD5);
        check_byte(8'hD5, "T1_SFD  ");

        // T2: 0xAA alternating
        send_byte(8'hAA);
        check_byte(8'hAA, "T2_0xAA ");

        // T3: pkt_data_valid must be exactly one-cycle pulse
        begin : T3
            integer k, pulse_cnt;
            pulse_cnt = 0;
            send_byte(8'h55);
            for (k = 0; k < 6; k = k + 1) begin
                @(posedge sample_clk); #1;
                if (pkt_data_valid) pulse_cnt = pulse_cnt + 1;
            end
            if (pulse_cnt !== 1) begin
                $display("FAIL T3: pkt_data_valid pulsed %0d times (expected 1)",
                          pulse_cnt);
                fail = fail + 1;
            end else
                $display("PASS T3: pkt_data_valid one-cycle pulse");
        end

        // T4: reset clears outputs
        @(negedge sample_clk); arst_n = 0;
        @(posedge sample_clk); #1;
        if (eth_pkt_data !== 8'd0 || pkt_data_valid !== 1'b0) begin
            $display("FAIL T4: reset did not clear outputs (data=0x%02X valid=%b)",
                      eth_pkt_data, pkt_data_valid);
            fail = fail + 1;
        end else
            $display("PASS T4: reset clears outputs");
        @(negedge sample_clk); arst_n = 1;
        repeat(2) @(posedge sample_clk);

        // T5: all-zeros byte
        send_byte(8'h00);
        check_byte(8'h00, "T5_0x00 ");

        // T6: all-ones byte
        send_byte(8'hFF);
        check_byte(8'hFF, "T6_0xFF ");

        // T7: back-to-back bytes - no gap between them
        send_byte(8'hBB); check_byte(8'hBB, "T7A_BB  ");
        send_byte(8'hCC); check_byte(8'hCC, "T7B_CC  ");

        // T8: no spurious valid when recovered_clock is idle
        begin : T8
            integer k, spurious;
            spurious = 0;
            repeat(20) begin
                @(posedge sample_clk); #1;
                if (pkt_data_valid) spurious = spurious + 1;
            end
            if (spurious !== 0) begin
                $display("FAIL T8: spurious pkt_data_valid during idle (%0d)",
                          spurious);
                fail = fail + 1;
            end else
                $display("PASS T8: no spurious valid during idle");
        end

        if (fail == 0) $display("ALL MANCHESTER DECODER TESTS PASSED");
        else           $display("%0d MANCHESTER DECODER TEST(S) FAILED", fail);
        $finish;
    end
endmodule