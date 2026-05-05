module sync_2ff(
    input  wire clk,
    input  wire arst_n,
    input  wire d,
    output reg  q
);
    reg q1;
    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            q1 <= 1'b0;
            q  <= 1'b0;
        end else begin
            q1 <= d;
            q  <= q1;
        end
    end
endmodule