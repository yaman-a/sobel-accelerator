// Camera -> Sobel -> VGA, with no tri-state pins (those are in sobel_cam_top). This is the
// part that is simulated.
//
// switches: sw[1:0] display mode (see frame_store), sw[2] Y byte phase (down = brightness is the second byte of each pair, which is what
//           this camera sends; up = first byte),
//           sw[3] darker exposure (read at reset), sw[4] camera test pattern (read at reset).
// LEDs: 0 camera configured, 1 a configuration write was NOT acknowledged (camera not
//       answering on SCCB), 2 PCLK seen, 3 HREF seen, 4 VSYNC seen, 5 flips every frame,
//       15 heartbeat.
module sobel_cam_core #(
    parameter int UNIT = 100_000,       // clocks per millisecond (camera start-up waits)
    parameter int DIV  = 500,           // SCCB quarter period in clocks (500 = 50 kHz, slow enough for the weak pull-up)
    parameter int FLUSH_CLKS = 3
)(
    input  logic        clk,            // 100 MHz
    input  logic        btnC,
    input  logic [4:0]  sw,

    // camera
    output logic        cam_xclk,
    output logic        cam_resetn,     // camera reset, active low (released after btnC)
    output logic        cam_pwdn,       // camera power-down, held low (running)
    output logic        cam_scl,
    output logic        sda_o,
    output logic        sda_oe,
    input  logic        sda_i,
    input  logic        cam_pclk,
    input  logic        cam_href,
    input  logic        cam_vsync,
    input  logic [7:0]  cam_d,

    // VGA
    output logic [3:0]  vgaRed,
    output logic [3:0]  vgaGreen,
    output logic [3:0]  vgaBlue,
    output logic        Hsync,
    output logic        Vsync,

    output logic [15:0] led
);

    localparam int W = 320;
    localparam int H = 240;

    logic [1:0] rst_sync = 2'b11;
    always_ff @(posedge clk) rst_sync <= {rst_sync[0], btnC};
    logic rst;
    assign rst = rst_sync[1];

    // 25 MHz camera clock: a flip-flop toggling every second clock (OV7670 accepts 10-48 MHz)
    logic [1:0] xdiv = '0;
    always_ff @(posedge clk) xdiv <= xdiv + 1'b1;
    assign cam_xclk = xdiv[1];

    assign cam_resetn = !rst;
    assign cam_pwdn   = 1'b0;

    // camera configuration
    logic cfg_done, cfg_ack_fail;
    cam_init #(.UNIT(UNIT), .DIV(DIV)) u_init (
        .clk(clk), .rst(rst), .test_pattern(sw[4]), .darker(sw[3]),
        .scl(cam_scl), .sda_o(sda_o), .sda_oe(sda_oe), .sda_i(sda_i),
        .done(cfg_done), .ack_fail(cfg_ack_fail)
    );

    // pixel capture
    logic       sof, pix_valid, pix_last;
    logic [7:0] pix_data;
    logic       seen_pclk, seen_href, seen_vsync;

    cam_capture #(.W(W), .H(H)) u_capture (
        .clk(clk), .rst(rst),
        .cam_pclk(cam_pclk), .cam_href(cam_href), .cam_vsync(cam_vsync), .cam_d(cam_d),
        .phase(!sw[2]),
        .sof(sof), .pix_valid(pix_valid), .pix_data(pix_data), .pix_last(pix_last),
        .seen_pclk(seen_pclk), .seen_href(seen_href), .seen_vsync(seen_vsync)
    );

    logic       frame_rst, s_valid_in, pix_wr, frame_toggle;
    logic [7:0] s_pixel_in;

    cam_frame_ctl #(.FLUSH_CLKS(FLUSH_CLKS)) u_ctl (
        .clk(clk), .rst(rst),
        .sof(sof), .pix_valid(pix_valid), .pix_data(pix_data), .pix_last(pix_last),
        .frame_rst(frame_rst), .s_valid_in(s_valid_in), .s_pixel_in(s_pixel_in),
        .pix_wr(pix_wr), .frame_toggle(frame_toggle)
    );

    // Sobel
    logic       s_valid_out;
    logic [7:0] s_pixel_out;

    sobel #(.WIDTH(W)) u_sobel (
        .clk(clk), .rst(rst | frame_rst),
        .image_width(16'(W)),
        .valid_in(s_valid_in), .pixel_in(s_pixel_in),
        .valid_out(s_valid_out), .pixel_out(s_pixel_out)
    );

    // frame buffers + VGA
    frame_store #(.FB_W(W), .FB_H(H)) u_store (
        .clk(clk), .rst(rst), .new_frame(frame_rst),
        .width(16'(W)), .height(16'(H)),
        .pix_wr(pix_wr), .pix_in(s_pixel_in),
        .res_valid(s_valid_out), .res_pixel(s_pixel_out),
        .sw(sw[1:0]),
        .vgaRed(vgaRed), .vgaGreen(vgaGreen), .vgaBlue(vgaBlue),
        .Hsync(Hsync), .Vsync(Vsync)
    );

    logic [26:0] heartbeat = '0;
    always_ff @(posedge clk) heartbeat <= heartbeat + 1'b1;

    assign led = {heartbeat[26], 9'b0, frame_toggle, seen_vsync, seen_href, seen_pclk,
                  cfg_ack_fail, cfg_done};

    logic unused;
    assign unused = 1'b0;

endmodule
