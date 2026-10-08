// Turns the camera's pixel stream into what the Sobel core and frame_store expect:
// a clear pulse at the start of each frame, and after the last pixel a few zero pixels
// so the final results are pushed out of the Sobel pipeline (the camera sends nothing
// between frames).
module cam_frame_ctl #(
    parameter int FLUSH_CLKS = 3
)(
    input  logic       clk,
    input  logic       rst,
    input  logic       sof,
    input  logic       pix_valid,
    input  logic [7:0] pix_data,
    input  logic       pix_last,

    output logic       frame_rst,      // one clock: clear the Sobel core and write addresses
    output logic       s_valid_in,
    output logic [7:0] s_pixel_in,
    output logic       pix_wr,         // with s_valid_in for real pixels (not flush zeros)
    output logic       frame_toggle    // flips after every finished frame
);

    localparam int FLUSH_W = $clog2(FLUSH_CLKS + 1);
    logic [FLUSH_W-1:0] flush_left = '0;

    initial begin
        frame_rst    = 1'b0;
        s_valid_in   = 1'b0;
        s_pixel_in   = '0;
        pix_wr       = 1'b0;
        frame_toggle = 1'b0;
    end

    always_ff @(posedge clk) begin
        frame_rst  <= 1'b0;
        s_valid_in <= 1'b0;
        pix_wr     <= 1'b0;

        if (rst) begin
            flush_left   <= '0;
            s_pixel_in   <= '0;
            frame_toggle <= 1'b0;
        end else begin
            if (sof) begin
                frame_rst  <= 1'b1;
                flush_left <= '0;
            end

            if (pix_valid) begin
                s_valid_in <= 1'b1;
                pix_wr     <= 1'b1;
                s_pixel_in <= pix_data;
                if (pix_last) flush_left <= FLUSH_W'(FLUSH_CLKS);
            end else if (flush_left != '0) begin
                s_valid_in <= 1'b1;
                s_pixel_in <= 8'd0;
                flush_left <= flush_left - 1'b1;
                if (flush_left == FLUSH_W'(1)) frame_toggle <= ~frame_toggle;
            end
        end
    end

endmodule
