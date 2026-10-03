// UART receiver: 8 data bits, no parity, 1 stop bit, least significant bit first.
//
// The line is sampled in the middle of each bit. After the stop bit has been
// sampled the receiver is immediately ready for the next start bit, so
// back-to-back bytes (no idle time between them) are received correctly.
module uart_rx #(
    parameter int CLKS_PER_BIT = 100   // clock frequency / baud rate, at least 4
)(
    input  logic       clk,
    input  logic       rst,
    input  logic       rx,             // serial input, asynchronous to clk
    output logic       valid,          // one-cycle pulse: a byte has been received
    output logic [7:0] data,           // the received byte (holds its value after valid)
    output logic       frame_err       // one-cycle pulse: the stop bit was not high
);

    localparam int CNT_W = $clog2(CLKS_PER_BIT);
    localparam logic [CNT_W-1:0] CNT_LAST = CNT_W'(CLKS_PER_BIT - 1);
    localparam logic [CNT_W-1:0] CNT_MID  = CNT_W'(CLKS_PER_BIT / 2 - 1);

    // Two flip-flops bring the asynchronous input into the clk domain.
    logic rx_meta = 1'b1;
    logic rx_sync = 1'b1;
    always_ff @(posedge clk) begin
        rx_meta <= rx;
        rx_sync <= rx_meta;
    end

    typedef enum logic [1:0] {R_IDLE, R_START, R_DATA, R_STOP} state_t;
    state_t           state   = R_IDLE;
    logic [CNT_W-1:0] cnt     = '0;
    logic [2:0]       bit_idx = '0;
    logic [7:0]       shreg   = '0;

    always_ff @(posedge clk) begin
        valid     <= 1'b0;
        frame_err <= 1'b0;

        if (rst) begin
            state   <= R_IDLE;
            cnt     <= '0;
            bit_idx <= '0;
        end else begin
            case (state)
                R_IDLE: begin
                    // falling edge of the start bit
                    if (!rx_sync) begin
                        cnt   <= '0;
                        state <= R_START;
                    end
                end

                R_START: begin
                    // check the start bit is still low in its middle (rejects glitches)
                    if (cnt == CNT_MID) begin
                        cnt <= '0;
                        if (!rx_sync) begin
                            bit_idx <= '0;
                            state   <= R_DATA;
                        end else begin
                            state <= R_IDLE;
                        end
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                R_DATA: begin
                    // one full bit after the previous sample point: the middle of the next bit
                    if (cnt == CNT_LAST) begin
                        cnt   <= '0;
                        shreg <= {rx_sync, shreg[7:1]};   // LSB arrives first
                        if (bit_idx == 3'd7) state <= R_STOP;
                        else                 bit_idx <= bit_idx + 1'b1;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                R_STOP: begin
                    if (cnt == CNT_LAST) begin
                        cnt   <= '0;
                        state <= R_IDLE;
                        if (rx_sync) begin
                            data  <= shreg;
                            valid <= 1'b1;
                        end else begin
                            frame_err <= 1'b1;
                        end
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                default: state <= R_IDLE;
            endcase
        end
    end

endmodule
