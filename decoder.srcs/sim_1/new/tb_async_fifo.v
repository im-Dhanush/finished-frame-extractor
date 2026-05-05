`timescale 1ns/1ps
// Testbench for async_fifo
// Tests: empty after reset, data integrity, full flag, no-write-when-full,
//        drain to empty, simultaneous R/W, reset mid-operation.
module tb_async_fifo;
    localparam AW    = 4;
    localparam DEPTH = 1 << AW;  // 16

    reg         wr_clk, rd_clk;
    reg         wr_arst_n, rd_arst_n;
    reg         wr_en, rd_en;
    reg  [31:0] din;
    wire [31:0] dout;
    wire        full, empty;
    integer     fail;

    async_fifo #(.DATA_WIDTH(32), .ADDR_WIDTH(AW)) DUT (
        .wr_clk    (wr_clk),
        .rd_clk    (rd_clk),
        .wr_arst_n (wr_arst_n),
        .rd_arst_n (rd_arst_n),
        .wr_en     (wr_en),
        .rd_en     (rd_en),
        .din       (din),
        .dout      (dout),
        .full      (full),
        .empty     (empty)
    );

    always #5 wr_clk = ~wr_clk;  // 100 MHz
    always #4 rd_clk = ~rd_clk;  // 125 MHz

    task do_reset;
        begin
            wr_arst_n = 0; rd_arst_n = 0;
            wr_en = 0; rd_en = 0; din = 0;
            repeat(6) @(posedge wr_clk);
            wr_arst_n = 1; rd_arst_n = 1;
            repeat(6) @(posedge wr_clk);
        end
    endtask

    task write_word;
        input [31:0] d;
        begin
            @(negedge wr_clk);
            wr_en = 1'b1; din = d;
            @(negedge wr_clk);
            wr_en = 1'b0;
        end
    endtask

    task read_word;
        output [31:0] d;
        begin
            @(negedge rd_clk);
            rd_en = 1'b1;
            @(negedge rd_clk);
            rd_en = 1'b0;
            @(posedge rd_clk); #1;
            d = dout;
        end
    endtask

    integer i;
    reg [31:0] got;

    initial begin
        fail = 0;
        wr_clk = 0; rd_clk = 0;
        wr_arst_n = 0; rd_arst_n = 0;
        wr_en = 0; rd_en = 0; din = 0;

        do_reset;

        // T1: empty after reset
        repeat(4) @(posedge rd_clk);
        if (!empty) begin
            $display("FAIL T1: not empty after reset"); fail = fail + 1;
        end else $display("PASS T1: empty after reset");

        // T2: write 8 words, allow sync latency, read back, verify data
        for (i = 1; i <= 8; i = i + 1) write_word(i);
        repeat(8) @(posedge rd_clk);  // allow gray-code sync

        for (i = 1; i <= 8; i = i + 1) begin
            read_word(got);
            if (got !== i) begin
                $display("FAIL T2[%0d]: got=0x%08X expected=0x%08X", i, got, i);
                fail = fail + 1;
            end
        end
        if (fail == 0) $display("PASS T2: data integrity OK");

        do_reset;

        // T3: fill to full
        for (i = 0; i < DEPTH; i = i + 1) write_word(i);
        repeat(8) @(posedge wr_clk);
        if (!full) begin
            $display("FAIL T3: full not asserted after %0d writes", DEPTH);
            fail = fail + 1;
        end else $display("PASS T3: full asserted correctly");

        // T4: no write when full
        begin : T4
            reg [AW:0] saved_wr;
            saved_wr = DUT.wr_ptr_bin;
            write_word(32'hDEADBEEF);
            if (DUT.wr_ptr_bin !== saved_wr) begin
                $display("FAIL T4: wr_ptr advanced on full"); fail = fail + 1;
            end else $display("PASS T4: no write when full");
        end

        // T5: drain to empty
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(negedge rd_clk); rd_en = 1;
            @(negedge rd_clk); rd_en = 0;
        end
        repeat(8) @(posedge rd_clk);
        if (!empty) begin
            $display("FAIL T5: not empty after full drain"); fail = fail + 1;
        end else $display("PASS T5: empty after drain");

        // T6: simultaneous read/write (no hang)
        do_reset;
        fork
            begin : WRITER
                integer w;
                for (w = 0; w < DEPTH; w = w + 1) begin
                    @(negedge wr_clk);
                    if (!full) begin wr_en = 1; din = w; end
                    @(negedge wr_clk); wr_en = 0;
                end
            end
            begin : READER
                integer r;
                repeat(8) @(posedge rd_clk);
                for (r = 0; r < DEPTH; r = r + 1) begin
                    @(negedge rd_clk);
                    if (!empty) rd_en = 1;
                    @(negedge rd_clk); rd_en = 0;
                end
            end
        join
        $display("PASS T6: simultaneous read/write no hang");

        // T7: reset mid-operation
        write_word(32'hCAFEBABE);
        do_reset;
        repeat(8) @(posedge rd_clk);
        if (!empty) begin
            $display("FAIL T7: not empty after mid-op reset"); fail = fail + 1;
        end else $display("PASS T7: reset mid-operation correct");

        if (fail == 0) $display("ALL ASYNC FIFO TESTS PASSED");
        else           $display("%0d ASYNC FIFO TEST(S) FAILED", fail);
        $finish;
    end
endmodule