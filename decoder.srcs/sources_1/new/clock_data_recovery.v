`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 21.05.2026 13:50:43
// Design Name: 
// Module Name: Clock_data_recovery
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
module clock_data_recovery (
    input  wire  sample_clk,
    input  wire  arst_n,
    input  wire  mdi,
    input  wire  start_decode,

    output reg   retimed_serial_data,
    output reg   recovered_clock,
    output reg   bit_error
);

    wire mdi_sync;
    wire lock;
    wire detect_one;
    wire detect_zero;
    wire bit_error_raw;

    synchronizer u_synchronizer (
        .sample_clk (sample_clk),
        .arst_n     (arst_n),
        .mdi        (mdi),
        .mdi_sync   (mdi_sync)
    );

    cdr_fsm u_cdr_fsm (
        .sample_clk   (sample_clk),
        .arst_n       (arst_n),
        .start_decode (start_decode),
        .mdi_sync     (mdi_sync),
        .lock         (lock)
    );

    data_sampling_comparison u_data_sampling (
        .sample_clk  (sample_clk),
        .arst_n      (arst_n),
        .mdi_sync    (mdi_sync),
        .detect_one  (detect_one),
        .detect_zero (detect_zero),
        .bit_error   (bit_error_raw)
    );

    // -- Rising-edge detector on detect_valid --------------------------------
    reg  detect_valid_d;
    wire detect_valid = detect_one | detect_zero;

    always @(posedge sample_clk or negedge arst_n) begin
        if (!arst_n) detect_valid_d <= 1'b0;
        else         detect_valid_d <= detect_valid;
    end

    wire bit_pulse_raw = detect_valid & ~detect_valid_d;

    // -- Blanking counter ----------------------------------------------------
    // FIX: was 5'd24. Correct value = 10.
    // Timing proof (cycles measured from start of current bit):
    //   bit_pulse fires at cycle 18. blank_cnt reloaded to 10.
    //   Same-value boundary detect at cycle 25: 10-(25-18)=3 → suppressed ✓
    //   Next bit centre detect    at cycle 33: 10-(33-18)=-5 → expired  ✓
    //   With ±2 jitter: boundary at 23: 10-5=5 suppressed ✓
    //                   centre  at 35: 10-17=-7 expired ✓
    reg [3:0] blank_cnt;                      // 4 bits covers 0..10
    wire      blanking = (blank_cnt != 4'd0);

    always @(posedge sample_clk or negedge arst_n) begin
        if (!arst_n)
            blank_cnt <= 4'd0;
        else if (bit_pulse_raw & ~blanking)
            blank_cnt <= 4'd10;              // FIX: was 5'd24
        else if (blank_cnt != 4'd0)
            blank_cnt <= blank_cnt - 4'd1;
    end

    wire bit_pulse = bit_pulse_raw & ~blanking;

    // -- Output register -----------------------------------------------------
    always @(posedge sample_clk or negedge arst_n) begin
        if (!arst_n) begin
            recovered_clock     <= 1'b0;
            retimed_serial_data <= 1'b0;
            bit_error           <= 1'b0;
        end else begin
            if (lock) begin
                recovered_clock <= bit_pulse;
                if (bit_pulse)
                    retimed_serial_data <= detect_one;
                // FIX: bit_error registered every cycle, not gated by bit_pulse.
                // A jittered bit never fires bit_pulse (detect_valid stays 0),
                // so gating by bit_pulse means bit_error is never sampled.
                bit_error <= bit_error_raw;
            end else begin
                recovered_clock     <= 1'b0;
                retimed_serial_data <= 1'b0;
                bit_error           <= 1'b0;
            end
        end
    end

endmodule
