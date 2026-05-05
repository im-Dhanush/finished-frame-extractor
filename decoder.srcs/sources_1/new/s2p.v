module s2p (
    input  wire       sample_clk,
    input  wire       arst_n,
    input  wire       retimed_serial_data,
    input  wire       recovered_clock,     // single-cycle clock-enable per bit
    output reg  [7:0] eth_pkt_data,
    output reg        pkt_data_valid
);
    reg [7:0] shift_reg;
    reg [2:0] bit_cnt;
 
    always @(posedge sample_clk or negedge arst_n) begin
        if (!arst_n) begin
            shift_reg      <= 8'd0;
            bit_cnt        <= 3'd0;
            eth_pkt_data   <= 8'd0;
            pkt_data_valid <= 1'b0;
        end else begin
            // Default: de-assert valid every cycle
            pkt_data_valid <= 1'b0;
 
            if (recovered_clock) begin
                // IEEE 802.3 transmits LSB first; shift in from MSB side
                // so that after 8 bits shift_reg holds the correct byte.
                shift_reg <= {retimed_serial_data, shift_reg[7:1]};
 
                if (bit_cnt == 3'd7) begin
                    // Final bit: latch completed byte
                    eth_pkt_data   <= {retimed_serial_data, shift_reg[7:1]};
                    pkt_data_valid <= 1'b1;
                    bit_cnt        <= 3'd0;
                end else begin
                    bit_cnt <= bit_cnt + 3'd1;
                end
            end
        end
    end
endmodule