// Frame receiver: turns the byte stream from uart_rx into a Sobel input stream.
//
// Protocol: width (2 bytes, big endian), height (2 bytes), then width*height pixels.
// A header is accepted when 3 <= width <= MAX_WIDTH and 3 <= height <= MAX_HEIGHT;
// otherwise the rest of the frame is ignored until the line has been idle for
// IDLE_TIMEOUT clocks.
//
// Outputs s_valid_in / s_pixel_in feed the Sobel core: the real pixels, then
// FLUSH_CLKS zeros to push the last results out of the pipeline. pix_wr is high
// together with s_valid_in for real pixels only (not the flush zeros).
// frame_rst is a one-clock pulse that clears the Sobel core when a header is accepted.
module frame_rx #(
    parameter int MAX_WIDTH    = 640,
    parameter int MAX_HEIGHT   = 65535,
    parameter int IDLE_TIMEOUT = 25_000_000,
    parameter int FLUSH_CLKS   = 3
)(
    input  logic        clk,
    input  logic        rst,
    input  logic        rx_valid,
    input  logic [7:0]  rx_data,
    input  logic        rx_frame_err,

    output logic [15:0] width,
    output logic [15:0] height,
    output logic        frame_rst,
    output logic        s_valid_in,
    output logic [7:0]  s_pixel_in,
    output logic        pix_wr,
    output logic        busy,           // a frame is being received or flushed
    output logic        err_header,     // sticky until rst
    output logic        err_rx,         // sticky until rst
    output logic        frame_toggle    // flips after every finished frame
);

    typedef enum logic [2:0] {
        S_W_HI, S_W_LO, S_H_HI, S_H_LO, S_PIX, S_FLUSH, S_DISCARD
    } state_t;
    state_t state = S_W_HI;

    localparam int IDLE_W  = $clog2(IDLE_TIMEOUT + 1);
    localparam int FLUSH_W = $clog2(FLUSH_CLKS + 1);

    logic [15:0]        px_col     = '0;
    logic [15:0]        px_row     = '0;
    logic [FLUSH_W-1:0] flush_left = '0;
    logic [IDLE_W-1:0]  idle_cnt   = '0;

    initial begin
        width        = '0;
        height       = '0;
        frame_rst    = 1'b0;
        s_valid_in   = 1'b0;
        s_pixel_in   = '0;
        pix_wr       = 1'b0;
        err_header   = 1'b0;
        err_rx       = 1'b0;
        frame_toggle = 1'b0;
    end

    assign busy = (state != S_W_HI);

    always_ff @(posedge clk) begin
        frame_rst  <= 1'b0;
        s_valid_in <= 1'b0;
        pix_wr     <= 1'b0;

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
            frame_toggle <= 1'b0;
        end else begin
            if (rx_frame_err) err_rx <= 1'b1;

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
                        /* verilator lint_off CMPCONST */
                        if (width >= 16'd3 && width <= 16'(MAX_WIDTH) &&
                            {height[15:8], rx_data} >= 16'd3 &&
                            {height[15:8], rx_data} <= 16'(MAX_HEIGHT)) begin
                            /* verilator lint_on CMPCONST */
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
                        pix_wr     <= 1'b1;
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

endmodule
