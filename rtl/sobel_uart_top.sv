// Basys3 top level: Sobel edge detection on an image sent over the USB-UART.
//
// Protocol (8N1 serial, default 1 Mbaud):
//   PC -> FPGA   width (2 bytes, big endian), height (2 bytes, big endian),
//                then width*height greyscale pixels, row by row.
//   FPGA -> PC   the (width-2)*(height-2) Sobel results for the interior pixels,
//                row by row. The one-pixel border has no full 3x3 window and is
//                not sent; the PC pads it with zeros.
//
// Limits: 3 <= width <= MAX_WIDTH, height >= 3. A frame with a bad header is
// ignored until the line has been idle for IDLE_TIMEOUT clocks.
//
// LEDs: 0 frame in progress, 1 toggles after every finished frame,
//       2 bad header seen, 3 UART framing error seen, 4 output FIFO overflowed,
//       15 heartbeat. LEDs 2 to 4 are sticky until the reset button (btnC).
module sobel_uart_top #(
    parameter int CLKS_PER_BIT = 100,         // 100 MHz / 1 Mbaud
    parameter int MAX_WIDTH    = 640,         // line buffer depth
    parameter int IDLE_TIMEOUT = 25_000_000,  // clocks without a byte before resync (250 ms)
    parameter int FLUSH_CLKS   = 3            // clocks needed to push the last results out
)(
    input  logic        clk,                  // 100 MHz
    input  logic        btnC,                 // reset, active high
    input  logic        RsRx,                 // from the USB-UART bridge
    output logic        RsTx,                 // to the USB-UART bridge
    output logic [15:0] led
);

    // ------------------------------------------------------------------
    // Reset: synchronised button, also asserted at power-up
    // ------------------------------------------------------------------
    logic [1:0] rst_sync = 2'b11;
    always_ff @(posedge clk) rst_sync <= {rst_sync[0], btnC};
    logic rst;
    assign rst = rst_sync[1];

    // ------------------------------------------------------------------
    // UART receiver
    // ------------------------------------------------------------------
    logic       rx_valid;
    logic [7:0] rx_data;
    logic       rx_frame_err;

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk       (clk),
        .rst       (rst),
        .rx        (RsRx),
        .valid     (rx_valid),
        .data      (rx_data),
        .frame_err (rx_frame_err)
    );

    // ------------------------------------------------------------------
    // Frame handling
    // ------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_W_HI, S_W_LO, S_H_HI, S_H_LO, S_PIX, S_FLUSH, S_DISCARD
    } state_t;
    state_t state = S_W_HI;

    localparam int IDLE_W  = $clog2(IDLE_TIMEOUT + 1);
    localparam int FLUSH_W = $clog2(FLUSH_CLKS + 1);

    logic [15:0]        width      = '0;
    logic [15:0]        height     = '0;
    logic [15:0]        px_col     = '0;
    logic [15:0]        px_row     = '0;
    logic [FLUSH_W-1:0] flush_left = '0;
    logic [IDLE_W-1:0]  idle_cnt   = '0;

    logic               frame_rst  = 1'b0;   // one-cycle pulse: clear the Sobel pipeline
    logic               s_valid_in = 1'b0;
    logic [7:0]         s_pixel_in = '0;

    logic err_header   = 1'b0;
    logic err_rx       = 1'b0;
    logic err_fifo     = 1'b0;
    logic frame_toggle = 1'b0;

    logic        s_valid_out;
    logic [7:0]  s_pixel_out;
    logic        fifo_full;

    always_ff @(posedge clk) begin
        frame_rst  <= 1'b0;
        s_valid_in <= 1'b0;

        if (rst) begin
            state        <= S_W_HI;
            width        <= '0;
            height       <= '0;
            px_col       <= '0;
            px_row       <= '0;
            flush_left   <= '0;
            idle_cnt     <= '0;
            s_pixel_in   <= '0;
            err_header   <= 1'b0;
            err_rx       <= 1'b0;
            err_fifo     <= 1'b0;
            frame_toggle <= 1'b0;
        end else begin
            if (rx_frame_err)              err_rx   <= 1'b1;
            if (s_valid_out && fifo_full)  err_fifo <= 1'b1;

            // Idle timeout: abandon a stalled frame, or resynchronise after a bad header.
            if (rx_valid) begin
                idle_cnt <= '0;
            end else if (idle_cnt != IDLE_W'(IDLE_TIMEOUT)) begin
                idle_cnt <= idle_cnt + 1'b1;
            end else if (state != S_FLUSH) begin
                state <= S_W_HI;
            end

            // Push zeros through so the last results leave the pipeline.
            if (state == S_FLUSH) begin
                s_valid_in <= 1'b1;
                s_pixel_in <= 8'd0;
                flush_left <= flush_left - 1'b1;
                if (flush_left == FLUSH_W'(1)) begin
                    state        <= S_W_HI;
                    frame_toggle <= ~frame_toggle;
                end
            end

            if (rx_valid) begin
                case (state)
                    S_W_HI: begin
                        width[15:8] <= rx_data;
                        state       <= S_W_LO;
                    end

                    S_W_LO: begin
                        width[7:0] <= rx_data;
                        state      <= S_H_HI;
                    end

                    S_H_HI: begin
                        height[15:8] <= rx_data;
                        state        <= S_H_LO;
                    end

                    S_H_LO: begin
                        height[7:0] <= rx_data;
                        if (width >= 16'd3 && width <= 16'(MAX_WIDTH) &&
                            ({height[15:8], rx_data} >= 16'd3)) begin
                            px_col    <= '0;
                            px_row    <= '0;
                            frame_rst <= 1'b1;
                            state     <= S_PIX;
                        end else begin
                            err_header <= 1'b1;
                            state      <= S_DISCARD;
                        end
                    end

                    S_PIX: begin
                        s_valid_in <= 1'b1;
                        s_pixel_in <= rx_data;
                        if (px_col == width - 16'd1) begin
                            px_col <= '0;
                            if (px_row == height - 16'd1) begin
                                state      <= S_FLUSH;
                                flush_left <= FLUSH_W'(FLUSH_CLKS);
                            end else begin
                                px_row <= px_row + 1'b1;
                            end
                        end else begin
                            px_col <= px_col + 1'b1;
                        end
                    end

                    default: ;   // S_FLUSH, S_DISCARD: ignore the byte
                endcase
            end
        end
    end

    // ------------------------------------------------------------------
    // Sobel core
    // ------------------------------------------------------------------
    sobel #(.WIDTH(MAX_WIDTH)) u_sobel (
        .clk         (clk),
        .rst         (rst | frame_rst),
        .image_width (width),
        .valid_in    (s_valid_in),
        .pixel_in    (s_pixel_in),
        .valid_out   (s_valid_out),
        .pixel_out   (s_pixel_out)
    );

    // ------------------------------------------------------------------
    // Results: FIFO, then UART transmitter
    // ------------------------------------------------------------------
    logic       fifo_empty;
    logic [7:0] fifo_dout;
    logic       fifo_pop;
    logic       tx_ready;

    fifo_sync #(.WIDTH(8), .DEPTH(64)) u_fifo (
        .clk   (clk),
        .rst   (rst),
        .push  (s_valid_out),
        .din   (s_pixel_out),
        .pop   (fifo_pop),
        .dout  (fifo_dout),
        .empty (fifo_empty),
        .full  (fifo_full)
    );

    assign fifo_pop = !fifo_empty && tx_ready;

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk      (clk),
        .rst      (rst),
        .in_valid (!fifo_empty),
        .in_ready (tx_ready),
        .in_data  (fifo_dout),
        .tx       (RsTx)
    );

    // ------------------------------------------------------------------
    // LEDs
    // ------------------------------------------------------------------
    logic [26:0] heartbeat = '0;
    always_ff @(posedge clk) heartbeat <= heartbeat + 1'b1;

    assign led = {heartbeat[26], 10'b0, err_fifo, err_rx, err_header,
                  frame_toggle, (state != S_W_HI)};

endmodule
