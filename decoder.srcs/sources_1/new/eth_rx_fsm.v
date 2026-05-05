// KEY DESIGN DECISIONS that eliminate all race conditions:
//
// 1. error_cause is a STICKY register, set as soon as bit_error or timeout
//    fires in ANY active state, and cleared only when returning to IDLE.
//    It is NOT derived from timeout_cnt or bit_error in STATUS_WAIT/STATUS_WRITE,
//    so timeout_cnt resets and bit_error pulse-clearing cannot corrupt it.
//
// 2. Two terminal states (STATUS_WAIT + STATUS_WRITE):
//    STATUS_WAIT  - settle cycle. CRC module absorbs the last byte this posedge.
//                   error_cause already registered from previous cycle. No FIFO write.
//    STATUS_WRITE - crc_residue is now settled (updated last posedge in STATUS_WAIT).
//                   error_cause is stable. EOF word written to FIFO.
//
// 3. status_nxt reads error_cause (sticky reg) and crc_residue (settled port).
//    Both are stable registered values in STATUS_WRITE. No races.
//
// FIFO word format:
//   [31]    = sof   (SFD word only)
//   [30]    = eof   (STATUS_WRITE word only)
//   [29:27] = data_id (0=SFD,1=DST,2=SRC,3=LEN,4=PAYLOAD,5=CRC/STATUS)
//   [26:24] = reserved
//   [23:16] = data byte
//   [15:0]  = status (eof word only)

