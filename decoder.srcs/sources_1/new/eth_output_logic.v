module eth_output_logic (
    input             clk125,
    input             arst125_n,
    input      [31:0] fifo_rdata,
    input             fifo_empty,
    output reg        fifo_rd_en,
    output reg        sof,
    output reg [7:0]  data,
    output reg [2:0]  data_id,
    output reg        eof,
    output reg [15:0] status
);
    localparam [1:0]
        IDLE_OUT  = 2'd0,
        READ_WAIT = 2'd1,
        OUTPUT    = 2'd2;
 
    reg [1:0] state;
 
    // Unpack current FIFO word
    wire        word_sof    = fifo_rdata[31];
    wire        word_eof    = fifo_rdata[30];
    wire [2:0]  word_did    = fifo_rdata[29:27];
    wire [7:0]  word_data   = fifo_rdata[23:16];
    wire [15:0] word_status = fifo_rdata[15:0];
 
    always @(posedge clk125 or negedge arst125_n) begin
        if (!arst125_n) begin
            state      <= IDLE_OUT;
            fifo_rd_en <= 1'b0;
            sof        <= 1'b0;
            eof        <= 1'b0;
            data       <= 8'd0;
            data_id    <= 3'd0;
            status     <= 16'd0;
        end else begin
            // Default: de-assert pulses
            sof        <= 1'b0;
            eof        <= 1'b0;
            fifo_rd_en <= 1'b0;
 
            case (state)
                IDLE_OUT: begin
                    if (!fifo_empty) begin
                        fifo_rd_en <= 1'b1;
                        state      <= READ_WAIT;
                    end
                end
 
                READ_WAIT: begin
                    // FIFO data will be valid next cycle
                    state <= OUTPUT;
                end
 
                OUTPUT: begin
                    // Present the word read in previous cycle
                    sof     <= word_sof;
                    eof     <= word_eof;
                    data    <= word_data;
                    data_id <= word_did;
 
                    if (word_eof) begin
                        // Latch status and return to idle
                        status <= word_status;
                        state  <= IDLE_OUT;
                    end else begin
                        // Fetch next word if available
                        if (!fifo_empty) begin
                            fifo_rd_en <= 1'b1;
                            state      <= READ_WAIT;
                        end else begin
                            state <= IDLE_OUT;
                        end
                    end
                end
 
                default: state <= IDLE_OUT;
            endcase
        end
    end
endmodule