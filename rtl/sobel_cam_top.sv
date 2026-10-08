// Basys3 top level for the live camera design: adds the tri-state SDA pin to
// sobel_cam_core. See that file for switches and LEDs.
module sobel_cam_top (
    input  logic        clk,
    input  logic        btnC,
    input  logic [4:0]  sw,

    output logic        cam_xclk,
    output logic        cam_resetn,
    output logic        cam_pwdn,
    output logic        cam_scl,
    inout  wire         cam_sda,
    input  logic        cam_pclk,
    input  logic        cam_href,
    input  logic        cam_vsync,
    input  logic [7:0]  cam_d,

    output logic [3:0]  vgaRed,
    output logic [3:0]  vgaGreen,
    output logic [3:0]  vgaBlue,
    output logic        Hsync,
    output logic        Vsync,

    output logic [15:0] led
);

    logic sda_o, sda_oe;

    assign cam_sda = sda_oe ? sda_o : 1'bz;

    sobel_cam_core u_core (
        .clk(clk), .btnC(btnC), .sw(sw),
        .cam_xclk(cam_xclk), .cam_resetn(cam_resetn), .cam_pwdn(cam_pwdn), .cam_scl(cam_scl),
        .sda_o(sda_o), .sda_oe(sda_oe), .sda_i(cam_sda),
        .cam_pclk(cam_pclk), .cam_href(cam_href), .cam_vsync(cam_vsync), .cam_d(cam_d),
        .vgaRed(vgaRed), .vgaGreen(vgaGreen), .vgaBlue(vgaBlue),
        .Hsync(Hsync), .Vsync(Vsync),
        .led(led)
    );

endmodule
