// Testbench for sobel_cam_core with a behavioural OV7670:
//   - an SCCB slave that acknowledges and records every register write
//   - a pixel source that produces VSYNC / HREF / PCLK / D[7:0] like the real sensor
//     (QVGA, YUV422, 640 bytes per line, data changing after the falling edge of PCLK)
// The captured frames are compared with the known image, in the frame buffers and on VGA.

module sobel_cam_tb;

    localparam int W = 320;
    localparam int H = 240;

    logic        clk = 1'b0;
    logic        btnC = 1'b1;
    logic [4:0]  sw = 5'b00000;
    logic        cam_xclk, cam_scl, sda_o, sda_oe, sda_i;
    logic        cam_pclk = 1'b0, cam_href = 1'b0, cam_vsync = 1'b0;
    logic [7:0]  cam_d = '0;
    logic [3:0]  vgaRed, vgaGreen, vgaBlue;
    logic        Hsync, Vsync;
    logic [15:0] led;

    sobel_cam_core #(.UNIT(20), .DIV(8)) dut (
        .clk(clk), .btnC(btnC), .sw(sw),
        .cam_xclk(cam_xclk), .cam_resetn(), .cam_pwdn(), .cam_scl(cam_scl),
        .sda_o(sda_o), .sda_oe(sda_oe), .sda_i(sda_i),
        .cam_pclk(cam_pclk), .cam_href(cam_href), .cam_vsync(cam_vsync), .cam_d(cam_d),
        .vgaRed(vgaRed), .vgaGreen(vgaGreen), .vgaBlue(vgaBlue),
        .Hsync(Hsync), .Vsync(Vsync), .led(led)
    );

    always #5 clk = ~clk;

    // ------------------------------------------------------------------
    // The picture the camera "sees"
    // ------------------------------------------------------------------
    logic [7:0] yimg [H][W];

    function automatic int px(input int y, input int x);
        return int'(yimg[y][x]);
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

    // ------------------------------------------------------------------
    // Camera model: SCCB slave
    // ------------------------------------------------------------------
    logic       ack_en = 1'b1;
    logic       cam_sda_low = 1'b0;                  // camera pulling SDA low
    assign sda_i = (sda_oe ? sda_o : 1'b1) & ~cam_sda_low;     // open-drain bus with pull-up

    logic [7:0] regs [256];
    int         n_writes = 0;
    int         sccb_errs = 0;
    logic       cam_run = 1'b0;
    int         first_reg = -1;
    int         first_data = -1;

    logic       scl_p = 1'b1, sda_p = 1'b1;
    int         bitcnt = 0, byte_idx = 0;
    logic [7:0] shreg = '0;
    logic [7:0] rcv_reg = '0;
    logic       acking = 1'b0;
    logic       in_xfer = 1'b0;

    always @(posedge clk) begin
        scl_p <= cam_scl;
        sda_p <= sda_i;

        // START: SDA falls while SCL is high
        if (cam_scl && scl_p && sda_p && !sda_i) begin
            in_xfer  <= 1'b1;
            bitcnt   <= 0;
            byte_idx <= 0;
            acking   <= 1'b0;
            cam_sda_low <= 1'b0;
        end
        // STOP: SDA rises while SCL is high
        else if (cam_scl && scl_p && !sda_p && sda_i) begin
            if (in_xfer && byte_idx != 3) begin
                sccb_errs++;
                $display("  SCCB: transaction ended after %0d bytes", byte_idx);
            end
            in_xfer <= 1'b0;
        end
        // clock rising: sample a data bit
        else if (in_xfer && cam_scl && !scl_p) begin
            if (!acking && bitcnt < 8) begin
                shreg  <= {shreg[6:0], sda_i};
                bitcnt <= bitcnt + 1;
            end
        end
        // clock falling: start or end the acknowledge
        else if (in_xfer && !cam_scl && scl_p) begin
            if (!acking && bitcnt == 8) begin
                acking <= 1'b1;
                if (ack_en) cam_sda_low <= 1'b1;
            end else if (acking) begin
                acking      <= 1'b0;
                cam_sda_low <= 1'b0;
                bitcnt      <= 0;
                case (byte_idx)
                    0: if (shreg != 8'h42) begin
                           sccb_errs++;
                           $display("  SCCB: device byte %02h, expected 42", shreg);
                       end
                    1: rcv_reg <= shreg;
                    2: begin
                           regs[rcv_reg] <= shreg;
                           n_writes++;
                           if (first_reg < 0) begin first_reg = int'(rcv_reg); first_data = int'(shreg); end
                           if (rcv_reg == 8'h12 && shreg == 8'h10) cam_run <= 1'b1;
                       end
                    default: ;
                endcase
                byte_idx <= byte_idx + 1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Camera model: pixel output
    // ------------------------------------------------------------------
    int  pclk_per = 16;           // clocks per PCLK period (16 = 6.25 MHz, 8 = 12.5 MHz)
    bit  uyvy     = 1'b1;         // byte order: 0 = Y U Y V, 1 = U Y V Y (what the real camera sends)

    task automatic byte_tick(input logic [7:0] dd, input logic hh, input logic vv);
        int low_ns, high_ns;
        low_ns  = (pclk_per / 2) * 10;
        high_ns = (pclk_per - pclk_per / 2) * 10;
        cam_d = dd; cam_href = hh; cam_vsync = vv;     // changes just after the falling edge
        #(low_ns - 3);
        cam_pclk = 1'b1;
        #(high_ns);
        cam_pclk = 1'b0;
        #3;
    endtask

    function automatic logic [7:0] line_byte(input int y, input int b);
        int p;
        logic [7:0] chroma;
        p      = b / 2;
        chroma = (p % 2 == 0) ? 8'hAA : 8'h55;
        if (!uyvy) return (b % 2 == 0) ? yimg[y][p] : chroma;
        else       return (b % 2 == 0) ? chroma : yimg[y][p];
    endfunction

    task automatic idle_lines(input int n, input logic vv);
        repeat (n) repeat (784) byte_tick(8'($urandom_range(255, 0)), 1'b0, vv);
    endtask

    initial begin
        wait (cam_run);
        forever begin
            idle_lines(3, 1'b1);                         // VSYNC high
            idle_lines(10, 1'b0);                        // back porch
            for (int y = 0; y < H; y++) begin
                for (int b = 0; b < 640; b++) byte_tick(line_byte(y, b), 1'b1, 1'b0);
                repeat (144) byte_tick(8'($urandom_range(255, 0)), 1'b0, 1'b0);
            end
            idle_lines(4, 1'b0);                         // front porch
        end
    end

    // ------------------------------------------------------------------
    // Checks
    // ------------------------------------------------------------------
    int errs = 0;

    task automatic wait_frames(input int n);
        logic t;
        repeat (n) begin
            t = led[5];
            wait (led[5] !== t);
        end
        repeat (200) @(posedge clk);
    endtask

    task automatic check_buffers(input string name);
        int bad_raw = 0, bad_edge = 0;
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++) begin
                if (dut.u_store.u_raw.mem[y * 320 + x] !== yimg[y][x][7:4]) begin
                    bad_raw++;
                    if (bad_raw <= 3) $display("  raw mismatch y=%0d x=%0d: got %0d want %0d", y, x,
                                               dut.u_store.u_raw.mem[y * 320 + x], yimg[y][x][7:4]);
                end
                if (y >= 1 && y <= H - 2 && x >= 1 && x <= W - 2)
                    if (dut.u_store.u_edge.mem[y * 320 + x] !== edge4(y, x)) begin
                        bad_edge++;
                        if (bad_edge <= 3) $display("  edge mismatch y=%0d x=%0d: got %0d want %0d", y, x,
                                                    dut.u_store.u_edge.mem[y * 320 + x], edge4(y, x));
                    end
            end
        if (bad_raw == 0 && bad_edge == 0) $display("PASS  %s: original and Sobel buffers correct", name);
        else begin $display("FAIL  %s: %0d raw, %0d edge pixels wrong", name, bad_raw, bad_edge); errs += bad_raw + bad_edge; end
    endtask

    task automatic expect_true(input string name, input bit cond);
        if (cond) $display("PASS  %s", name);
        else begin $display("FAIL  %s", name); errs++; end
    endtask

    // VGA capture
    logic [3:0] cap [480][640];
    logic [9:0] xd, yd;
    logic       actd;
    always @(posedge clk) if (dut.u_store.pix_en) begin
        if (actd) cap[yd][xd] <= vgaRed;
        xd <= dut.u_store.x; yd <= dut.u_store.y; actd <= dut.u_store.active;
    end

    function automatic logic [3:0] expect_px(input logic [1:0] mode, input int x, input int y);
        int ix, iy;
        logic use_edge;
        if (mode[1]) begin
            if (y < 120 || y >= 360) return 4'd0;
            iy = y - 120;
            use_edge = (x >= 320);
            ix = use_edge ? x - 320 : x;
        end else begin
            ix = x / 2; iy = y / 2; use_edge = !mode[0];
        end
        if (use_edge) begin
            if (ix < 1 || ix > W - 2 || iy < 1 || iy > H - 2) return 4'd0;
            return edge4(iy, ix);
        end
        return yimg[iy][ix][7:4];
    endfunction

    task automatic check_vga(input logic [1:0] mode, input string name);
        int bad = 0;
        sw[1:0] = mode;
        repeat (3 * 4 * 800 * 525) @(posedge clk);
        for (int y = 0; y < 480; y++)
            for (int x = 0; x < 640; x++)
                if (cap[y][x] !== expect_px(mode, x, y)) begin
                    bad++;
                    if (bad <= 3) $display("  %s mismatch x=%0d y=%0d: got %0d want %0d", name, x, y,
                                           cap[y][x], expect_px(mode, x, y));
                end
        if (bad == 0) $display("PASS  VGA %s: all pixels correct", name);
        else begin $display("FAIL  VGA %s: %0d pixels wrong", name, bad); errs += bad; end
    endtask

    logic [7:0] want [int];

    initial begin
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++) begin
                yimg[y][x] = 8'((x + 2 * y) % 256);
                if (x >= 100 && x < 220 && y >= 60 && y < 180) yimg[y][x] = 8'd240;
                if (x >= 130 && x < 190 && y >= 90 && y < 150) yimg[y][x] = 8'd30;
                if ((x * 7 + y * 13) % 29 == 0) yimg[y][x] = 8'($urandom_range(255, 0));
            end

        repeat (10) @(posedge clk);
        btnC = 1'b0;

        // ---- configuration over SCCB ----
        wait (led[0]);
        repeat (50) @(posedge clk);
        expect_true("camera configuration finished", led[0]);
        expect_true("every configuration write was acknowledged", !led[1]);
        expect_true("first write was the software reset (reg 12 = 80)", first_reg == 'h12 && first_data == 'h80);
        expect_true("19 register writes", n_writes == 19);
        expect_true("no SCCB protocol errors", sccb_errs == 0);

        want[8'h3A] = 8'h04; want[8'h12] = 8'h10; want[8'h40] = 8'hC0; want[8'h0C] = 8'h04;
        want[8'h3E] = 8'h19; want[8'h70] = 8'h3A; want[8'h71] = 8'h35; want[8'h72] = 8'h11;
        want[8'h73] = 8'hF1; want[8'h17] = 8'h16; want[8'h18] = 8'h04; want[8'h32] = 8'h24;
        want[8'h19] = 8'h02; want[8'h1A] = 8'h7A; want[8'h03] = 8'h0A; want[8'h11] = 8'h01;
        want[8'h3D] = 8'hC0; want[8'hA2] = 8'h02;
        begin
            int bad = 0;
            foreach (want[r]) if (regs[r] !== want[r]) begin
                bad++; $display("  reg %02h = %02h, expected %02h", r, regs[r], want[r]);
            end
            expect_true("camera registers hold the intended values", bad == 0);
        end

        // ---- pixels, at three different PCLK rates ----
        pclk_per = 16;
        wait_frames(3);                                  // let the first (partial) frames pass
        check_buffers("PCLK period 16 clocks");
        expect_true("PCLK, HREF, VSYNC activity seen", led[2] && led[3] && led[4]);

        pclk_per = 8;                                    // 12.5 MHz, the real rate with XCLK 25 MHz
        wait_frames(3);
        check_buffers("PCLK period 8 clocks");

        pclk_per = 11;                                   // not a multiple of the system clock
        wait_frames(3);
        check_buffers("PCLK period 11 clocks");

        // ---- other byte order, selected with sw[2] ----
        uyvy = 1'b0; sw[2] = 1'b1;
        pclk_per = 12;
        wait_frames(3);
        check_buffers("Y-first byte order with sw[2] up");
        uyvy = 1'b1; sw[2] = 1'b0;
        wait_frames(3);

        // ---- VGA output of the live picture ----
        pclk_per = 8;
        check_vga(2'b10, "side-by-side");
        check_vga(2'b00, "Sobel 2x");

        // ---- camera that does not answer on SCCB ----
        ack_en = 1'b0;
        btnC = 1'b1; repeat (6) @(posedge clk); btnC = 1'b0;
        wait (led[0]);
        repeat (50) @(posedge clk);
        expect_true("missing acknowledge is reported on LED 1", led[1]);
        ack_en = 1'b1;
        btnC = 1'b1; repeat (6) @(posedge clk); btnC = 1'b0;
        wait (led[0]);
        repeat (50) @(posedge clk);
        expect_true("LED 1 clears after reset when the camera answers", !led[1]);

        if (errs == 0) $display("ALL TESTS PASSED");
        else $fatal(1, "TESTS FAILED (%0d)", errs);
        $finish;
    end

    initial begin
        #3_000_000_000;
        $fatal(1, "Testbench timed out");
    end

endmodule
