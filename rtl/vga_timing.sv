// VGA 640x480 timing generator.
//
// Runs on the 100 MHz system clock with a pixel enable every 4th clock, which gives
// a 25 MHz pixel rate (the standard is 25.175 MHz, monitors accept the 0.7% difference;
// the frame rate comes out at 59.5 Hz). Using an enable rather than a divided clock
// keeps everything in one clock domain.
//
// Line:  640 visible + 16 front porch + 96 sync + 48 back porch = 800 pixels
// Frame: 480 visible + 10 front porch +  2 sync + 33 back porch = 525 lines
// Both sync pulses are active low.
module vga_timing (
    input  logic       clk,
    input  logic       rst,
    output logic       pix_en,      // high for one clock in every four
    output logic       hsync,
    output logic       vsync,
    output logic       active,      // inside the 640x480 visible area
    output logic [9:0] x,           // pixel position (valid while active)
    output logic [9:0] y,
    output logic       frame_start  // one pix_en-wide pulse at x=0, y=0
);

    localparam int H_VIS = 640, H_FP = 16, H_SYNC = 96, H_BP = 48;
    localparam int V_VIS = 480, V_FP = 10, V_SYNC = 2,  V_BP = 33;
    localparam int H_TOTAL = H_VIS + H_FP + H_SYNC + H_BP;   // 800
    localparam int V_TOTAL = V_VIS + V_FP + V_SYNC + V_BP;   // 525

    logic [1:0] div = '0;
    logic [9:0] hc  = '0;   // 0 .. 799
    logic [9:0] vc  = '0;   // 0 .. 524

    assign pix_en = (div == 2'd3);

    always_ff @(posedge clk) begin
        if (rst) begin
            div <= '0;
            hc  <= '0;
            vc  <= '0;
        end else begin
            div <= div + 1'b1;
            if (pix_en) begin
                if (hc == 10'(H_TOTAL - 1)) begin
                    hc <= '0;
                    vc <= (vc == 10'(V_TOTAL - 1)) ? 10'd0 : vc + 1'b1;
                end else begin
                    hc <= hc + 1'b1;
                end
            end
        end
    end

    assign active      = (hc < 10'(H_VIS)) && (vc < 10'(V_VIS));
    assign x           = hc;
    assign y           = vc;
    assign hsync       = ~((hc >= 10'(H_VIS + H_FP)) && (hc < 10'(H_VIS + H_FP + H_SYNC)));
    assign vsync       = ~((vc >= 10'(V_VIS + V_FP)) && (vc < 10'(V_VIS + V_FP + V_SYNC)));
    assign frame_start = (hc == 10'd0) && (vc == 10'd0);

endmodule
