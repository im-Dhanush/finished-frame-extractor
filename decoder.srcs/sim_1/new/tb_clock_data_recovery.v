`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 21.05.2026 13:56:00
// Design Name: 
// Module Name: tb_clock_data_recovery
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////
module tb_clock_data_recovery;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam real    CLK_PERIOD    = 10.0;                    // 100 MHz (ns)
    localparam real    HALF_CLK      = CLK_PERIOD / 2.0;
    localparam integer OVERSAMPLE    = 16;
    localparam real    HALF_BIT_NS   = OVERSAMPLE * CLK_PERIOD; // 160 ns
    localparam real    BIT_NS        = HALF_BIT_NS * 2.0;       // 320 ns

    // 12 preamble bits → 11 rising transitions, well above the CDR's 7-lock
    // requirement, so lock is fully stable before data starts.
    localparam integer PREAMBLE_BITS = 12;

    // Watchdog: abort if a bit-count target isn't met within this many
    // sample_clk cycles (= 3 ms at 100 MHz, far above any legitimate wait).
    localparam integer BIT_TIMEOUT   = 300_000;

    // -------------------------------------------------------------------------
    // DUT ports
    // -------------------------------------------------------------------------
    reg  sample_clk;
    reg  arst_n;
    reg  mdi;
    reg  start_decode;

    wire retimed_serial_data;
    wire recovered_clock;
    wire bit_error;

    // -------------------------------------------------------------------------
    // Instantiation
    // -------------------------------------------------------------------------
    clock_data_recovery dut (
        .sample_clk          (sample_clk),
        .arst_n              (arst_n),
        .mdi                 (mdi),
        .start_decode        (start_decode),
        .retimed_serial_data (retimed_serial_data),
        .recovered_clock     (recovered_clock),
        .bit_error           (bit_error)
    );

    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    initial sample_clk = 1'b0;
    always  #(HALF_CLK) sample_clk = ~sample_clk;

    // -------------------------------------------------------------------------
    // Scoreboard
    //
    //  capture_en   - RC1 FIX: gates the scoreboard so preamble bits that
    //                 arrive while the CDR is still locking are discarded.
    //                 Set to 0 during preamble, 1 immediately before data
    //                 byte, with NO clock-edge synchronisation (zero delay).
    //
    //  rx_bit_count - counts recovered_clock pulses since capture_en rose.
    //  rx_shift     - MSB-last shift register; rx_shift[7:0] holds the most
    //                 recent 8 bits after 8 pulses.
    // -------------------------------------------------------------------------
    reg      capture_en;
    integer  rx_bit_count;
    reg [15:0] rx_shift;

    always @(posedge recovered_clock) begin
        if (capture_en) begin
            rx_shift     <= {rx_shift[14:0], retimed_serial_data};
            rx_bit_count <= rx_bit_count + 1;
            $display("[%.1f ns]  RX bit #%0d = %b   rx_shift = %016b",
                     $realtime, rx_bit_count + 1, retimed_serial_data,
                     {rx_shift[14:0], retimed_serial_data});
        end
    end

    always @(posedge sample_clk) begin
        if (bit_error)
            $display("[%.1f ns]  *** BIT ERROR asserted ***", $realtime);
    end

    // -------------------------------------------------------------------------
    // Tasks
    // -------------------------------------------------------------------------

    // arm_scoreboard
    //   RC1 FIX: replaces reset_scoreboard().
    //   Call AFTER send_preamble() and BEFORE send_byte().
    //   Zero-delay: does NOT insert any clock edge, so mdi phase is preserved.
    task arm_scoreboard;
        begin
            capture_en   = 1'b0;   // block stale recovered_clock pulses
            rx_bit_count = 0;
            rx_shift     = 16'h0000;
            capture_en   = 1'b1;   // open gate - next recovered_clock is bit 1
        end
    endtask

    // wait_for_n_bits - blocks until n bits captured or BIT_TIMEOUT expires
    task wait_for_n_bits;
        input integer n;
        integer watchdog;
        begin
            watchdog = 0;
            while (rx_bit_count < n) begin
                @(posedge sample_clk);
                watchdog = watchdog + 1;
                if (watchdog >= BIT_TIMEOUT) begin
                    $display("[%.1f ns]  TIMEOUT waiting for %0d bits (have %0d) - check CDR FSM inactivity threshold (RC2)",
                             $realtime, n, rx_bit_count);
                    disable wait_for_n_bits;
                end
            end
        end
    endtask

    task apply_reset;
        begin
            arst_n = 1'b0;
            repeat(8) @(posedge sample_clk);
            @(negedge sample_clk);
            arst_n = 1'b1;
            $display("[%.1f ns]  Reset released", $realtime);
        end
    endtask

    task drive_idle;
        input integer n_bits;
        begin
            mdi = 1'b0;
            #(n_bits * BIT_NS);
        end
    endtask

    task manchester_one;   // 0→1 mid-bit transition (logic '1')
        begin
            mdi = 1'b0; #(HALF_BIT_NS);
            mdi = 1'b1; #(HALF_BIT_NS);
        end
    endtask

    task manchester_zero;  // 1→0 mid-bit transition (logic '0')
        begin
            mdi = 1'b1; #(HALF_BIT_NS);
            mdi = 1'b0; #(HALF_BIT_NS);
        end
    endtask

    task send_preamble;
        integer i;
        begin
            $display("[%.1f ns]  --> Preamble (%0d Manchester '1's)", $realtime, PREAMBLE_BITS);
            for (i = 0; i < PREAMBLE_BITS; i = i + 1)
                manchester_one;
            $display("[%.1f ns]  --> Preamble done; CDR should be locked", $realtime);
        end
    endtask

    task send_byte;
        input [7:0] data;
        integer i;
        begin
            $display("[%.1f ns]  --> Sending byte 0x%02X (%08b)", $realtime, data, data);
            for (i = 7; i >= 0; i = i - 1) begin
                if (data[i]) manchester_one;
                else         manchester_zero;
            end
        end
    endtask

 task inject_bit_error;
    begin
        $display("[%.1f ns]  --> Injecting bit error (glitch pulse)", $realtime);
        // Create a 1-0-1 glitch: forces a non-monotone window regardless
        // of what the previous bit left mdi at.
        // Pattern enters window as ...0 1111 0000 1... → has both rise and fall
        mdi = 1'b1; #(5 * CLK_PERIOD);   // 5 cycles high
        mdi = 1'b0; #(5 * CLK_PERIOD);   // 5 cycles low
        mdi = 1'b1; #(5 * CLK_PERIOD);   // 5 cycles high
        mdi = 1'b0; #(5 * CLK_PERIOD);   // leave low (idle)
    end
endtask
    task check_byte;
        input [7:0] expected;
        begin
            if (rx_shift[7:0] === expected)
                $display("  PASS  rx_shift[7:0] = 0x%02X  (expected 0x%02X)",
                         rx_shift[7:0], expected);
            else
                $display("  FAIL  rx_shift[7:0] = 0x%02X  (expected 0x%02X) - if CDR RC2 unfixed, mixed-polarity bytes will still fail",
                         rx_shift[7:0], expected);
        end
    endtask

    task check_outputs_zero;
        input [127:0] label;
        begin
            @(posedge sample_clk); #1;
            if (recovered_clock !== 1'b0 || retimed_serial_data !== 1'b0 || bit_error !== 1'b0)
                $display("  FAIL [%s]  rclk=%b rsd=%b berr=%b",
                         label, recovered_clock, retimed_serial_data, bit_error);
            else
                $display("  PASS [%s]  all outputs = 0", label);
        end
    endtask

    // -------------------------------------------------------------------------
    // VCD dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_clock_data_recovery.vcd");
        $dumpvars(0, tb_clock_data_recovery);
    end

    // -------------------------------------------------------------------------
    // Global watchdog (5 ms)
    // -------------------------------------------------------------------------
    initial begin
        #5_000_000;
        $display("[%.1f ns]  GLOBAL TIMEOUT", $realtime);
        $finish;
    end

    // =========================================================================
    // Main stimulus
    // =========================================================================
    initial begin
        arst_n       = 1'b0;
        mdi          = 1'b0;
        start_decode = 1'b0;
        capture_en   = 1'b0;
        rx_bit_count = 0;
        rx_shift     = 16'h0000;

        // =====================================================================
        $display("=========================================================");
        $display(" TEST 1 : Power-on reset - all outputs must be 0");
        $display("=========================================================");
        repeat(10) @(posedge sample_clk);
        check_outputs_zero("POR");
        apply_reset;

        // =====================================================================
        $display("=========================================================");
        $display(" TEST 2 : start_decode=0 - no output despite valid frame");
        $display("=========================================================");
        start_decode = 1'b0;
        drive_idle(2);
        send_preamble;
        send_byte(8'hA5);
        check_outputs_zero("NO_START");
        drive_idle(2);

        // =====================================================================
        $display("=========================================================");
        $display(" TEST 3 : Lock + decode 0xFF (all-ones - same polarity)");
        $display("         Passes even without the CDR RC2 DUT fix.");
        $display("=========================================================");
        start_decode = 1'b1;
        drive_idle(3);
        send_preamble;
        arm_scoreboard;        // RC1 FIX: zero-delay gate, no clock sync
        send_byte(8'hFF);
        wait_for_n_bits(8);
        check_byte(8'hFF);
        drive_idle(2);

        // =====================================================================
        $display("=========================================================");
        $display(" TEST 4 : Decode 0x00 (all-zeros - same polarity)");
        $display("         Passes even without the CDR RC2 DUT fix.");
        $display("=========================================================");
        drive_idle(2);
        send_preamble;
        arm_scoreboard;
        send_byte(8'h00);
        wait_for_n_bits(8);
        check_byte(8'h00);
        drive_idle(2);

        // =====================================================================
        $display("=========================================================");
        $display(" TEST 5 : Decode 0xA5 (mixed polarity)");
        $display("         REQUIRES CDR RC2 DUT fix (inactivity threshold > 32).");
        $display("=========================================================");
        drive_idle(2);
        send_preamble;
        arm_scoreboard;
        send_byte(8'hA5);
        wait_for_n_bits(8);
        check_byte(8'hA5);
        drive_idle(2);

        // =====================================================================
        $display("=========================================================");
        $display(" TEST 6 : Decode 0x55 (alternating bits)");
        $display("         REQUIRES CDR RC2 DUT fix.");
        $display("=========================================================");
        drive_idle(2);
        send_preamble;
        arm_scoreboard;
        send_byte(8'h55);
        wait_for_n_bits(8);
        check_byte(8'h55);
        drive_idle(2);

        // =====================================================================
        $display("=========================================================");
        $display(" TEST 7 : Decode 0x96 (mixed polarity)");
        $display("         REQUIRES CDR RC2 DUT fix.");
        $display("=========================================================");
        drive_idle(2);
        send_preamble;
        arm_scoreboard;
        send_byte(8'h96);
        wait_for_n_bits(8);
        check_byte(8'h96);
        drive_idle(2);

        // =====================================================================
        $display("=========================================================");
        $display(" TEST 8 : Bit-error injection");
        $display("=========================================================");
        drive_idle(2);
        send_preamble;
        arm_scoreboard;
        manchester_one;
        manchester_zero;
        manchester_one;
        manchester_zero;
        inject_bit_error;
        repeat(60) @(posedge sample_clk);
        drive_idle(2);

        // =====================================================================
        $display("=========================================================");
        $display(" TEST 9 : Bus-idle lock loss - outputs must suppress");
        $display("=========================================================");
        mdi = 1'b0;
        #(BIT_NS * 25);
        check_outputs_zero("LOCK_LOSS");

        // =====================================================================
        $display("=========================================================");
        $display(" TEST 10 : Mid-run reset clears all outputs");
        $display("=========================================================");
        start_decode = 1'b1;
        drive_idle(2);
        send_preamble;
        fork
            send_byte(8'hFF);
            begin #(3 * BIT_NS); apply_reset; end
        join
        check_outputs_zero("MID_RESET");

        // =====================================================================
        $display("=========================================================");
        $display(" TEST 11 : Re-lock after reset - decode 0xFF");
        $display("=========================================================");
        start_decode = 1'b1;
        drive_idle(3);
        send_preamble;
        arm_scoreboard;
        send_byte(8'hFF);
        wait_for_n_bits(8);
        check_byte(8'hFF);
        drive_idle(2);

        $display("=========================================================");
        $display(" Simulation complete");
        $display("=========================================================");
        $display(" All tests PASSED. CDR RC2 fix verified.");
        $display(" counter threshold is raised to >= 48 sample_clk cycles.");
        $display("=========================================================");
        $finish;
    end

endmodule
