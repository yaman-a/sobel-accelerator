// UART transmitter: 8 data bits, no parity, 1 stop bit, least significant bit first.
//
// Ready/valid input. A byte is accepted when in_valid and in_ready are both high.
// in_ready is also high during the last clock of the stop bit, so a new byte can
// follow the previous one with no idle time on the line (full line rate).
module uart_tx #(
    parameter int CLKS_PER_BIT = 100   // clock frequency / baud rate, at least 4
)(
    input  logic       clk,
    input  logic       rst,
    input  logic       in_valid,
    output logic       in_ready,
    input  logic [7:0] in_data,
    output logic       tx
);

    localparam int CNT_W = $clog2(CLKS_PER_BIT);
    localparam logic [CNT_W-1:0] CNT_LAST = CNT_W'(CLKS_PER_BIT - 1);

    typedef enum logic [1:0] {T_IDLE, T_START, T_DATA, T_STOP} state_t;
    state_t           state   = T_IDLE;
    logic [CNT_W-1:0] cnt     = '0;
    logic [2:0]       bit_idx = '0;
    logic [7:0]       shreg   = '0;

    assign in_ready = (state == T_IDLE) || ((state == T_STOP) && (cnt == CNT_LAST));

    always_ff @(posedge clk) begin
        if (rst) begin
            state   <= T_IDLE;
            tx      <= 1'b1;
            cnt     <= '0;
            bit_idx <= '0;
            shreg   <= '0;
        end else begin
            case (state)
                T_IDLE: begin
                    tx <= 1'b1;
                    if (in_valid) begin
                        shreg <= in_data;
                        tx    <= 1'b0;            // start bit
                        cnt   <= '0;
                        state <= T_START;
                    end
                end

                T_START: begin
                    if (cnt == CNT_LAST) begin
                        cnt     <= '0;
                        tx      <= shreg[0];      // data bit 0
                        shreg   <= {1'b0, shreg[7:1]};
                        bit_idx <= '0;
                        state   <= T_DATA;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                T_DATA: begin
                    if (cnt == CNT_LAST) begin
                        cnt <= '0;
                        if (bit_idx == 3'd7) begin
                            tx    <= 1'b1;        // stop bit
                            state <= T_STOP;
                        end else begin
                            tx      <= shreg[0];
                            shreg   <= {1'b0, shreg[7:1]};
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                T_STOP: begin
                    if (cnt == CNT_LAST) begin
                        cnt <= '0;
                        if (in_valid) begin       // next byte follows with no gap
                            shreg <= in_data;
                            tx    <= 1'b0;
                            state <= T_START;
                        end else begin
                            state <= T_IDLE;
                        end
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                default: state <= T_IDLE;
            endcase
        end
    end

endmodule
