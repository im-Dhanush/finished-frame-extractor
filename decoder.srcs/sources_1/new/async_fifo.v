module async_fifo #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 11
)(
    input  wire                  wr_clk,
    input  wire                  rd_clk,
    input  wire                  wr_arst_n,
    input  wire                  rd_arst_n,
    input  wire                  wr_en,
    input  wire                  rd_en,
    input  wire [DATA_WIDTH-1:0] din,
    output reg  [DATA_WIDTH-1:0] dout,
    output wire                  full,
    output wire                  empty
);
    localparam DEPTH = 1 << ADDR_WIDTH;
 
    // Dual-port memory
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
 
    // Binary and Gray-code pointers (one extra bit for full/empty)
    reg [ADDR_WIDTH:0] wr_ptr_bin,  rd_ptr_bin;
    reg [ADDR_WIDTH:0] wr_ptr_gray, rd_ptr_gray;
 
    // Synchronizers: rd_gray into wr domain, wr_gray into rd domain
    reg [ADDR_WIDTH:0] rd_gray_sync1, rd_gray_sync2;
    reg [ADDR_WIDTH:0] wr_gray_sync1, wr_gray_sync2;
 
    // Next-pointer combinational
    wire [ADDR_WIDTH:0] wr_ptr_bin_next   = wr_ptr_bin  + {{ADDR_WIDTH{1'b0}}, 1'b1};
    wire [ADDR_WIDTH:0] rd_ptr_bin_next   = rd_ptr_bin  + {{ADDR_WIDTH{1'b0}}, 1'b1};
    wire [ADDR_WIDTH:0] wr_ptr_gray_next  = (wr_ptr_bin_next >> 1) ^ wr_ptr_bin_next;
    wire [ADDR_WIDTH:0] rd_ptr_gray_next  = (rd_ptr_bin_next >> 1) ^ rd_ptr_bin_next;
 
    // Full : MSB and next-MSB differ between wr_next_gray and synced rd_gray;
    //        remaining bits equal.
    assign full  = (wr_ptr_gray_next ==
                    {~rd_gray_sync2[ADDR_WIDTH:ADDR_WIDTH-1],
                      rd_gray_sync2[ADDR_WIDTH-2:0]});
 
    // Empty: rd_gray == synced wr_gray
    assign empty = (rd_ptr_gray == wr_gray_sync2);
 
    // ---- Write domain ----
    always @(posedge wr_clk or negedge wr_arst_n) begin
        if (!wr_arst_n) begin
            wr_ptr_bin  <= {(ADDR_WIDTH+1){1'b0}};
            wr_ptr_gray <= {(ADDR_WIDTH+1){1'b0}};
        end else if (wr_en && !full) begin
            mem[wr_ptr_bin[ADDR_WIDTH-1:0]] <= din;
            wr_ptr_bin  <= wr_ptr_bin_next;
            wr_ptr_gray <= wr_ptr_gray_next;
        end
    end
 
    // ---- Read domain ----
    always @(posedge rd_clk or negedge rd_arst_n) begin
        if (!rd_arst_n) begin
            rd_ptr_bin  <= {(ADDR_WIDTH+1){1'b0}};
            rd_ptr_gray <= {(ADDR_WIDTH+1){1'b0}};
            dout        <= {DATA_WIDTH{1'b0}};
        end else if (rd_en && !empty) begin
            dout        <= mem[rd_ptr_bin[ADDR_WIDTH-1:0]];
            rd_ptr_bin  <= rd_ptr_bin_next;
            rd_ptr_gray <= rd_ptr_gray_next;
        end
    end
 
    // ---- Synchronize rd_gray into wr domain ----
    always @(posedge wr_clk or negedge wr_arst_n) begin
        if (!wr_arst_n) begin
            rd_gray_sync1 <= {(ADDR_WIDTH+1){1'b0}};
            rd_gray_sync2 <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            rd_gray_sync1 <= rd_ptr_gray;
            rd_gray_sync2 <= rd_gray_sync1;
        end
    end
 
    // ---- Synchronize wr_gray into rd domain ----
    always @(posedge rd_clk or negedge rd_arst_n) begin
        if (!rd_arst_n) begin
            wr_gray_sync1 <= {(ADDR_WIDTH+1){1'b0}};
            wr_gray_sync2 <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            wr_gray_sync1 <= wr_ptr_gray;
            wr_gray_sync2 <= wr_gray_sync1;
        end
    end
endmodule