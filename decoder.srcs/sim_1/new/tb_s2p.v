`timescale 1ns/1ps
module tb_s2p;
    reg        sample_clk, arst_n;
    reg        retimed_serial_data, recovered_clock;
    wire [7:0] eth_pkt_data;
    wire       pkt_data_valid;

    integer fail;

    s2p DUT (
        .sample_clk          (sample_clk),
        .arst_n              (arst_n),
        .retimed_serial_data (retimed_serial_data),
        .recovered_clock     (recovered_clock),
        .eth_pkt_data        (eth_pkt_data),
        .pkt_data_valid      (pkt_data_valid)
    );

    always #5 sample_clk = ~sample_clk;

    // Send one byte LSB-first, recovered_clock pulses once per bit
    task send_byte;
        input [7:0] b;
        integer j;
        begin
            for (j=0; j<8; j=j+1) begin
                @(posedge sample_clk);
                retimed_serial_data <= b[j];  // LSB first
                recovered_clock     <= 1'b1;
                @(posedge sample_clk);
                recovered_clock     <= 1'b0;
            end
        end
    endtask

    task check_byte;
        input [7:0] expected;
        input [63:0] tname;
        begin
            @(posedge sample_clk);
            if (!pkt_data_valid) begin
                $display("FAIL %s: pkt_data_valid not asserted", tname);
                fail = fail + 1;
            end else if (eth_pkt_data !== expected) begin
                $display("FAIL %s: got 0x%02X expected 0x%02X",
                          tname, eth_pkt_data, expected);
                fail = fail + 1;
            end else
                $display("PASS %s: 0x%02X", tname, eth_pkt_data);
        end
    endtask

    initial begin
        fail=0; sample_clk=0; arst_n=0;
        retimed_serial_data=0; recovered_clock=0;

        repeat(4) @(posedge sample_clk); arst_n=1;

        // T1: send 0xD5 (SFD) = 8'b11010101, LSB-first: 1,0,1,0,1,0,1,1
        send_byte(8'hD5);
        check_byte(8'hD5, "T1_SFD  ");

        // T2: send 0xAA = 8'b10101010, LSB-first: 0,1,0,1,0,1,0,1
        send_byte(8'hAA);
        check_byte(8'hAA, "T2_0xAA ");

        // T3: pkt_data_valid is one-cycle pulse only
        begin : T3
            reg [2:0] pulse_cnt;
            integer k;
            pulse_cnt = 0;
            send_byte(8'h55);
            for (k=0; k<4; k=k+1) begin
                @(posedge sample_clk);
                if (pkt_data_valid) pulse_cnt = pulse_cnt + 1;
            end
            if (pulse_cnt !== 1) begin
                $display("FAIL T3: pkt_data_valid pulsed %0d times", pulse_cnt);
                fail = fail + 1;
            end else $display("PASS T3: pkt_data_valid one-cycle pulse");
        end

        // T4: reset clears outputs
        arst_n = 0;
        @(posedge sample_clk);
        if (eth_pkt_data !== 8'd0 || pkt_data_valid !== 1'b0) begin
            $display("FAIL T4: reset did not clear outputs");
            fail = fail + 1;
        end else $display("PASS T4: reset correct");
        arst_n = 1;

        // T5: back-to-back bytes
        send_byte(8'hBB); check_byte(8'hBB, "T5A_BB  ");
        send_byte(8'hCC); check_byte(8'hCC, "T5B_CC  ");

        if (fail==0) $display("ALL S2P TESTS PASSED");
        else         $display("%0d S2P TEST(S) FAILED", fail);
        $finish;
    end
endmodule