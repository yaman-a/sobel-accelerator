// Bit-level testbench for sobel_uart_top (the Basys3 design).
//
// It plays the part of the PC: it wiggles the RsRx pin with real UART bit timing,
// and a monitor decodes whatever the design puts on RsTx. Every frame is checked
// against a software Sobel model.
//
//   ./Vsobel_uart_tb                       self-checking regression
//   ./Vsobel_uart_tb +in=a.pgm +out=b.pgm  also run one image through the UART link
//
// The baud divisor is shrunk (8 clocks per bit) so that the run takes seconds.
// The logic is identical to the 100 clocks per bit used on the board.

module sobel_uart_tb;

    localparam int CPB     = 8;       // clocks per bit in simulation
    localparam int TIMEOUT = 3000;    // idle clocks before the design resyncs

    logic        clk = 1'b0;
    logic        btnC;
    logic        RsRx;
    logic        RsTx;
    logic [15:0] led;

    sobel_uart_top #(
        .CLKS_PER_BIT (CPB),
        .MAX_WIDTH    (640),
        .IDLE_TIMEOUT (TIMEOUT),
        .FLUSH_CLKS   (3)
    ) dut (
        .clk  (clk),
        .btnC (btnC),
        .RsRx (RsRx),
        .RsTx (RsTx),
        .led  (led)
    );

    always #5 clk = ~clk;

    // ------------------------------------------------------------------
    // Test image and reference model
    // ------------------------------------------------------------------
    int         W, H;
    logic [7:0] img [];

    function automatic int px(input int y, input int x);
        return int'(img[y * W + x]);
    endfunction

    function automatic int iabs(input int v);
        return (v < 0) ? -v : v;
    endfunction

    function automatic int sobel_ref(input int y, input int x);
        int gx, gy, mag;
        gx = (px(y-1, x+1) + 2*px(y, x+1) + px(y+1, x+1))
           - (px(y-1, x-1) + 2*px(y, x-1) + px(y+1, x-1));
        gy = (px(y+1, x-1) + 2*px(y+1, x) + px(y+1, x+1))
           - (px(y-1, x-1) + 2*px(y-1, x) + px(y-1, x+1));
        mag = iabs(gx) + iabs(gy);
        return (mag > 255) ? 255 : mag;
    endfunction

    // pattern 0: random noise, 1: blocks (strong edges), 2: smooth ramp
    task automatic make_image(input int w, input int h, input int pattern);
        W   = w;
        H   = h;
        img = new[w * h];
        for (int y = 0; y < h; y++) begin
            for (int x = 0; x < w; x++) begin
                case (pattern)
                    0:       img[y*w + x] = 8'($urandom_range(255, 0));
                    1:       img[y*w + x] = (((x / 4) + (y / 3)) % 2) ? 8'd230 : 8'd20;
                    default: img[y*w + x] = 8'((x * 3 + y * 5) % 256);
                endcase
            end
        end
    endtask

    // ------------------------------------------------------------------
    // PC side: transmit a byte on RsRx with exact bit timing
    // ------------------------------------------------------------------
    task automatic send_byte(input logic [7:0] b);
        RsRx = 1'b0;                              // start bit
        repeat (CPB) @(posedge clk);
        for (int i = 0; i < 8; i++) begin
            RsRx = b[i];
            repeat (CPB) @(posedge clk);
        end
        RsRx = 1'b1;                              // stop bit
        repeat (CPB) @(posedge clk);
    endtask

    // max_gap = 0: bytes back to back. Otherwise a random idle gap of 0..max_gap clocks.
    task automatic send_gap(input int max_gap);
        if (max_gap > 0) repeat ($urandom_range(max_gap, 0)) @(posedge clk);
    endtask

    task automatic send_header(input int w, input int h, input int max_gap);
        send_byte(8'(w >> 8)); send_gap(max_gap);
        send_byte(8'(w));      send_gap(max_gap);
        send_byte(8'(h >> 8)); send_gap(max_gap);
        send_byte(8'(h));      send_gap(max_gap);
    endtask

    task automatic send_pixels(input int count, input int max_gap);
        for (int i = 0; i < count; i++) begin
            send_byte(img[i]);
            send_gap(max_gap);
        end
    endtask

    // ------------------------------------------------------------------
    // PC side: decode RsTx. Samples in the middle of every bit and checks the
    // start and stop bits.
    // ------------------------------------------------------------------
    logic [7:0] rx_q [$];
    int         mon_errs = 0;

    initial begin
        logic [7:0] b;
        forever begin
            @(negedge RsTx);
            repeat (CPB / 2) @(posedge clk);
            if (RsTx !== 1'b0) begin
                mon_errs++;
                $display("  monitor: start bit glitch at %0t", $time);
            end
            for (int i = 0; i < 8; i++) begin
                repeat (CPB) @(posedge clk);
                b[i] = RsTx;
            end
            repeat (CPB) @(posedge clk);
            if (RsTx !== 1'b1) begin
                mon_errs++;
                $display("  monitor: bad stop bit at %0t", $time);
            end
            rx_q.push_back(b);
        end
    end

    // FIFO occupancy, to prove the 64-deep FIFO is never anywhere near full
    int max_occ = 0;
    always @(posedge clk) begin
        int occ;
        occ = int'(dut.u_fifo.wr_ptr) - int'(dut.u_fifo.rd_ptr);
        if (occ < 0) occ += 128;
        if (occ > max_occ) max_occ = occ;
    end

    // ------------------------------------------------------------------
    // Checking
    // ------------------------------------------------------------------
    int total_errs = 0;
    int n_tests    = 0;

    // Wait until `expected` bytes have arrived (or give up), let the line settle,
    // then compare with the reference. Returns the number of problems.
    function automatic int compare_frame(input int expected);
        int errs, k, e;
        errs = 0;
        if (rx_q.size() != expected) begin
            errs++;
            $display("  expected %0d result bytes, got %0d", expected, rx_q.size());
        end
        k = 0;
        for (int y = 1; y <= H - 2; y++) begin
            for (int x = 1; x <= W - 2; x++) begin
                e = sobel_ref(y, x);
                if (k < rx_q.size()) begin
                    if (int'(rx_q[k]) != e) begin
                        errs++;
                        if (errs <= 5)
                            $display("  MISMATCH (y=%0d,x=%0d): expected %0d, got %0d", y, x, e, rx_q[k]);
                    end
                end
                k++;
            end
        end
        return errs;
    endfunction

    task automatic settle(input int expected);
        int waited;
        waited = 0;
        while (rx_q.size() < expected && waited < 4000 + expected * CPB * 10) begin
            @(posedge clk);
            waited++;
        end
        repeat (30 * CPB) @(posedge clk);       // time for any stray extra byte
    endtask

    task automatic report(input string name, input int errs);
        n_tests++;
        if (errs == 0) begin
            $display("PASS  %s", name);
        end else begin
            total_errs += errs;
            $display("FAIL  %s (%0d problems)", name, errs);
        end
    endtask

    task automatic expect_led(input string name, input int bit_idx, input logic want);
        n_tests++;
        if (led[bit_idx] !== want) begin
            total_errs++;
            $display("FAIL  %s (led[%0d] = %b, wanted %b)", name, bit_idx, led[bit_idx], want);
        end else begin
            $display("PASS  %s", name);
        end
    endtask

    // Full frame test: header, pixels, collect, compare.
    task automatic frame_test(input string name, input int w, input int h,
                              input int pattern, input int max_gap);
        int errs;
        make_image(w, h, pattern);
        rx_q.delete();
        send_header(w, h, max_gap);
        send_pixels(w * h, max_gap);
        settle((w - 2) * (h - 2));
        errs = compare_frame((w - 2) * (h - 2));
        report(name, errs);
    endtask

    task automatic press_reset();
        btnC = 1'b1;
        repeat (6) @(posedge clk);
        btnC = 1'b0;
        repeat (6) @(posedge clk);
    endtask

    // ------------------------------------------------------------------
    // File mode: one image through the UART link, written back as a PGM with
    // a zero border (the PC side of the real system does the same).
    // ------------------------------------------------------------------
    task automatic next_int(input int fd, output int value);
        int c;
        value = -1;
        c = $fgetc(fd);
        while (c != -1) begin
            if (c == "#") begin
                while (c != -1 && c != "\n") c = $fgetc(fd);
            end else if (c == " " || c == "\n" || c == "\r" || c == "\t") begin
                c = $fgetc(fd);
            end else begin
                break;
            end
        end
        if (c >= "0" && c <= "9") begin
            value = 0;
            while (c >= "0" && c <= "9") begin
                value = value * 10 + (c - "0");
                c = $fgetc(fd);
            end
        end
    endtask

    task automatic read_pgm(input string path);
        int fd, c1, c2, w, h, maxv, v;
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "Cannot open input file %s", path);
        c1 = $fgetc(fd);
        c2 = $fgetc(fd);
        if (c1 != "P" || c2 != "2") $fatal(1, "%s is not an ASCII PGM (expected P2)", path);
        next_int(fd, w);
        next_int(fd, h);
        next_int(fd, maxv);
        if (w < 3 || h < 3 || maxv < 1)
            $fatal(1, "Bad PGM header in %s (%0dx%0d, maxval %0d)", path, w, h, maxv);
        if (w > 640) $fatal(1, "Image is %0d wide, the design handles at most 640", w);
        W   = w;
        H   = h;
        img = new[w * h];
        for (int i = 0; i < w * h; i++) begin
            next_int(fd, v);
            if (v < 0) $fatal(1, "%s ended early at pixel %0d of %0d", path, i, w * h);
            img[i] = 8'((v * 255) / maxv);
        end
        $fclose(fd);
    endtask

    task automatic write_padded_pgm(input string path);
        int fd, k;
        fd = $fopen(path, "w");
        if (fd == 0) $fatal(1, "Cannot open output file %s", path);
        $fwrite(fd, "P2\n%0d %0d\n255\n", W, H);
        k = 0;
        for (int y = 0; y < H; y++) begin
            for (int x = 0; x < W; x++) begin
                if (y >= 1 && y <= H - 2 && x >= 1 && x <= W - 2 && k < rx_q.size()) begin
                    $fwrite(fd, "%0d ", rx_q[k]);
                    k++;
                end else begin
                    $fwrite(fd, "0 ");
                end
            end
            $fwrite(fd, "\n");
        end
        $fclose(fd);
    endtask

    // ------------------------------------------------------------------
    // Main
    // ------------------------------------------------------------------
    string in_path, out_path;
    int    errs;
    int    toggles_before;
    logic  tog;

    initial begin
        RsRx = 1'b1;
        btnC = 1'b1;
        repeat (10) @(posedge clk);
        btnC = 1'b0;
        repeat (10) @(posedge clk);

        // ---- normal frames ----
        frame_test("37x23 noise, bytes back to back",   37, 23, 0, 0);
        report("FIFO stays shallow (max occupancy < 16)", (max_occ < 16) ? 0 : 1);
        $display("      max FIFO occupancy seen: %0d of 64", max_occ);

        frame_test("37x23 blocks, bytes back to back",  37, 23, 1, 0);
        frame_test("16x9 ramp, random gaps up to 40",   16,  9, 2, 40);
        frame_test("16x9 noise, random gaps up to 400", 16,  9, 0, 400);
        frame_test("3x3 minimum size",                   3,  3, 0, 0);
        frame_test("3x40 narrow",                        3, 40, 0, 0);
        frame_test("40x3 short",                        40,  3, 0, 0);
        frame_test("640x3 maximum width",              640,  3, 0, 0);

        // ---- two frames with no pause, different sizes ----
        begin
            int e1, e2;
            logic [7:0] saved [$];

            make_image(20, 10, 0);
            rx_q.delete();
            send_header(20, 10, 0);
            send_pixels(20 * 10, 0);
            // no settle: the next header follows immediately
            begin
                int w1 = W, h1 = H;
                logic [7:0] img1 [];
                img1 = img;
                make_image(11, 7, 1);
                send_header(11, 7, 0);
                send_pixels(11 * 7, 0);
                settle((w1 - 2) * (h1 - 2) + 9 * 5);

                // split the received stream into the two frames and check each
                saved = rx_q;
                rx_q.delete();
                for (int i = 0; i < (w1 - 2) * (h1 - 2) && i < saved.size(); i++) rx_q.push_back(saved[i]);
                begin
                    int tw = W, th = H;
                    logic [7:0] img2 [];
                    img2 = img;
                    W = w1; H = h1; img = img1;
                    e1 = compare_frame((w1 - 2) * (h1 - 2));
                    W = tw; H = th; img = img2;
                end
                rx_q.delete();
                for (int i = (w1 - 2) * (h1 - 2); i < saved.size(); i++) rx_q.push_back(saved[i]);
                e2 = compare_frame(9 * 5);
            end
            report("two frames back to back (20x10 then 11x7)", e1 + e2);
        end

        // ---- LEDs after good traffic ----
        expect_led("no bad header flagged yet",  2, 1'b0);
        expect_led("no UART framing error",      3, 1'b0);
        expect_led("no FIFO overflow",           4, 1'b0);
        expect_led("not in a frame when idle",   0, 1'b0);

        tog = led[1];
        frame_test("frame toggles LED 1", 10, 6, 0, 0);
        expect_led("LED 1 changed after a frame", 1, ~tog);

        // ---- frame abandoned half way, then a good frame ----
        make_image(10, 10, 0);
        rx_q.delete();
        send_header(10, 10, 0);
        send_pixels(30, 0);
        repeat (TIMEOUT + 200) @(posedge clk);
        expect_led("timeout returns to idle after a cut-off frame", 0, 1'b0);
        frame_test("good frame after a cut-off frame", 14, 8, 0, 0);

        // ---- bad headers ----
        make_image(8, 8, 0);
        rx_q.delete();
        send_header(2, 10, 0);                     // width too small
        send_pixels(20, 0);
        repeat (TIMEOUT + 200) @(posedge clk);
        report("no output for width 2", rx_q.size() == 0 ? 0 : 1);
        expect_led("bad header flagged (width 2)", 2, 1'b1);
        frame_test("good frame after bad header", 12, 9, 0, 0);

        rx_q.delete();
        make_image(641, 4, 0);
        send_header(641, 4, 0);                    // width too big: enough pixels that a wrongly
        send_pixels(641 * 4, 0);                   // accepted frame would produce output
        repeat (TIMEOUT + 200) @(posedge clk);
        report("no output for width 641", rx_q.size() == 0 ? 0 : 1);

        rx_q.delete();
        send_header(10, 2, 0);                     // height too small
        send_pixels(20, 0);
        repeat (TIMEOUT + 200) @(posedge clk);
        report("no output for height 2", rx_q.size() == 0 ? 0 : 1);
        frame_test("good frame after three bad headers", 25, 13, 0, 0);

        // a byte whose stop bit is low must raise the framing-error LED
        RsRx = 1'b0; repeat (CPB) @(posedge clk);            // start
        repeat (8) begin RsRx = 1'b1; repeat (CPB) @(posedge clk); end
        RsRx = 1'b0; repeat (CPB) @(posedge clk);            // bad stop bit
        RsRx = 1'b1; repeat (4 * CPB) @(posedge clk);
        expect_led("framing error flagged for a low stop bit", 3, 1'b1);
        repeat (TIMEOUT + 200) @(posedge clk);

        // reset button clears the sticky LED
        press_reset();
        expect_led("reset clears the bad-header LED", 2, 1'b0);
        expect_led("reset clears the framing-error LED", 3, 1'b0);
        frame_test("frame works after reset button", 18, 11, 1, 0);

        // ---- optional: one real image ----
        if ($value$plusargs("in=%s", in_path)) begin
            if (!$value$plusargs("out=%s", out_path)) out_path = "sobel_uart_out.pgm";
            read_pgm(in_path);
            $display("Loaded image: %0dx%0d, sending over the simulated UART", W, H);
            rx_q.delete();
            send_header(W, H, 0);
            send_pixels(W * H, 0);
            settle((W - 2) * (H - 2));
            errs = compare_frame((W - 2) * (H - 2));
            report("image through UART matches software model", errs);
            write_padded_pgm(out_path);
            $display("Output written to %s", out_path);
        end

        // ---- summary ----
        total_errs += mon_errs;
        $display("");
        $display("%0d checks, %0d problems, %0d UART monitor errors", n_tests, total_errs, mon_errs);
        if (total_errs == 0) $display("ALL TESTS PASSED");
        else                 $fatal(1, "TESTS FAILED");
        $finish;
    end

    // watchdog
    initial begin
        #2_000_000_000;
        $fatal(1, "Testbench timed out");
    end

endmodule
