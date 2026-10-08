// Captures the OV7670's parallel output (YUV422, 640 bytes per line) and picks out the
// brightness (Y) byte of every pixel, giving a 320x240 greyscale pixel stream.
//
// The camera's pixel clock is NOT used as a clock here. All camera signals go through
// two flip-flops on the 100 MHz system clock, and a rising edge of PCLK is detected from
// the synchronised copy; the data bus went through the same two flip-flops, so it was
// sampled at the same moment as PCLK. That is safe because the data is stable for half a
// PCLK period (40 ns or more) around the rising edge, and it keeps the whole design in
// one clock domain.
//
// Camera signals: VSYNC is high during the gap between frames, HREF is high while a line's
// bytes are being sent.
//
// phase = 0: bytes 0, 2, 4 ... of each line are Y (YUYV order, what cam_init selects)
// phase = 1: bytes 1, 3, 5 ... are Y (UYVY order); a switch for bring-up in case the
//            picture comes out as colour noise.
module cam_capture #(
    parameter int W = 320,
    parameter int H = 240
)(
    input  logic       clk,
    input  logic       rst,

    input  logic       cam_pclk,
    input  logic       cam_href,
    input  logic       cam_vsync,
    input  logic [7:0] cam_d,
    input  logic       phase,

    output logic       sof,          // one clock: a new frame starts (before its pixels)
    output logic       pix_valid,    // one clock per pixel
    output logic [7:0] pix_data,
    output logic       pix_last,     // with pix_valid: the last pixel of the frame

    output logic       seen_pclk,    // sticky activity flags, cleared by rst
    output logic       seen_href,
    output logic       seen_vsync
);

    // two-flop synchronisers, all signals together
    logic       p1, p2, p3;
    logic       h1, h2, h3;
    logic       v1, v2, v3;
    logic [7:0] d1, d2;

    always_ff @(posedge clk) begin
        {p1, h1, v1, d1} <= {cam_pclk, cam_href, cam_vsync, cam_d};
        {p2, h2, v2, d2} <= {p1, h1, v1, d1};
        {p3, h3, v3}     <= {p2, h2, v2};
    end

    logic pclk_rise, href_fall, vsync_rise;
    assign pclk_rise  = p2 && !p3;
    assign href_fall  = !h2 && h3;
    assign vsync_rise = v2 && !v3;

    logic        in_frame  = 1'b0;
    logic        byte_odd  = 1'b0;           // 0 for even byte positions in the line
    logic [8:0]  col       = '0;             // pixels emitted so far in this line
    logic [8:0]  row       = '0;             // lines completed in this frame
    logic        line_got  = 1'b0;           // this line produced at least one byte

    initial begin
        sof        = 1'b0;
        pix_valid  = 1'b0;
        pix_data   = '0;
        pix_last   = 1'b0;
        seen_pclk  = 1'b0;
        seen_href  = 1'b0;
        seen_vsync = 1'b0;
    end

    always_ff @(posedge clk) begin
        sof       <= 1'b0;
        pix_valid <= 1'b0;
        pix_last  <= 1'b0;

        if (rst) begin
            in_frame   <= 1'b0;
            byte_odd   <= 1'b0;
            col        <= '0;
            row        <= '0;
            line_got   <= 1'b0;
            seen_pclk  <= 1'b0;
            seen_href  <= 1'b0;
            seen_vsync <= 1'b0;
        end else begin
            if (pclk_rise) seen_pclk  <= 1'b1;
            if (h2)        seen_href  <= 1'b1;
            if (vsync_rise) seen_vsync <= 1'b1;

            // a new frame begins when VSYNC goes high
            if (vsync_rise) begin
                in_frame <= 1'b1;
                sof      <= 1'b1;
                row      <= '0;
                col      <= '0;
                byte_odd <= 1'b0;
                line_got <= 1'b0;
            end

            // end of a line: count it and get ready for the next
            if (href_fall) begin
                if (line_got && row != 9'(H)) row <= row + 1'b1;
                col      <= '0;
                byte_odd <= 1'b0;
                line_got <= 1'b0;
            end

            if (pclk_rise && h2 && !v2 && in_frame && row < 9'(H)) begin
                line_got <= 1'b1;
                byte_odd <= !byte_odd;
                if (byte_odd == phase && col < 9'(W)) begin
                    pix_valid <= 1'b1;
                    pix_data  <= d2;
                    col       <= col + 1'b1;
                    if (col == 9'(W - 1) && row == 9'(H - 1)) pix_last <= 1'b1;
                end
            end
        end
    end

    logic unused;
    assign unused = &{1'b0, h3, v3};

endmodule
