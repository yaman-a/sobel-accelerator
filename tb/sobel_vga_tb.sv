// End-to-end test of sobel_vga_top: an image goes in over the (bit-level) UART, and the
// VGA output is captured pixel by pixel and compared with what it should show in each of
// the three display modes. The UART reply is checked too.
module sobel_vga_tb;

    localparam int CPB = 8;
    localparam int MAXW = 100;      // storage for the test images
    localparam int MAXH = 60;
    int IW = 100;                   // size of the image currently loaded
    int IH = 60;

    logic        clk = 1'b0;
    logic        btnC = 1'b1;
    logic [1:0]  sw = 2'b00;
    logic        RsRx = 1'b1;
    logic        RsTx;
    logic [3:0]  vgaRed, vgaGreen, vgaBlue;
    logic        Hsync, Vsync;
    logic [15:0] led;

    sobel_vga_top #(.CLKS_PER_BIT(CPB), .IDLE_TIMEOUT(5000)) dut (.*);
    always #5 clk = ~clk;

    // ---- test image: gradient, a bright box, some noise ----
    logic [7:0] img [MAXH][MAXW];
    function automatic int px(input int y, input int x);
        return int'(img[y][x]);
    endfunction
    function automatic int sobel_ref(input int y, input int x);
        int gx, gy, m;
        gx = (px(y-1,x+1) + 2*px(y,x+1) + px(y+1,x+1)) - (px(y-1,x-1) + 2*px(y,x-1) + px(y+1,x-1));
        gy = (px(y+1,x-1) + 2*px(y+1,x) + px(y+1,x+1)) - (px(y-1,x-1) + 2*px(y-1,x) + px(y-1,x+1));
        m = ((gx < 0) ? -gx : gx) + ((gy < 0) ? -gy : gy);
        return (m > 255) ? 255 : m;
    endfunction
    function automatic logic [3:0] edge4(input int y, input int x);
        int v;
        v = sobel_ref(y, x);
        return (v >= 64) ? 4'd15 : 4'(v >> 2);
    endfunction

    // ---- UART driver and monitor ----
    task automatic send_byte(input logic [7:0] b);
        RsRx = 1'b0; repeat (CPB) @(posedge clk);
        for (int i = 0; i < 8; i++) begin RsRx = b[i]; repeat (CPB) @(posedge clk); end
        RsRx = 1'b1; repeat (CPB) @(posedge clk);
    endtask

    logic [7:0] rx_q [$];
    initial forever begin
        logic [7:0] b;
        @(negedge RsTx);
        repeat (CPB / 2) @(posedge clk);
        for (int i = 0; i < 8; i++) begin repeat (CPB) @(posedge clk); b[i] = RsTx; end
        repeat (CPB) @(posedge clk);
        rx_q.push_back(b);
    end

    // ---- VGA capture: pins show the previous pixel, so keep delayed coordinates ----
    logic [3:0] cap [480][640];
    logic [9:0] xd, yd;
    logic       actd;
    always @(posedge clk) if (dut.pix_en) begin
        if (actd) cap[yd][xd] <= vgaRed;
        xd <= dut.x; yd <= dut.y; actd <= dut.active;
    end

    // also check the three colour channels always agree (grey output)
    int chan_errs = 0;
    always @(posedge clk) if (vgaRed !== vgaGreen || vgaRed !== vgaBlue) chan_errs++;

    // ---- expected frame for a display mode ----
    function automatic logic [3:0] expect_px(input logic [1:0] mode, input int x, input int y);
        int ix, iy;
        logic use_edge;
        if (mode[1]) begin
            if (y < 120 || y >= 360) return 4'd0;
            iy = y - 120;
            use_edge = (x >= 320);
            ix = use_edge ? x - 320 : x;
        end else begin
            ix = x / 2;
            iy = y / 2;
            use_edge = !mode[0];
        end
        if (ix >= IW || iy >= IH) return 4'd0;
        if (use_edge) begin
            if (ix < 1 || ix > IW - 2 || iy < 1 || iy > IH - 2) return 4'd0;
            return edge4(iy, ix);
        end
        return img[iy][ix][7:4];
    endfunction

    int errs = 0;

    task automatic check_mode(input logic [1:0] mode, input string name);
        int bad = 0;
        sw = mode;
        repeat (3 * 4 * 800 * 525) @(posedge clk);       // let two full frames pass
        for (int y = 0; y < 480; y++)
            for (int x = 0; x < 640; x++)
                if (cap[y][x] !== expect_px(mode, x, y)) begin
                    bad++;
                    if (bad <= 5) $display("  %s mismatch at x=%0d y=%0d: got %0d expected %0d",
                                           name, x, y, cap[y][x], expect_px(mode, x, y));
                end
        if (bad == 0) $display("PASS  VGA %s: all 307200 pixels correct", name);
        else begin $display("FAIL  VGA %s: %0d pixels wrong", name, bad); errs += bad; end
    endtask

    task automatic load_and_check(input int w, input int h, input int pattern, input string tag);
        int k, bad;
        IW = w; IH = h;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) begin
                img[y][x] = (pattern == 0) ? 8'((x * 2 + y * 3) % 256) : 8'((x * 9 + y * 4) % 256);
                if (x >= w / 3 && x < 2 * w / 3 && y >= h / 4 && y < 3 * h / 4) img[y][x] = 8'd250;
                if ((x * 7 + y * 13) % 23 == 0) img[y][x] = 8'($urandom_range(255, 0));
            end

        rx_q.delete();
        send_byte(8'(w >> 8)); send_byte(8'(w));
        send_byte(8'(h >> 8)); send_byte(8'(h));
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) send_byte(img[y][x]);
        repeat (40 * CPB) @(posedge clk);

        bad = 0; k = 0;
        if (rx_q.size() != (w - 2) * (h - 2)) begin
            bad++;
            $display("  UART reply has %0d bytes, expected %0d", rx_q.size(), (w - 2) * (h - 2));
        end
        for (int y = 1; y <= h - 2; y++)
            for (int x = 1; x <= w - 2; x++) begin
                if (k < rx_q.size() && int'(rx_q[k]) != sobel_ref(y, x)) bad++;
                k++;
            end
        if (bad == 0) $display("PASS  [%s] UART reply matches the software Sobel", tag);
        else begin $display("FAIL  [%s] UART reply (%0d problems)", tag, bad); errs += bad; end

        check_mode(2'b00, {tag, " Sobel 2x"});
        check_mode(2'b01, {tag, " raw 2x"});
        check_mode(2'b10, {tag, " side-by-side"});
    endtask

    initial begin
        repeat (10) @(posedge clk);
        btnC = 1'b0;
        repeat (10) @(posedge clk);

        load_and_check(100, 60, 0, "100x60");
        // a second, smaller image must replace the first and leave no old pixels outside it
        load_and_check(41, 23, 1, "41x23");

        if (led[4:2] != 3'b000) begin $display("FAIL  error LEDs set: %b", led[4:2]); errs++; end
        else $display("PASS  error LEDs clear");

        if (chan_errs != 0) begin $display("FAIL  colour channels differ %0d times", chan_errs); errs++; end

        if (errs == 0) $display("ALL TESTS PASSED");
        else $fatal(1, "TESTS FAILED (%0d)", errs);
        $finish;
    end
endmodule
