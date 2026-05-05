`timescale 1ns/1ps
// Testbench for crc32_eth_parallel
// Verified against bit-serial CRC-32 reference model (POLY=0xEDB88320)
// GOOD_CRC = 0xDEBB20E3 (raw crc_reg after data+correct_FCS, no final XOR)
module tb_crc32;
    reg        clk, rst_n, data_valid, crc_init;
    reg  [7:0] data_in;
    wire [31:0] crc_out, crc_residue;
    integer i, fail;

    reg [7:0] frame [0:63];

    crc32_eth_parallel #(.FINAL_XOR(1)) DUT (
        .clk(clk), .rst_n(rst_n),
        .data_valid(data_valid), .crc_init(crc_init),
        .data_in(data_in), .crc_out(crc_out), .crc_residue(crc_residue)
    );

    always #5 clk = ~clk;

    // Bit-serial CRC-32 model (POLY=0xEDB88320, reflected)
    function [31:0] crc32_model;
        input [31:0] cin; input [7:0] b;
        integer j; reg [31:0] c; reg inv;
        begin
            c = cin ^ {24'd0, b};
            for (j=0;j<8;j=j+1) begin
                inv = c[0]; c = c>>1;
                if (inv) c = c ^ 32'hEDB88320;
            end
            crc32_model = c;
        end
    endfunction

    task feed_byte;
        input [7:0] b;
        begin
            @(negedge clk); data_in=b; data_valid=1;
            @(negedge clk); data_valid=0; data_in=0;
        end
    endtask

    task do_init;
        begin
            @(negedge clk); crc_init=1;
            @(negedge clk); crc_init=0;
        end
    endtask

    task build_fcs;
        integer k; reg [31:0] crc;
        begin
            crc=32'hFFFFFFFF;
            for(k=0;k<60;k=k+1) crc=crc32_model(crc,frame[k]);
            crc=~crc;
            frame[60]=crc[7:0]; frame[61]=crc[15:8];
            frame[62]=crc[23:16]; frame[63]=crc[31:24];
        end
    endtask

    // Verify model produces correct residue
    task verify_model;
        reg [31:0] crc; integer k;
        begin
            // Build frame
            for(k=0;k<6;k=k+1)  frame[k]    = 8'hAA;
            for(k=0;k<6;k=k+1)  frame[6+k]  = 8'hBB;
            frame[12]=8'h00; frame[13]=8'h2E;
            for(k=0;k<46;k=k+1) frame[14+k] = 8'h00;
            build_fcs;
            // Run model over all 64 bytes
            crc=32'hFFFFFFFF;
            for(k=0;k<64;k=k+1) crc=crc32_model(crc,frame[k]);
            if(crc!==32'hDEBB20E3) begin
                $display("ERROR: model residue=0x%08X expected 0xDEBB20E3",crc);
                $finish;
            end else
                $display("Model verified: residue=0xDEBB20E3");
        end
    endtask

    initial begin
        fail=0; clk=0; rst_n=0;
        data_valid=0; crc_init=0; data_in=0;

        verify_model;  // sanity check model before testing RTL

        @(negedge clk); rst_n=1;
        repeat(2) @(posedge clk);

        // T1: after reset crc_reg=0xFFFFFFFF, crc_out=0x00000000
        if(crc_out!==32'h00000000) begin
            $display("FAIL T1: crc_out=0x%08X expected 0x00000000",crc_out);
            fail=fail+1;
        end else $display("PASS T1: crc_out=0x00000000 after reset");

        // T2: feed all 64 bytes, residue (raw) must be 0xDEBB20E3
        do_init;
        for(i=0;i<64;i=i+1) feed_byte(frame[i]);
        @(posedge clk); #1;
        if(crc_residue!==32'hDEBB20E3) begin
            $display("FAIL T2: residue=0x%08X expected 0xDEBB20E3",crc_residue);
            fail=fail+1;
        end else $display("PASS T2: residue=0xDEBB20E3");

        // T3: crc_init resets mid-stream
        feed_byte(8'hDE); feed_byte(8'hAD);
        do_init;
        @(posedge clk); #1;
        if(crc_residue!==32'hFFFFFFFF) begin
            $display("FAIL T3: after crc_init=0x%08X expected 0xFFFFFFFF",crc_residue);
            fail=fail+1;
        end else $display("PASS T3: crc_init resets correctly");

        // T4: data_valid=0 must not advance CRC
        do_init; feed_byte(8'hAA);
        begin : T4
            reg [31:0] snap;
            @(posedge clk); #1; snap=crc_residue;
            repeat(10) @(posedge clk);
            if(crc_residue!==snap) begin
                $display("FAIL T4: CRC advanced without data_valid"); fail=fail+1;
            end else $display("PASS T4: CRC stable without data_valid");
        end

        // T5: crc_init priority over data_valid
        do_init;
        @(negedge clk); data_in=8'hFF; data_valid=1; crc_init=1;
        @(negedge clk); data_valid=0; crc_init=0;
        @(posedge clk); #1;
        if(crc_residue!==32'hFFFFFFFF) begin
            $display("FAIL T5: crc_init did not override data_valid"); fail=fail+1;
        end else $display("PASS T5: crc_init overrides data_valid");

        // T6: verify RTL parallel equations match bit-serial model byte by byte
        begin : T6
            integer k; reg [31:0] model_crc, rtl_crc;
            reg mismatch;
            mismatch=0;
            do_init;
            model_crc=32'hFFFFFFFF;
            for(k=0;k<64;k=k+1) begin
                model_crc=crc32_model(model_crc,frame[k]);
                feed_byte(frame[k]);
                @(posedge clk); #1;
                if(crc_residue!==model_crc) begin
                    $display("FAIL T6 byte %0d: RTL=0x%08X model=0x%08X",
                              k,crc_residue,model_crc);
                    mismatch=1; fail=fail+1;
                end
            end
            if(!mismatch) $display("PASS T6: RTL matches model for all 64 bytes");
        end

        if(fail==0) $display("ALL CRC TESTS PASSED");
        else        $display("%0d CRC TEST(S) FAILED",fail);
        $finish;
    end
endmodule