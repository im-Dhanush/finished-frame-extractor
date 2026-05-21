`timescale 1ns / 1ps


module cdr_fsm (
    input  wire  sample_clk,
    input  wire  arst_n,
    input  wire  start_decode,
    input  wire  mdi_sync,
    output reg   lock
);

    localparam [1:0] IDLE             = 2'b00,
                     WAIT_IDLE_CYCLES = 2'b01,
                     WAIT_PREAMBLE    = 2'b10,
                     CHK_BUS_ACTIVITY = 2'b11;

    reg [1:0] state;

    // -------------------------------------------------------------------------
    // Edge detection on mdi_sync
    // -------------------------------------------------------------------------
    reg mdi_sync_d;

    always @(posedge sample_clk or negedge arst_n) begin
        if (!arst_n) mdi_sync_d <= 1'b0;
        else         mdi_sync_d <= mdi_sync;
    end

    wire rising_edge  = ~mdi_sync_d & mdi_sync;
    wire falling_edge =  mdi_sync_d & ~mdi_sync;
    wire any_edge     = rising_edge | falling_edge;

    // -------------------------------------------------------------------------
    // Counters
    // -------------------------------------------------------------------------
    reg [3:0] trans_count;

    // FIX: was "reg [4:0] no_act_timer" (max 31, threshold 24).
    //      One Manchester bit = 32 sample_clk cycles, so max gap between
    //      valid transitions is 32 cycles.  24 < 32 → premature lock loss.
    //      6 bits needed to hold threshold 48 (1.5 × 32).
    reg [5:0] no_act_timer;  // FIXED: widened from 5 to 6 bits

    reg       last_rising;

    // -------------------------------------------------------------------------
    // Transition condition wires
    // -------------------------------------------------------------------------
    wire idle_cycles_done = (trans_count == 4'd9) & any_edge;
    wire preamble_done    = (trans_count == 4'd6) & rising_edge;
    wire preamble_error   = last_rising & rising_edge;

    // FIX: was "5'd24".  Correct value = 1.5 × 32 = 48 sample_clk cycles.
    wire no_activity = (no_act_timer >= 6'd48);  // FIXED: was 5'd24

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    always @(posedge sample_clk or negedge arst_n) begin
        if (!arst_n) begin
            state        <= IDLE;
            lock         <= 1'b0;
            trans_count  <= 4'd0;
            no_act_timer <= 6'd0;
            last_rising  <= 1'b0;

        end else begin
            case (state)

                IDLE: begin
                    lock         <= 1'b0;
                    trans_count  <= 4'd0;
                    no_act_timer <= 6'd0;
                    last_rising  <= 1'b0;
                    if (start_decode)
                        state <= WAIT_IDLE_CYCLES;
                end

                WAIT_IDLE_CYCLES: begin
                    if (!start_decode) begin
                        state       <= IDLE;
                        trans_count <= 4'd0;
                    end else if (any_edge) begin
                        if (idle_cycles_done) begin
                            state       <= WAIT_PREAMBLE;
                            trans_count <= 4'd0;
                            last_rising <= 1'b0;
                        end else begin
                            trans_count <= trans_count + 4'd1;
                        end
                    end
                end

                WAIT_PREAMBLE: begin
                    if (!start_decode) begin
                        state       <= IDLE;
                        trans_count <= 4'd0;
                        last_rising <= 1'b0;
                    end else if (any_edge) begin
                        if (preamble_error) begin
                            state       <= IDLE;
                            trans_count <= 4'd0;
                            last_rising <= 1'b0;
                            lock        <= 1'b0;
                        end else if (preamble_done) begin
                            state        <= CHK_BUS_ACTIVITY;
                            trans_count  <= 4'd0;
                            no_act_timer <= 6'd0;
                            last_rising  <= 1'b1;
                            lock         <= 1'b1;
                        end else begin
                            if (rising_edge) begin
                                trans_count <= trans_count + 4'd1;
                                last_rising <= 1'b1;
                            end else begin
                                last_rising <= 1'b0;
                            end
                        end
                    end
                end

                CHK_BUS_ACTIVITY: begin
                    if (!start_decode) begin
                        state        <= IDLE;
                        lock         <= 1'b0;
                        no_act_timer <= 6'd0;

                    end else if (no_activity) begin
                        state        <= IDLE;
                        lock         <= 1'b0;
                        no_act_timer <= 6'd0;
                        trans_count  <= 4'd0;

                    end else begin
                        if (any_edge)
                            no_act_timer <= 6'd0;
                        else
                            no_act_timer <= no_act_timer + 6'd1;
                    end
                end

                default: begin
                    state <= IDLE;
                    lock  <= 1'b0;
                end

            endcase
        end
    end

endmodule
