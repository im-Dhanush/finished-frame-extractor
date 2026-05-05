`timescale 1ns/1ps

module tb_ethernet_decoder_over_manchester;

    reg        sample_clk, arst_n, clk125, arst125_n;
    reg        mdi, start_decode;
    wire       sof, eof;
    wire [7:0] data;
    wire [2:0] data_id;
    wire [15:0] status;
    integer    fail;

    ethernet_decoder_over_manchester DUT (
        .mdi(mdi), .start_decode(start_decode),
        .sample_clk(sample_clk), .arst_n(arst_n),
        .clk125(clk125),         .arst125_n(arst125_n),
        .sof(sof), .data(data), .data_id(data_id),
        .eof(eof), .status(status)
    );

    always #3 sample_clk = ~sample_clk;  // 6ns period ~167 MHz
    always #4 clk125     = ~clk125;      // 8ns period  125 MHz

    `define CDR_RSD  DUT.DESER.CDR.retimed_serial_data
    `define CDR_CLK  DUT.DESER.CDR.recovered_clock
    `define CDR_ERR  DUT.DESER.CDR.bit_error

    // CDR stimulus tasks
    task cdr_bit;
        input b;
        begin
            @(negedge sample_clk); `CDR_RSD = b; `CDR_CLK = 1'b1;
            @(negedge sample_clk);               `CDR_CLK = 1'b0;
        end
    endtask

    task cdr_byte;
        input [7:0] b;
        integer j;
        begin for (j=0; j<8; j=j+1) cdr_bit(b[j]); end
    endtask

    task cdr_bit_err;
        begin
            @(negedge sample_clk); `CDR_ERR = 1'b1;
            @(negedge sample_clk); `CDR_ERR = 1'b0;
        end
    endtask

    // Frame storage and FCS computation
    reg [7:0] frame[0:63];
    integer   i;

    function [31:0] crc32_model;
        input [31:0] cin; input [7:0] b;
        integer j; reg [31:0] c; reg inv;
        begin
            c = cin;
            for (j=0; j<8; j=j+1) begin
                inv = c[0]^b[j]; c = c>>1;
                if (inv) c = c ^ 32'hEDB88320;
            end
            crc32_model = c;
        end
    endfunction

    task build_fcs;
        integer k; reg [31:0] crc;
        begin
            crc = 32'hFFFFFFFF;
            for (k=0; k<60; k=k+1) crc = crc32_model(crc, frame[k]);
            crc = ~crc;
            frame[60]=crc[7:0];  frame[61]=crc[15:8];
            frame[62]=crc[23:16]; frame[63]=crc[31:24];
        end
    endtask

    // Frame send tasks
    task send_clean;
        integer j;
        begin
            cdr_byte(8'hD5);
            for(j=0;  j<6;  j=j+1) cdr_byte(frame[j]);
            for(j=0;  j<6;  j=j+1) cdr_byte(frame[6+j]);
            cdr_byte(frame[12]); cdr_byte(frame[13]);
            for(j=0;  j<46; j=j+1) cdr_byte(frame[14+j]);
            cdr_byte(frame[60]); cdr_byte(frame[61]);
            cdr_byte(frame[62]); cdr_byte(frame[63]);
        end
    endtask

    task send_bad_fcs;
        integer j;
        begin
            cdr_byte(8'hD5);
            for(j=0;  j<6;  j=j+1) cdr_byte(frame[j]);
            for(j=0;  j<6;  j=j+1) cdr_byte(frame[6+j]);
            cdr_byte(frame[12]); cdr_byte(frame[13]);
            for(j=0;  j<46; j=j+1) cdr_byte(frame[14+j]);
            cdr_byte(8'hDE); cdr_byte(8'hAD);
            cdr_byte(8'hBE); cdr_byte(8'hEF);
        end
    endtask

    // Poll helpers - all run on clk125
    reg [15:0] lat_status;
    integer    got_sof, sof_cnt, eof_cnt;

    // Poll for eof pulse on clk125; latch status when seen.
    // N = max number of clk125 cycles to wait.
    task poll_eof;
        input integer N;
        integer k;
        begin
            lat_status = 16'hFFFF;
            for (k=0; k<N; k=k+1) begin
                @(posedge clk125); #1;
                if (eof) begin
                    lat_status = status;
                    k = N; // exit
                end
            end
        end
    endtask

    // Poll for sof pulse on clk125.
    task poll_sof;
        input integer N;
        integer k;
        begin
            got_sof = 0;
            for (k=0; k<N; k=k+1) begin
                @(posedge clk125); #1;
                if (sof) begin got_sof=1; k=N; end
            end
        end
    endtask

    // Inter-frame gap (sample_clk domain).
    // Ensures FSM reaches IDLE and FIFO fully drains before next frame.
    // 300 × 6ns = 1800ns >> STATUS_WAIT+STATUS_WRITE(12ns) + CDC(16ns) + output(16ns)
    task ifg;
        begin repeat(300) @(posedge sample_clk); end
    endtask

    // Check helpers
    task check_status;
        input [15:0] expected;
        input [79:0] tname;
        begin
            if (lat_status === 16'hFFFF) begin
                $display("FAIL %s: eof not seen", tname); fail=fail+1;
            end else if (lat_status !== expected) begin
                $display("FAIL %s: status=0x%04X expected=0x%04X",
                          tname, lat_status, expected);
                fail=fail+1;
            end else
                $display("PASS %s: status=0x%04X", tname, lat_status);
        end
    endtask

    // Main test
    initial begin
        fail=0; sof_cnt=0; eof_cnt=0;
        sample_clk=0; clk125=0;
        arst_n=0; arst125_n=0;
        mdi=0; start_decode=0;
        lat_status=16'hFFFF; got_sof=0;

        `CDR_RSD = 1'b0;
        `CDR_CLK = 1'b0;
        `CDR_ERR = 1'b0;

        // Build test frame: DST=AA×6, SRC=BB×6, LEN=0x002E(46), payload=00×46
        for(i=0;  i<6;  i=i+1) frame[i]    = 8'hAA;
        for(i=0;  i<6;  i=i+1) frame[6+i]  = 8'hBB;
        frame[12]=8'h00; frame[13]=8'h2E;
        for(i=0;  i<46; i=i+1) frame[14+i] = 8'h00;
        build_fcs;

        repeat(8) @(posedge sample_clk); arst_n    = 1'b1;
        repeat(8) @(posedge clk125);     arst125_n = 1'b1;
        repeat(4) @(posedge sample_clk); start_decode = 1'b1;

        // T1: Clean frame - expect status=0x0000
        // poll_sof and send_clean run concurrently so sof is not missed
        fork send_clean; poll_sof(12000); join
        poll_eof(12000);
        if (!got_sof) begin
            $display("FAIL T1a: sof not seen"); fail=fail+1;
        end else $display("PASS T1a: sof");
        check_status(16'h0000, "T1_clean");

        // T2: Corrupt FCS - expect status=0x0002
        ifg;
        fork send_bad_fcs; join
        poll_eof(12000);
        check_status(16'h0002, "T2_crcerr");

        // T3: bit_error mid-DST - expect status=0x0004
        // Send SFD + 3 DST bytes, then assert bit_error for 1 cycle.
        // FSM detects bit_error in DST state → STATUS_WAIT immediately.
        // error_cause sticky=2 (bit_error).
        // poll_eof runs concurrently so the short eof pulse is caught.
        ifg;
        fork
            begin
                cdr_byte(8'hD5);
                for(i=0; i<3; i=i+1) cdr_byte(frame[i]);
                cdr_bit_err;
            end
            poll_eof(2000);
        join
        check_status(16'h0004, "T3_biterr");

        // T4: Byte timeout - expect status=0x0001
        //
        // FIX: poll_eof runs CONCURRENTLY with the 300-cycle silence.
        // Previously poll_eof started AFTER the silence - the eof pulse
        // fires at ~202 sample_clk into the silence (1212ns), which is
        // equivalent to ~152 clk125 cycles. If poll_eof starts after
        // all 300 sample_clk (1800ns = 225 clk125), the pulse is gone.
        //
        // With fork/join: poll_eof monitors clk125 during the silence,
        // catching the eof pulse the moment it appears.
        ifg;
        fork
            begin : T4_STIMULUS
                cdr_byte(8'hD5);
                cdr_byte(frame[0]);
                cdr_byte(frame[1]);
                // Go silent - FSM timeout_cnt counts up to 200 in DST state
                // Timeout fires at ~200 sample_clk after last data_valid
                // STATUS_WAIT(1) + STATUS_WRITE(1) + CDC(~2 clk125) + output(~2 clk125)
                // Total: ~204 sample_clk + ~50ns = ~1274ns after last byte
                repeat(400) @(posedge sample_clk); // wait longer than timeout
            end
            begin : T4_POLL
                // Start polling immediately - eof will fire during the silence
                poll_eof(5000);
            end
        join
        check_status(16'h0001, "T4_timeout");

        // T5: Back-to-back clean frames - both expect status=0x0000
        ifg;
        sof_cnt=0; eof_cnt=0;

        // Frame 1
        fork send_clean; poll_sof(12000); join
        if (got_sof) sof_cnt=sof_cnt+1;
        poll_eof(12000);
        if (lat_status !== 16'hFFFF) begin
            eof_cnt=eof_cnt+1;
            if (lat_status !== 16'h0000) begin
                $display("FAIL T5 frame1: status=0x%04X expected 0x0000",lat_status);
                fail=fail+1;
            end
        end else begin
            $display("FAIL T5 frame1: eof not seen"); fail=fail+1;
        end

        ifg;

        // Frame 2
        fork send_clean; poll_sof(12000); join
        if (got_sof) sof_cnt=sof_cnt+1;
        poll_eof(12000);
        if (lat_status !== 16'hFFFF) begin
            eof_cnt=eof_cnt+1;
            if (lat_status !== 16'h0000) begin
                $display("FAIL T5 frame2: status=0x%04X expected 0x0000",lat_status);
                fail=fail+1;
            end
        end else begin
            $display("FAIL T5 frame2: eof not seen"); fail=fail+1;
        end

        if (sof_cnt!==2 || eof_cnt!==2) begin
            $display("FAIL T5: sof=%0d eof=%0d expected 2 each",sof_cnt,eof_cnt);
            fail=fail+1;
        end else
            $display("PASS T5: back-to-back sof=%0d eof=%0d",sof_cnt,eof_cnt);

        if (fail==0) $display("ALL SYSTEM TESTS PASSED");
        else         $display("%0d SYSTEM TEST(S) FAILED", fail);
        $finish;
    end
endmodule