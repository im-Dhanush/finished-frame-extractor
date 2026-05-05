module simple_fifo #(
    parameter WIDTH = 32,
    parameter DEPTH = 16
)(
    input              clk,
    input              rst_n,
    input              wr_en,
    input  [WIDTH-1:0] din,
    input              rd_en,
    output reg [WIDTH-1:0] dout,
    output             empty,
    output             full
);
    localparam PTR_W = $clog2(DEPTH);
 
    reg [WIDTH-1:0] mem   [0:DEPTH-1];
    reg [PTR_W-1:0] wr_ptr, rd_ptr;
    reg [PTR_W:0]   count;          // one extra bit to hold DEPTH
 
    assign empty = (count == 0);
    assign full  = (count == DEPTH);
 
    wire do_wr = wr_en && !full;
    wire do_rd = rd_en && !empty;
 
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= {PTR_W{1'b0}};
            rd_ptr <= {PTR_W{1'b0}};
            count  <= {(PTR_W+1){1'b0}};
            dout   <= {WIDTH{1'b0}};
        end else begin
            if (do_wr) begin
                mem[wr_ptr] <= din;
                wr_ptr      <= wr_ptr + 1'b1;
            end
            if (do_rd) begin
                dout   <= mem[rd_ptr];
                rd_ptr <= rd_ptr + 1'b1;
            end
            // Simultaneous read+write: count stays the same
            case ({do_wr, do_rd})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end
endmodule