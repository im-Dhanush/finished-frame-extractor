`timescale 1ns/1ps
// Integration testbench for ethernet_frame_extractor
// Tests: clean frame (sof+eof+status=0), bit_error (status=0x0004),
//        corrupt FCS (status=0x0002), back-to-back frames, byte timeout (status=0x0001).
// Note: uses correct port name "pkt_data_valid" (fixed from original "eth_pkt_data_in").
module tb_ethernet_frame_extractor;

    reg        sample_clk, arst_n;
    reg        clk125, arst125_n;
    reg        pkt_data_valid;
    reg [7:0]  eth_pkt_data;
    reg        bit_error;

    wire        sof, eof;
    wire [7:0]  data;
    wire [2:0]  data_id;
    wire [15:0] status;

    ethernet_frame_extractor DUT (
        .pkt_data_valid (pkt_data_valid),
        .eth_pkt_data   (eth_pkt_data),
        .bit_error      (bit_error),
        .sample_clk     (sample_clk),
        .arst_n         (arst_n),
        .clk125         (clk125),
        .arst125_n      (arst125_n),
        .sof            (sof),
        .data           (data),
        .data_id        (data_id),
        .eof            (eof),
        .status         (status)
    );

    always #3 sample_clk = ~sample_clk;  // ~167 MHz (oversampled CDR clock)
    always #4 clk125     = ~clk125;      // 125 MHz

    reg [7:0]  frame [0:63];
    integer    i, fail;
    reg [15:0] latched_status;
    integer    found_sof;

    // Software CRC model (bit-reversed, 802.3)
    function [31:0] crc32_byte_model;
        input [31:0] crc_in;
        input [7:0]  b;
        integer j; reg [31:0] c; reg inv;
        begin
            c = crc_in;
            for (j = 0; j < 8; j = j + 1) begin
                inv = c[0] ^ b[j]; c = c >> 1;
                if (inv) c = c ^ 32'hEDB88320;
            end
            crc32_byte_model = c;
        end
    endfunction

    task compute_fcs;
        integer k; reg [31:0] crc;
        begin
            crc = 32'hFFFFFFFF;
            for (k = 0; k < 60; k = k + 1)
                crc = crc32_byte_model(crc, frame[k]);
            crc = ~crc;
            frame[60] = crc[7:0];  frame[61] = crc[15:8];
            frame[62] = crc[23:16]; frame[63] = crc[31:24];
        end
    endtask

    // Send one byte: assert pkt_data_valid for one sample_clk cycle
    task send_byte;
        input [7:0] b;
        begin
            @(negedge sample_clk);
            eth_pkt_data   = b;
            pkt_data_valid = 1'b1;
            @(negedge sample_clk);
            pkt_data_valid = 1'b0;
            eth_pkt_data   = 8'd0;
        end
    endtask

    task send_frame;
        integer j;
        begin
            send_byte(8'hD5);                                   // SFD
            for (j = 0; j < 6;  j = j+1) send_byte(frame[j]);  // DST
            for (j = 0; j < 6;  j = j+1) send_byte(frame[6+j]);// SRC
            send_byte(frame[12]); send_byte(frame[13]);          // LEN
            for (j = 0; j < 46; j = j+1) send_byte(frame[14+j]);// payload
            send_byte(frame[60]); send_byte(frame[61]);          // FCS
            send_byte(frame[62]); send_byte(frame[63]);
        end
    endtask

    // Poll eof on clk125; latch status when seen
    task wait_eof_latch;
        input integer timeout_cycles;
        integer k;
        begin
            latched_status = 16'hFFFF;
            for (k = 0; k < timeout_cycles; k = k + 1) begin
                @(posedge clk125); #1;
                if (eof) begin
                    latched_status = status;
                    k = timeout_cycles; // break
                end
            end
        end
    endtask

    // Poll sof on clk125
    task wait_sof_task;
        output integer result;
        input  integer timeout_cycles;
        integer k;
        begin
            result = 0;
            for (k = 0; k < timeout_cycles; k = k + 1) begin
                @(posedge clk125); #1;
                if (sof) begin result = 1; k = timeout_cycles; end
            end
        end
    endtask

    integer sof_count, eof_count;

    initial begin
        fail = 0; sof_count = 0; eof_count = 0;
        sample_clk = 0; clk125 = 0;
        arst_n = 0; arst125_n = 0;
        pkt_data_valid = 0; eth_pkt_data = 0; bit_error = 0;
        latched_status = 0; found_sof = 0;

        for (i = 0; i < 6;  i = i+1) frame[i]      = 8'hAA;
        for (i = 0; i < 6;  i = i+1) frame[6+i]    = 8'hBB;
        frame[12] = 8'h00; frame[13] = 8'h2E;
        for (i = 0; i < 46; i = i+1) frame[14+i]   = 8'h00;
        compute_fcs;

        repeat(6) @(posedge sample_clk); arst_n    = 1;
        repeat(6) @(posedge clk125);     arst125_n = 1;
        repeat(4) @(posedge sample_clk);

        // ---- T1: clean frame ----
        fork
            send_frame;
            wait_sof_task(found_sof, 5000);
        join
        wait_eof_latch(2000);

        if (!found_sof) begin
            $display("FAIL T1a: sof not seen"); fail = fail + 1;
        end else $display("PASS T1a: sof received");

        if (latched_status === 16'hFFFF) begin
            $display("FAIL T1b: eof not seen"); fail = fail + 1;
        end else if (latched_status !== 16'h0000) begin
            $display("FAIL T1c: status=0x%04X expected 0x0000", latched_status);
            fail = fail + 1;
        end else $display("PASS T1b/c: eof status=0x0000");

        // ---- T2: bit_error mid-DST ----
        repeat(10) @(posedge sample_clk);
        send_byte(8'hD5);
        for (i = 0; i < 3; i = i+1) send_byte(frame[i]);
        @(negedge sample_clk); bit_error = 1;
        @(negedge sample_clk); bit_error = 0;
        wait_eof_latch(1000);
        if (latched_status === 16'hFFFF) begin
            $display("FAIL T2: eof not seen after bit_error"); fail = fail + 1;
        end else if (latched_status !== 16'h0004) begin
            $display("FAIL T2: status=0x%04X expected 0x0004", latched_status);
            fail = fail + 1;
        end else $display("PASS T2: bit_error status=0x0004");

        // ---- T3: corrupt FCS ----
        repeat(10) @(posedge sample_clk);
        send_byte(8'hD5);
        for (i = 0; i < 6;  i = i+1) send_byte(frame[i]);
        for (i = 0; i < 6;  i = i+1) send_byte(frame[6+i]);
        send_byte(frame[12]); send_byte(frame[13]);
        for (i = 0; i < 46; i = i+1) send_byte(frame[14+i]);
        send_byte(8'hDE); send_byte(8'hAD); send_byte(8'hBE); send_byte(8'hEF);
        wait_eof_latch(5000);
        if (latched_status === 16'hFFFF) begin
            $display("FAIL T3: eof not seen for corrupt FCS"); fail = fail + 1;
        end else if (latched_status !== 16'h0002) begin
            $display("FAIL T3: status=0x%04X expected 0x0002", latched_status);
            fail = fail + 1;
        end else $display("PASS T3: CRC error status=0x0002");

        // ---- T4: back-to-back frames ----
        repeat(20) @(posedge sample_clk);
        sof_count = 0; eof_count = 0;

        fork send_frame; wait_sof_task(found_sof, 5000); join
        wait_eof_latch(2000);
        if (found_sof) sof_count = sof_count + 1;
        if (latched_status !== 16'hFFFF) begin
            eof_count = eof_count + 1;
            if (latched_status !== 16'h0000) begin
                $display("FAIL T4 frame1: status=0x%04X", latched_status);
                fail = fail + 1;
            end
        end else begin $display("FAIL T4 frame1: eof not seen"); fail=fail+1; end

        repeat(20) @(posedge sample_clk);

        fork send_frame; wait_sof_task(found_sof, 5000); join
        wait_eof_latch(2000);
        if (found_sof) sof_count = sof_count + 1;
        if (latched_status !== 16'hFFFF) begin
            eof_count = eof_count + 1;
            if (latched_status !== 16'h0000) begin
                $display("FAIL T4 frame2: status=0x%04X", latched_status);
                fail = fail + 1;
            end
        end else begin $display("FAIL T4 frame2: eof not seen"); fail=fail+1; end

        if (sof_count !== 2 || eof_count !== 2) begin
            $display("FAIL T4: sof=%0d eof=%0d expected 2 each",
                      sof_count, eof_count);
            fail = fail + 1;
        end else
            $display("PASS T4: back-to-back sof=%0d eof=%0d", sof_count, eof_count);

        // ---- T5: byte timeout ----
        repeat(10) @(posedge sample_clk);
        send_byte(8'hD5);
        send_byte(frame[0]); send_byte(frame[1]);
        repeat(300) @(posedge sample_clk); // exceed BYTE_TIMEOUT=200
        wait_eof_latch(1000);
        if (latched_status === 16'hFFFF) begin
            $display("FAIL T5: eof not seen after timeout"); fail = fail + 1;
        end else if (latched_status !== 16'h0001) begin
            $display("FAIL T5: status=0x%04X expected 0x0001", latched_status);
            fail = fail + 1;
        end else $display("PASS T5: timeout status=0x0001");

        if (fail == 0) $display("ALL INTEGRATION TESTS PASSED");
        else           $display("%0d INTEGRATION TEST(S) FAILED", fail);
        $finish;
    end
endmodule