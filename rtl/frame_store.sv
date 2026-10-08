// Frame buffers and VGA display, shared by the UART and camera designs.
//
// Inputs are the original pixel stream (pix_wr, pix_in) and the Sobel results
// (res_valid, res_pixel). Both are stored as 4-bit pixels in two 320x240 buffers and
// shown on VGA. new_frame (one clock) restarts the write addresses.
//
//   sw[1:0] = 00 : Sobel result, each pixel doubled to fill 640x480
//             01 : original image, doubled
//             1x : original (left) and Sobel (right) side by side at 1:1
//
// The VGA DAC has 4 bits per colour, hence 4-bit buffers. The original keeps its top
// 4 bits. Sobel results are mostly small, so they are shown with a gain of 4 (saturating).
// The part of the buffers outside width x height, and the one-pixel border of the Sobel
// result (which has no full 3x3 window), is shown black.
module frame_store #(
    parameter int FB_W = 320,
    parameter int FB_H = 240
)(
    input  logic        clk,
    input  logic        rst,
    input  logic        new_frame,
    input  logic [15:0] width,
    input  logic [15:0] height,
    input  logic        pix_wr,
    input  logic [7:0]  pix_in,
    input  logic        res_valid,
    input  logic [7:0]  res_pixel,
    input  logic [1:0]  sw,

    output logic [3:0]  vgaRed,
    output logic [3:0]  vgaGreen,
    output logic [3:0]  vgaBlue,
    output logic        Hsync,
    output logic        Vsync
);

    localparam int FB_AW = 17;                  // 76800 < 2^17

    // ------------------------------------------------------------------
    // Writes. Address = row * 320 + column, kept with running counters so no
    // multiplier is needed. A smaller image uses the top-left corner.
    // ------------------------------------------------------------------
    logic [FB_AW-1:0] raw_waddr  = '0;
    logic [8:0]       raw_col    = '0;
    logic [FB_AW-1:0] edge_waddr = '0;
    logic [8:0]       edge_col   = '0;

    logic [FB_AW-1:0] raw_row_pad;     // 320 - width: skip to the next buffer row
    logic [FB_AW-1:0] edge_row_skip;   // 323 - width: last interior column -> next row, column 1
    assign raw_row_pad   = FB_AW'(FB_W) - FB_AW'(width);
    assign edge_row_skip = FB_AW'(FB_W + 3) - FB_AW'(width);

    always_ff @(posedge clk) begin
        if (rst || new_frame) begin
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
            if (res_valid) begin
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

    logic [3:0] raw_nib, edge_nib;
    assign raw_nib  = pix_in[7:4];
    assign edge_nib = (res_pixel >= 8'd64) ? 4'd15 : res_pixel[5:2];   // gain 4, saturating

    logic [FB_AW-1:0] rd_addr;
    logic [3:0]       raw_rd, edge_rd;

    frame_buf #(.DEPTH(FB_W * FB_H), .DW(4)) u_raw (
        .clk(clk), .we(pix_wr), .waddr(raw_waddr), .wdata(raw_nib),
        .raddr(rd_addr), .rdata(raw_rd)
    );

    frame_buf #(.DEPTH(FB_W * FB_H), .DW(4)) u_edge (
        .clk(clk), .we(res_valid), .waddr(edge_waddr), .wdata(edge_nib),
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
    //   s1: which buffer pixel (ix, iy) this screen pixel shows, and which buffer
    //   s2: buffer address, and whether the pixel is inside the picture
    //   s3: block RAM data is available
    logic        sbs;
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

    logic unused;
    assign unused = &{1'b0, frame_start};

endmodule
