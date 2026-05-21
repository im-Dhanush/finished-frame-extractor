`timescale 1ns / 1ps
module data_sampling_comparison (
    
    input  wire        sample_clk,    // 160 MHz (16x of 10 Mbps MDI)
    input  wire        arst_n,        // Active LOW 
    input  wire        mdi_sync,      // Synchronized MDI
    output reg         detect_one,    // Valid 0→1 transition detected
    output reg         detect_zero,   // Valid 1→0 transition detected
    output reg         bit_error      // exceeds ±12.5% jitter
);

    reg [15:0] sample_reg;

    always @(posedge sample_clk or negedge arst_n) begin
        if (!arst_n)
            sample_reg <= 16'h0000;
        else
            sample_reg <= { sample_reg[14:0], mdi_sync };  
    end

    wire [11:0] window;
    assign window = sample_reg[13:2];

    always @(posedge sample_clk or negedge arst_n) begin
    if (!arst_n) begin
        detect_one  <= 1'b0;
        detect_zero <= 1'b0;
        bit_error   <= 1'b0;
    end else begin
        case (window)
            12'h03F: begin                  // 000000111111 - valid '1'
                detect_one  <= 1'b1;
                detect_zero <= 1'b0;
                bit_error   <= 1'b0;
            end
            12'hFC0: begin                  // 111111000000 - valid '0'
                detect_one  <= 1'b0;
                detect_zero <= 1'b1;
                bit_error   <= 1'b0;
            end
            default: begin
                detect_one  <= 1'b0;
                detect_zero <= 1'b0;
                
                 bit_error <= (|(~window[11:1] & window[10:0]))   // has a rising edge
                           & (| (window[11:1] & ~window[10:0])); // AND a falling edge
            end
        endcase
    end
end
endmodule