module eth_rx_fsm #(
    parameter [8:0] BYTE_TIMEOUT = 9'd200
)(
    input             clk,
    input             rst_n,
    input             data_valid,
    input     [7:0]   data_in,
    input             bit_error,
    input             fifo_full,
    output reg        fifo_wr_en,
    output reg [31:0] fifo_din,
    output reg        crc_init,
    output reg        crc_en,
    input     [31:0]  crc_residue,
    output reg [15:0] status
);
    localparam [2:0]
        IDLE         = 3'd0,
        DST          = 3'd1,
        SRC          = 3'd2,
        LENGTH       = 3'd3,
        PAYLOAD      = 3'd4,
        CRC_S        = 3'd5,
        STATUS_WAIT  = 3'd6,
        STATUS_WRITE = 3'd7;

    localparam [7:0]  SFD_BYTE = 8'hD5;
    localparam [31:0] GOOD_CRC = 32'hDEBB20E3;

    reg [2:0]  state, next_state;
    reg [3:0]  byte_cnt;
    reg [15:0] payload_len;
    reg [15:0] payload_cnt;
    reg [8:0]  timeout_cnt;
    reg        length_msb_done;

    // Sticky error register - set the moment error is detected in any
    // active state, held until IDLE. Never read from timeout_cnt again
    // after being set, so timeout_cnt resets cannot corrupt it.
    reg [1:0]  error_cause;   // 0=none, 1=timeout, 2=bit_error

    // Active state = any state where we are receiving frame data
    wire active = (state == DST     || state == SRC    ||
                   state == LENGTH  || state == PAYLOAD ||
                   state == CRC_S);

    wire timeout_hit = (timeout_cnt >= BYTE_TIMEOUT);
    wire error_now   = (active) && (bit_error || timeout_hit);

    // Next-state
    always @(*) begin
        next_state = state;
        case (state)
            IDLE:
                if (data_valid && data_in == SFD_BYTE)
                    next_state = DST;
            DST:
                if      (error_now)                              next_state = STATUS_WAIT;
                else if (data_valid && byte_cnt == 4'd5)         next_state = SRC;
            SRC:
                if      (error_now)                              next_state = STATUS_WAIT;
                else if (data_valid && byte_cnt == 4'd5)         next_state = LENGTH;
            LENGTH:
                if      (error_now)                              next_state = STATUS_WAIT;
                else if (data_valid && byte_cnt == 4'd1)         next_state = PAYLOAD;
            PAYLOAD:
                if      (error_now)                              next_state = STATUS_WAIT;
                else if (data_valid &&
                         payload_cnt == payload_len - 16'd1)     next_state = CRC_S;
            CRC_S:
                if      (error_now)                              next_state = STATUS_WAIT;
                else if (data_valid && byte_cnt == 4'd3)         next_state = STATUS_WAIT;
            STATUS_WAIT:                                         next_state = STATUS_WRITE;
            STATUS_WRITE:                                        next_state = IDLE;
            default:                                             next_state = IDLE;
        endcase
    end

    // ----------------------------------------------------------------
    // status_nxt - combinational, evaluated in STATUS_WRITE.
    // error_cause: stable sticky register (set in earlier active state).
    // crc_residue: CRC module updated at STATUS_WAIT posedge → settled now.
    // ----------------------------------------------------------------
    reg [15:0] status_nxt;
    always @(*) begin
        if      (error_cause == 2'd2)      status_nxt = 16'h0004; // bit error
        else if (error_cause == 2'd1)      status_nxt = 16'h0001; // timeout
        else if (crc_residue == GOOD_CRC)  status_nxt = 16'h0000; // clean
        else                               status_nxt = 16'h0002; // CRC error
    end

    // ----------------------------------------------------------------
    // Output / FIFO write (combinational)
    // ----------------------------------------------------------------
    always @(*) begin
        crc_init   = 1'b0;
        crc_en     = 1'b0;
        fifo_wr_en = 1'b0;
        fifo_din   = 32'd0;
        case (state)
            IDLE: begin
                if (data_valid && data_in == SFD_BYTE) begin
                    crc_init   = 1'b1;
                    fifo_din   = {1'b1, 1'b0, 3'd0, 3'd0, data_in, 16'd0};
                    fifo_wr_en = ~fifo_full;
                end
            end
            DST: if (data_valid) begin
                crc_en=1; fifo_wr_en=~fifo_full;
                fifo_din={1'b0,1'b0,3'd1,3'd0,data_in,16'd0};
            end
            SRC: if (data_valid) begin
                crc_en=1; fifo_wr_en=~fifo_full;
                fifo_din={1'b0,1'b0,3'd2,3'd0,data_in,16'd0};
            end
            LENGTH: if (data_valid) begin
                crc_en=1; fifo_wr_en=~fifo_full;
                fifo_din={1'b0,1'b0,3'd3,3'd0,data_in,16'd0};
            end
            PAYLOAD: if (data_valid) begin
                crc_en=1; fifo_wr_en=~fifo_full;
                fifo_din={1'b0,1'b0,3'd4,3'd0,data_in,16'd0};
            end
            CRC_S: if (data_valid) begin
                crc_en=1; fifo_wr_en=~fifo_full;
                fifo_din={1'b0,1'b0,3'd5,3'd0,data_in,16'd0};
            end
            STATUS_WAIT: begin
                // settle - no FIFO write, no crc_en
            end
            STATUS_WRITE: begin
                fifo_din   = {1'b0, 1'b1, 3'd5, 3'd0, 8'd0, status_nxt};
                fifo_wr_en = ~fifo_full;
            end
            default: begin end
        endcase
    end

    // ----------------------------------------------------------------
    // Sequential
    // ----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= IDLE;
            byte_cnt        <= 4'd0;
            payload_len     <= 16'd0;
            payload_cnt     <= 16'd0;
            timeout_cnt     <= 9'd0;
            error_cause     <= 2'd0;
            status          <= 16'd0;
            length_msb_done <= 1'b0;
        end else begin
            state <= next_state;

            // ---- Sticky error_cause ----
            // Set immediately when error detected in active state.
            // Cleared only on return to IDLE (STATUS_WRITE → IDLE).
            // Priority: bit_error > timeout.
            if (next_state == IDLE)
                error_cause <= 2'd0;
            else if (active && bit_error && error_cause == 2'd0)
                error_cause <= 2'd2;
            else if (active && timeout_hit && error_cause == 2'd0)
                error_cause <= 2'd1;

            // ---- Byte counter ----
            if (next_state != state)
                byte_cnt <= 4'd0;
            else if (data_valid && (state==DST || state==SRC ||
                                    state==LENGTH || state==CRC_S))
                byte_cnt <= byte_cnt + 4'd1;

            // ---- Payload length (IEEE 802.3 big-endian: MSB first) ----
            if (next_state == IDLE) begin
                length_msb_done <= 1'b0;
                payload_len     <= 16'd0;
            end else if (state == LENGTH && data_valid) begin
                if (!length_msb_done) begin
                    payload_len     <= {data_in, 8'd0};
                    length_msb_done <= 1'b1;
                end else
                    payload_len <= {payload_len[15:8], data_in};
            end

            // ---- Payload counter ----
            if (state != PAYLOAD && next_state == PAYLOAD)
                payload_cnt <= 16'd0;
            else if (data_valid && state == PAYLOAD)
                payload_cnt <= payload_cnt + 16'd1;

            // ---- Timeout counter ----
            // Reset in non-active states or when data arrives.
            // NOT reset in STATUS_WAIT/STATUS_WRITE - timeout_cnt may
            // already be >= BYTE_TIMEOUT but error_cause sticky handles that.
            if (!active || data_valid)
                timeout_cnt <= 9'd0;
            else
                timeout_cnt <= timeout_cnt + 9'd1;

            // ---- Status monitor output ----
            if (state == STATUS_WRITE)
                status <= status_nxt;
        end
    end
endmodule