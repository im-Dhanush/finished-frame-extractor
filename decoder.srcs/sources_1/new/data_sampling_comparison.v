module data_sampling_comparison (
    input  wire        sample_clk,   // 160 MHz (16× of 10 Mbps MDI)
    input  wire        arst_n,       // Active LOW asynchronous reset
    input  wire        mdi_sync,     // Synchronized MDI from synchronizer
 
    // All three outputs are now COMBINATIONAL 1-cycle strobes.
    // clock_data_recovery.v registers them at the output stage.
    output wire        detect_one,   // Valid 0→1 transition: Manchester "1"
    output wire        detect_zero,  // Valid 1→0 transition: Manchester "0"
    output wire        bit_error     // Transition present but outside ±12.5% window
);
 
    reg [15:0] sample_reg;
 
    always @(posedge sample_clk or negedge arst_n) begin
        if (!arst_n)
            sample_reg <= 16'h0000;
        else
            sample_reg <= { sample_reg[14:0], mdi_sync };
    end
 
    wire [11:0] window = sample_reg[13:2];
 
    assign detect_one  = (window == 12'h03F);   // 000000111111
    assign detect_zero = (window == 12'hFC0);   // 111111000000
    wire transition_zone;

assign transition_zone =
       (window[11:6] != window[5:0]);
 
    //wire has_transition = |(window[11:1] ^ window[10:0]);  // any adjacent edge
 
    assign bit_error =
       transition_zone &&
       !detect_one &&
       !detect_zero;
 
endmodule
