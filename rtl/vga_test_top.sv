// Basys3 VGA test pattern: proves the monitor / VGA-to-HDMI converter chain works
// before any image data is involved.
//
//   top two thirds : 8 colour bars (white, yellow, cyan, green, magenta, red, blue, black)
//   bottom third   : 16-step grey ramp
//   1-pixel white frame round the edge, to see whether the display crops anything
//
// The Basys3 DAC is 4 bits per colour. Colour and sync outputs are registered together
// so they change on the same clock edge.
module vga_test_top (
    input  logic        clk,        // 100 MHz
    input  logic        btnC,       // reset
    output logic [3:0]  vgaRed,
    output logic [3:0]  vgaGreen,
    output logic [3:0]  vgaBlue,
    output logic        Hsync,
    output logic        Vsync,
    output logic [15:0] led
);

    logic [1:0] rst_sync = 2'b11;
    always_ff @(posedge clk) rst_sync <= {rst_sync[0], btnC};
    logic rst;
    assign rst = rst_sync[1];

    logic       pix_en, hsync, vsync, active, frame_start;
    logic [9:0] x, y;

    vga_timing u_timing (
        .clk(clk), .rst(rst), .pix_en(pix_en),
        .hsync(hsync), .vsync(vsync), .active(active),
        .x(x), .y(y), .frame_start(frame_start)
    );

    logic [11:0] rgb;     // {r, g, b}
    logic [3:0]  grey;

    // bar number 0..7 for x in 0..639 (80 pixels per bar)
    function automatic logic [2:0] bar_index(input logic [9:0] xx);
        if      (xx < 10'd80)  return 3'd0;
        else if (xx < 10'd160) return 3'd1;
        else if (xx < 10'd240) return 3'd2;
        else if (xx < 10'd320) return 3'd3;
        else if (xx < 10'd400) return 3'd4;
        else if (xx < 10'd480) return 3'd5;
        else if (xx < 10'd560) return 3'd6;
        else                   return 3'd7;
    endfunction

    assign grey = 4'(x / 10'd40);          // 16 steps of 40 pixels

    always_comb begin
        rgb = 12'h000;
        if (active) begin
            if (x == 10'd0 || x == 10'd639 || y == 10'd0 || y == 10'd479) begin
                rgb = 12'hFFF;                         // white frame
            end else if (y < 10'd320) begin
                case (bar_index(x))
                    3'd0:    rgb = 12'hFFF;
                    3'd1:    rgb = 12'hFF0;
                    3'd2:    rgb = 12'h0FF;
                    3'd3:    rgb = 12'h0F0;
                    3'd4:    rgb = 12'hF0F;
                    3'd5:    rgb = 12'hF00;
                    3'd6:    rgb = 12'h00F;
                    default: rgb = 12'h000;
                endcase
            end else begin
                rgb = {grey, grey, grey};
            end
        end
    end

    // register everything together on the pixel enable
    always_ff @(posedge clk) begin
        if (pix_en) begin
            {vgaRed, vgaGreen, vgaBlue} <= rgb;
            Hsync <= hsync;
            Vsync <= vsync;
        end
    end

    logic [26:0] heartbeat = '0;
    always_ff @(posedge clk) heartbeat <= heartbeat + 1'b1;
    assign led = {heartbeat[26], 15'b0};

endmodule
