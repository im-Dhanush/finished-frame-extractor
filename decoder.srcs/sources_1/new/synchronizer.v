  module synchronizer (
    input  wire  sample_clk,     // (16x of 10 Mbps MDI)
    input  wire  arst_n,         // Active LOW 
    input  wire  mdi,            
    output wire  mdi_sync        // MDI synchronized with 160
);
    
    (* ASYNC_REG = "TRUE" *) reg sync_ff1;
    (* ASYNC_REG = "TRUE" *) reg sync_ff2;
    
    always @(posedge sample_clk or negedge arst_n) begin
        if (!arst_n) begin // active low
            sync_ff1 <= 1'b0;
            sync_ff2 <= 1'b0;
        end else begin
            sync_ff1 <= mdi;       
            sync_ff2 <= sync_ff1;   
        end
    end

    assign mdi_sync = sync_ff2;
endmodule
