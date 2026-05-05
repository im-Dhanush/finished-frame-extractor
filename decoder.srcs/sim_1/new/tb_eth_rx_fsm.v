`timescale 1ns/1ps
// Testbench for eth_rx_fsm
// Bug fixed: fifo_full port was missing from FSM instantiation in original.
// Tests: clean frame (status=0), CRC error (0x0002), bit_error (0x0004),
//        byte timeout (0x0001), back-to-back frames.
module tb_eth_rx_fsm;
    reg         clk, rst_n;
    reg         data_valid;
    reg  [7:0]  data_in;
    reg         bit_error;

    wire        crc_init_w, crc_en_w;
    wire [31:0] crc_residue_w;
    wire [31:0] fifo_din_w;
    wire        fifo_wr_en_w;
    wire [15:0] status_w;

    // Shadow FIFO: capture FSM writes
    reg  [31:0] fifo_mem [0:2047];
    integer     fifo_ptr;
    reg         fifo_full_r;   // driven by TB; normally 0

    wire [31:0] crc_out_unused;

    crc32_eth_parallel #(.FINAL_XOR(1)) CRC (
        .clk        (clk),
        .rst_n      (rst_n),
        .data_valid (crc_en_w),
        .crc_init   (crc_init_w),
        .data_in    (data_in),
        .crc_out    (crc_out_unused),
        .crc_residue(crc_residue_w)
    );

    eth_rx_fsm #(.BYTE_TIMEOUT(9'd20)) FSM (
        .clk        (clk),
        .rst_n      (rst_n),
        .data_valid (data_valid),
        .data_in    (data_in),
        .bit_error  (bit_error),
        .fifo_full  (fifo_full_r),   // FIX: was missing in original
        .crc_init   (crc_init_w),
        .crc_en     (crc_en_w),
        .crc_residue(crc_residue_w),
        .fifo_din   (fifo_din_w),
        .fifo_wr_en (fifo_wr_en_w),
        .status     (status_w)
    );

    always #5 clk = ~clk;

    // Capture FIFO writes in shadow memory
    always @(posedge clk) begin
        if (fifo_wr_en_w) begin
            fifo_mem[fifo_ptr] = fifo_din_w;
            fifo_ptr           = fifo_ptr + 1;
        end
    end

    // Frame: 6B DST(AA) + 6B SRC(BB) + 2B LEN(0x002E) + 46B payload(0x00)
    // + 4B FCS (computed below)
    reg [7:0] frame [0:63];
    integer   i, fail;

    // Software CRC model
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

    task send_byte;
        input [7:0] b;
        begin
            @(negedge clk);
            data_in    = b;
            data_valid = 1'b1;
            @(negedge clk);
            data_valid = 1'b0;
            data_in    = 8'd0;
        end
    endtask

    // Send full 64-byte frame; corrupt_fcs=1 replaces FCS with junk
    task send_frame;
        input corrupt_fcs;
        begin
            fifo_ptr = 0;
            send_byte(8'hD5);               // SFD
            for (i = 0; i < 6;  i = i+1) send_byte(frame[i]);      // DST
            for (i = 0; i < 6;  i = i+1) send_byte(frame[6+i]);    // SRC
            send_byte(frame[12]); send_byte(frame[13]);             // LEN
            for (i = 0; i < 46; i = i+1) send_byte(frame[14+i]);   // payload
            if (corrupt_fcs) begin
                send_byte(8'hDE); send_byte(8'hAD);
                send_byte(8'hBE); send_byte(8'hEF);
            end else begin
                send_byte(frame[60]); send_byte(frame[61]);
                send_byte(frame[62]); send_byte(frame[63]);
            end
            repeat(6) @(posedge clk); // wait for STATUS_S + FIFO write
        end
    endtask

    // Check that the last eof word in shadow FIFO carries expected status
    task check_eof_status;
        input [15:0] expected;
        input [79:0] tname;
        reg found_eof; integer j; reg [15:0] got;
        begin
            found_eof = 0; got = 0;
            for (j = 0; j < fifo_ptr; j = j + 1) begin
                if (fifo_mem[j][30]) begin
                    got = fifo_mem[j][15:0]; found_eof = 1;
                end
            end
            if (!found_eof) begin
                $display("FAIL %s: no eof word in FIFO", tname); fail = fail + 1;
            end else if (got !== expected) begin
                $display("FAIL %s: status=0x%04X expected=0x%04X",
                          tname, got, expected);
                fail = fail + 1;
            end else
                $display("PASS %s: status=0x%04X", tname, got);
        end
    endtask

    task check_fifo_count;
        input integer expected;
        input [79:0] tname;
        begin
            if (fifo_ptr !== expected) begin
                $display("FAIL %s: fifo_ptr=%0d expected %0d",
                          tname, fifo_ptr, expected);
                fail = fail + 1;
            end else
                $display("PASS %s: fifo word count=%0d", tname, fifo_ptr);
        end
    endtask

    task check_sof_present;
        input [63:0] tname;
        reg found; integer j;
        begin
            found = 0;
            for (j = 0; j < fifo_ptr; j = j + 1)
                if (fifo_mem[j][31]) found = 1;
            if (!found) begin
                $display("FAIL %s: sof not found in FIFO", tname); fail = fail + 1;
            end else
                $display("PASS %s: sof present", tname);
        end
    endtask

    initial begin
        fail = 0; clk = 0; rst_n = 0;
        data_valid = 0; bit_error = 0; data_in = 0;
        fifo_ptr = 0; fifo_full_r = 0;

        for (i = 0; i < 6;  i = i+1) frame[i]      = 8'hAA;
        for (i = 0; i < 6;  i = i+1) frame[6+i]    = 8'hBB;
        frame[12] = 8'h00; frame[13] = 8'h2E;
        for (i = 0; i < 46; i = i+1) frame[14+i]   = 8'h00;
        compute_fcs;

        repeat(4) @(posedge clk); rst_n = 1;
        repeat(2) @(posedge clk);

        // T1: clean frame - expect 1(SFD)+6(DST)+6(SRC)+2(LEN)+46(PLD)+4(CRC)+1(STATUS) = 66 words
        send_frame(0);
        check_fifo_count(66, "T1_COUNT  ");
        check_sof_present("T1_SOF  ");
        check_eof_status(16'h0000, "T1_CLEAN  ");

        // T2: corrupt FCS
        repeat(4) @(posedge clk);
        send_frame(1);
        check_eof_status(16'h0002, "T2_CRCERR ");

        // T3: bit_error mid-payload
        repeat(4) @(posedge clk);
        fifo_ptr = 0;
        send_byte(8'hD5);
        for (i = 0; i < 6;  i = i+1) send_byte(frame[i]);
        for (i = 0; i < 6;  i = i+1) send_byte(frame[6+i]);
        send_byte(frame[12]); send_byte(frame[13]);
        send_byte(frame[14]); send_byte(frame[15]);
        @(negedge clk); bit_error = 1;
        @(negedge clk); bit_error = 0;
        repeat(6) @(posedge clk);
        check_eof_status(16'h0004, "T3_BITERR ");

        // T4: byte timeout mid-DST  (BYTE_TIMEOUT=20 cycles)
        repeat(4) @(posedge clk);
        fifo_ptr = 0;
        send_byte(8'hD5);
        send_byte(frame[0]); send_byte(frame[1]); // 2 of 6 DST bytes
        repeat(28) @(posedge clk);                // exceed timeout
        repeat(4)  @(posedge clk);
        check_eof_status(16'h0001, "T4_TIMEOUT");

        // T5: back-to-back frames
        repeat(4) @(posedge clk);
        send_frame(0);
        begin : T5A
            reg found_eof_a; integer j;
            found_eof_a = 0;
            for (j = 0; j < fifo_ptr; j = j + 1)
                if (fifo_mem[j][30]) found_eof_a = 1;
            if (!found_eof_a) begin
                $display("FAIL T5: first frame no eof"); fail = fail + 1;
            end else $display("PASS T5A: first frame eof present");
        end
        send_frame(0);
        check_eof_status(16'h0000, "T5B_B2B   ");

        if (fail == 0) $display("ALL FSM TESTS PASSED");
        else           $display("%0d FSM TEST(S) FAILED", fail);
        $finish;
    end
endmodule