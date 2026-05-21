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

    // -------------------------------------------------------------------------
    // Internal wires connecting sub-blocks
    // -------------------------------------------------------------------------
    wire mdi_sync;
    wire lock;
    wire detect_one;
    wire detect_zero;
    wire bit_error_raw;

    // =========================================================================
    // 1. Synchronizer
    // =========================================================================
    synchronizer u_synchronizer (
        .sample_clk ( sample_clk ),
        .arst_n     ( arst_n     ),
        .mdi        ( mdi        ),
        .mdi_sync   ( mdi_sync   )
    );

    // =========================================================================
    // 2. CDR FSM
    // =========================================================================
    cdr_fsm u_cdr_fsm (
        .sample_clk   ( sample_clk   ),
        .arst_n       ( arst_n       ),
        .start_decode ( start_decode ),
        .mdi_sync     ( mdi_sync     ),
        .lock         ( lock         )
    );

    // =========================================================================
    // 3. Data Sampling & Comparison Logic
    // =========================================================================
    data_sampling_comparison u_data_sampling (
        .sample_clk  ( sample_clk  ),
        .arst_n      ( arst_n      ),
        .mdi_sync    ( mdi_sync    ),
        .detect_one  ( detect_one  ),
        .detect_zero ( detect_zero ),
        .bit_error   ( bit_error_raw )
    );

    // =========================================================================
    // 4. MUX / Output Gate
    // =========================================================================

    // -- Step 1: rising-edge detector on (detect_one | detect_zero) -----------
    //    Fires on the first sample_clk cycle that a clean transition pattern
    //    first enters the 12-bit jitter window.
    reg  detect_valid_d;
    wire detect_valid = detect_one | detect_zero;

    always @(posedge sample_clk or negedge arst_n) begin
        if (!arst_n) detect_valid_d <= 1'b0;
        else         detect_valid_d <= detect_valid;
    end

    wire bit_pulse_raw = detect_valid & ~detect_valid_d;

    
    reg [4:0] blank_cnt;                              // 5 bits covers 0..24
    wire      blanking = (blank_cnt != 5'd0);

    always @(posedge sample_clk or negedge arst_n) begin
        if (!arst_n)
            blank_cnt <= 5'd0;
        else if (bit_pulse_raw & ~blanking)           // new un-blanked pulse
            blank_cnt <= 5'd24;                       // reload blanking window
        else if (blank_cnt != 5'd0)
            blank_cnt <= blank_cnt - 5'd1;            // count down
    end

    // Gated bit pulse: exactly one pulse per Manchester bit cell
    wire bit_pulse = bit_pulse_raw & ~blanking;

    // -- Step 3: registered MUX outputs ---------------------------------------
    always @(posedge sample_clk or negedge arst_n) begin
        if (!arst_n) begin
            recovered_clock     <= 1'b0;
            retimed_serial_data <= 1'b0;
            bit_error           <= 1'b0;
        end else begin
            if (lock) begin
                recovered_clock     <= bit_pulse;     // 1-cycle pulse per bit
                retimed_serial_data <= detect_one;    // '1' on 0→1, '0' on 1→0
                bit_error           <= bit_error_raw;
            end else begin
                recovered_clock     <= 1'b0;
                retimed_serial_data <= 1'b0;
                bit_error           <= 1'b0;
            end
        end
    end

endmodule
