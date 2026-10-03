// Basys3 top level: image over USB-UART, Sobel, and a VGA display of the result.
//
// The UART link works exactly as in sobel_uart_top (the PC script still gets its
// Sobel bytes back and can verify them). In addition both the original image and
// the Sobel result are stored in two 320x240 frame buffers and shown on VGA.
//
//   sw[1:0] = 00 : Sobel result, each pixel doubled to fill 640x480
//             01 : original image, doubled
//             1x : original (left) and Sobel (right) side by side at 1:1
//
// The VGA DAC has only 4 bits per colour, so the buffers hold 4 bits per pixel.
// The original keeps its top 4 bits. Sobel results are mostly small numbers and would
// look nearly black, so they are shown with a gain of 4 (saturating); the bytes sent
// back over UART are not affected by this.
//
// Limits: width <= 320, height <= 240 (frame buffer size).
module sobel_vga_top #(
    parameter int CLKS_PER_BIT = 100,
    parameter int IDLE_TIMEOUT = 25_000_000,
    parameter int FLUSH_CLKS   = 3
)(
    input  logic        clk,
    input  logic        btnC,
    input  logic [1:0]  sw,
    input  logic        RsRx,
    output logic        RsTx,
    output logic [3:0]  vgaRed,
    output logic [3:0]  vgaGreen,
    output logic [3:0]  vgaBlue,
    output logic        Hsync,
    output logic        Vsync,
    output logic [15:0] led
);

    localparam int FB_W   = 320;
    localparam int FB_H   = 240;
    localparam int FB_AW  = 17;                 // 76800 < 2^17

    logic [1:0] rst_sync = 2'b11;
    always_ff @(posedge clk) rst_sync <= {rst_sync[0], btnC};
    logic rst;
    assign rst = rst_sync[1];

    // ------------------------------------------------------------------
    // UART in, frame handling, Sobel
    // ------------------------------------------------------------------
    logic       rx_valid, rx_frame_err;
    logic [7:0] rx_data;

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk), .rst(rst), .rx(RsRx),
        .valid(rx_valid), .data(rx_data), .frame_err(rx_frame_err)
    );

    logic [15:0] width, height;
    logic        frame_rst, s_valid_in, pix_wr, busy;
    logic [7:0]  s_pixel_in;
    logic        err_header, err_rx, frame_toggle;

    frame_rx #(
        .MAX_WIDTH    (FB_W),
        .MAX_HEIGHT   (FB_H),
        .IDLE_TIMEOUT (IDLE_TIMEOUT),
        .FLUSH_CLKS   (FLUSH_CLKS)
    ) u_frame (
        .clk(clk), .rst(rst),
        .rx_valid(rx_valid), .rx_data(rx_data), .rx_frame_err(rx_frame_err),
        .width(width), .height(height),
        .frame_rst(frame_rst), .s_valid_in(s_valid_in), .s_pixel_in(s_pixel_in),
        .pix_wr(pix_wr), .busy(busy),
        .err_header(err_header), .err_rx(err_rx), .frame_toggle(frame_toggle)
    );

    logic       s_valid_out;
    logic [7:0] s_pixel_out;

    sobel #(.WIDTH(FB_W)) u_sobel (
        .clk(clk), .rst(rst | frame_rst),
        .image_width(width),
        .valid_in(s_valid_in), .pixel_in(s_pixel_in),
        .valid_out(s_valid_out), .pixel_out(s_pixel_out)
    );

    // ------------------------------------------------------------------
    // UART out: results through a FIFO to the transmitter
    // ------------------------------------------------------------------
    logic       fifo_empty, fifo_full, fifo_pop, tx_ready;
    logic [7:0] fifo_dout;
    logic       err_fifo = 1'b0;

    always_ff @(posedge clk) begin
        if (rst)                           err_fifo <= 1'b0;
        else if (s_valid_out && fifo_full) err_fifo <= 1'b1;
    end

    fifo_sync #(.WIDTH(8), .DEPTH(64)) u_fifo (
        .clk(clk), .rst(rst),
        .push(s_valid_out), .din(s_pixel_out),
        .pop(fifo_pop), .dout(fifo_dout),
        .empty(fifo_empty), .full(fifo_full)
    );

    assign fifo_pop = !fifo_empty && tx_ready;

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst(rst),
        .in_valid(!fifo_empty), .in_ready(tx_ready),
        .in_data(fifo_dout), .tx(RsTx)
    );

    // ------------------------------------------------------------------
    // Frame buffer writes
    //
    // Addresses are row * 320 + column, kept with running counters so no
    // multiplier is needed. A smaller image simply uses the top-left corner.
    // ------------------------------------------------------------------
    logic [FB_AW-1:0] raw_waddr = '0;
    logic [8:0]       raw_col   = '0;
    logic [FB_AW-1:0] edge_waddr = '0;
    logic [8:0]       edge_col   = '0;

    logic [FB_AW-1:0] raw_row_pad;     // 320 - width: skip to the next buffer row
    logic [FB_AW-1:0] edge_row_skip;   // 323 - width: from last interior column to the next row's column 1
    assign raw_row_pad   = FB_AW'(FB_W) - FB_AW'(width);
    assign edge_row_skip = FB_AW'(FB_W + 3) - FB_AW'(width);

    always_ff @(posedge clk) begin
        if (rst || frame_rst) begin
            raw_waddr  <= '0;
            raw_col    <= '0;
            edge_waddr <= FB_AW'(FB_W + 1);        // row 1, column 1
            edge_col   <= '0;
        end else begin
            if (pix_wr) begin
                if (raw_col == 9'(width - 16'd1)) begin
                    raw_col   <= '0;
                    raw_waddr <= raw_waddr + 1'b1 + raw_row_pad;
                end else begin
                    raw_col   <= raw_col + 1'b1;
                    raw_waddr <= raw_waddr + 1'b1;
                end
            end
            if (s_valid_out) begin
                if (edge_col == 9'(width - 16'd3)) begin
                    edge_col   <= '0;
                    edge_waddr <= edge_waddr + edge_row_skip;
                end else begin
                    edge_col   <= edge_col + 1'b1;
                    edge_waddr <= edge_waddr + 1'b1;
                end
            end
        end
    end

    // 4-bit pixels for the display
    logic [3:0] raw_nib, edge_nib;
    assign raw_nib  = s_pixel_in[7:4];
    assign edge_nib = (s_pixel_out >= 8'd64) ? 4'd15 : s_pixel_out[5:2];   // gain 4, saturating

    logic [FB_AW-1:0] rd_addr;
    logic [3:0]       raw_rd, edge_rd;

    frame_buf #(.DEPTH(FB_W * FB_H), .DW(4)) u_raw (
        .clk(clk), .we(pix_wr), .waddr(raw_waddr), .wdata(raw_nib),
        .raddr(rd_addr), .rdata(raw_rd)
    );

    frame_buf #(.DEPTH(FB_W * FB_H), .DW(4)) u_edge (
        .clk(clk), .we(s_valid_out), .waddr(edge_waddr), .wdata(edge_nib),
        .raddr(rd_addr), .rdata(edge_rd)
    );

    // ------------------------------------------------------------------
    // VGA
    // ------------------------------------------------------------------
    logic       pix_en, hsync, vsync, active, frame_start;
    logic [9:0] x, y;

    vga_timing u_timing (
        .clk(clk), .rst(rst), .pix_en(pix_en),
        .hsync(hsync), .vsync(vsync), .active(active),
        .x(x), .y(y), .frame_start(frame_start)
    );

    // Pipeline, one stage per clock (x and y hold still for 4 clocks, so there is time):
    //   s1: work out which buffer pixel (ix, iy) this screen pixel shows and which buffer
    //   s2: buffer address, and whether the pixel is inside the picture
    //   s3: block RAM data is available
    logic        sbs;                      // side-by-side mode
    assign sbs = sw[1];

    logic [8:0]  s1_ix;
    logic [7:0]  s1_iy;
    logic        s1_edge, s1_act;
    logic        s2_edge, s2_show;
    logic        s3_edge, s3_show;

    always_ff @(posedge clk) begin
        // stage 1
        if (!sbs) begin
            s1_ix   <= x[9:1];
            s1_iy   <= y[8:1];
            s1_edge <= !sw[0];
            s1_act  <= active;
        end else begin
            s1_ix   <= (x >= 10'd320) ? 9'(x - 10'd320) : x[8:0];
            s1_iy   <= 8'(y - 10'd120);
            s1_edge <= (x >= 10'd320);
            s1_act  <= active && (y >= 10'd120) && (y < 10'd360);
        end

        // stage 2
        rd_addr <= (FB_AW'(s1_iy) << 8) + (FB_AW'(s1_iy) << 6) + FB_AW'(s1_ix);
        s2_edge <= s1_edge;
        s2_show <= s1_act && (16'(s1_ix) < width) && (16'(s1_iy) < height) &&
                   (!s1_edge || ((s1_ix != 9'd0) && (16'(s1_ix) != width - 16'd1) &&
                                 (s1_iy != 8'd0) && (16'(s1_iy) != height - 16'd1)));

        // stage 3
        s3_edge <= s2_edge;
        s3_show <= s2_show;
    end

    logic [3:0] pixel4;
    assign pixel4 = !s3_show ? 4'd0 : (s3_edge ? edge_rd : raw_rd);

    always_ff @(posedge clk) begin
        if (pix_en) begin
            {vgaRed, vgaGreen, vgaBlue} <= {pixel4, pixel4, pixel4};
            Hsync <= hsync;
            Vsync <= vsync;
        end
    end

    // ------------------------------------------------------------------
    // LEDs
    // ------------------------------------------------------------------
    logic [26:0] heartbeat = '0;
    always_ff @(posedge clk) heartbeat <= heartbeat + 1'b1;

    assign led = {heartbeat[26], 10'b0, err_fifo, err_rx, err_header, frame_toggle, busy};

endmodule
