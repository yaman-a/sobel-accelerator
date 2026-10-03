// Self-checking testbench for sobel.sv. Pure SystemVerilog, no Python or C++.
//
// Regression mode (default):
//   Generates the same patterns as generate_tests.py (vertical, horizontal,
//   checker, diagonal, noise) at several sizes, streams each through the DUT,
//   and compares every output pixel with a software Sobel computed here.
//   Also runs a noise image with random stalls on valid_in.
//   Exits with an error if anything mismatches.
//
// File mode:
//   ./Vsobel_tb +in=image.pgm +out=result.pgm
//   Reads an ASCII (P2) PGM, runs it through the DUT, checks it against the
//   software model, and writes the result as an ASCII PGM.


module sobel_tb;

    // ------------------------------------------------------------------
    // DUT and clock
    // ------------------------------------------------------------------
    logic        clk = 1'b0;
    logic        rst;
    logic [15:0] image_width;
    logic        valid_in;
    logic [7:0]  pixel_in;
    logic        valid_out;
    logic [7:0]  pixel_out;

    sobel dut (.*);

    always #5 clk = ~clk;

    // ------------------------------------------------------------------
    // Image storage (flattened, row-major)
    // ------------------------------------------------------------------
    int         W, H;
    logic [7:0] img  [];     // input image
    logic [7:0] got  [];     // DUT output, placed at the centre pixel
    bit         seen [];     // which output pixels the DUT produced

    int n_valid;             // number of valid_out pulses collected
    int n_bad_index;         // outputs whose centre fell outside the image
    int n_idle_violations;   // valid_out high during a cycle with valid_in low

    // ------------------------------------------------------------------
    // Test patterns (mirror generate_tests.py)
    // ------------------------------------------------------------------
    localparam int N_KINDS = 5;

    function automatic string pattern_name(input int kind);
        case (kind)
            0: return "vertical";
            1: return "horizontal";
            2: return "checker";
            3: return "diagonal";
            default: return "noise";
        endcase
    endfunction

    task automatic make_pattern(input int kind, input int w, input int h);
        W = w;
        H = h;
        img = new[w * h];
        for (int y = 0; y < h; y++) begin
            for (int x = 0; x < w; x++) begin
                logic [7:0] v;
                case (kind)
                    0: v = (x >= w / 2) ? 8'd255 : 8'd0;
                    1: v = (y >= h / 2) ? 8'd255 : 8'd0;
                    2: v = (((x / 8) + (y / 8)) % 2 == 0) ? 8'd0 : 8'd255;
                    3: v = (x == y) ? 8'd255 : 8'd0;
                    default: v = 8'($urandom_range(255, 0));
                endcase
                img[y * w + x] = v;
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Software reference Sobel: |gx| + |gy|, clamped to 255
    // ------------------------------------------------------------------
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

    // ------------------------------------------------------------------
    // Drive the DUT
    // ------------------------------------------------------------------
    task automatic reset_dut();
        rst      = 1'b1;
        valid_in = 1'b0;
        pixel_in = 8'd0;
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;
    endtask

    // Streams the image in row-major order, one pixel per accepted clock.
    // The DUT's result for the window centred on pixel n appears on the clock
    // that is (W + 3) accepted clocks after pixel n was accepted, so three extra
    // clocks are run after the last pixel to collect the final results.
    task automatic stream_image(input bit stalls);
        int total;
        int centre;

        total = W * H + 3;
        got   = new[W * H];
        seen  = new[W * H];
        for (int i = 0; i < W * H; i++) begin
            got[i]  = 8'd0;
            seen[i] = 1'b0;
        end
        n_valid           = 0;
        n_bad_index       = 0;
        n_idle_violations = 0;

        image_width = 16'(W);
        reset_dut();

        for (int a = 0; a < total; a++) begin
            if (stalls) begin
                // idle cycles with garbage on pixel_in: the DUT must ignore them
                while ($urandom_range(3, 0) == 0) begin
                    valid_in = 1'b0;
                    pixel_in = 8'($urandom);
                    @(posedge clk);
                    #1;
                    if (valid_out) n_idle_violations++;
                end
            end

            valid_in = 1'b1;
            pixel_in = (a < W * H) ? img[a] : 8'd0;
            @(posedge clk);
            #1;

            if (valid_out) begin
                centre = a - (W + 3);
                if (centre < 0 || centre >= W * H) begin
                    n_bad_index++;
                end else begin
                    got[centre]  = pixel_out;
                    seen[centre] = 1'b1;
                    n_valid++;
                end
            end
        end
        valid_in = 1'b0;
    endtask

    // ------------------------------------------------------------------
    // Compare against the software model. Returns the number of problems.
    // Interior pixels must match exactly. The one-pixel border has no full
    // 3x3 window, so the DUT must not produce output there.
    // ------------------------------------------------------------------
    function automatic int check_image(input string name);
        int errs;
        int expected_valid;
        int e;

        errs = 0;
        expected_valid = (W >= 3 && H >= 3) ? (W - 2) * (H - 2) : 0;

        for (int y = 0; y < H; y++) begin
            for (int x = 0; x < W; x++) begin
                if (y >= 1 && y <= H - 2 && x >= 1 && x <= W - 2) begin
                    e = sobel_ref(y, x);
                    if (!seen[y * W + x] || int'(got[y * W + x]) != e) begin
                        errs++;
                        if (errs <= 5)
                            $display("  MISMATCH %s (y=%0d,x=%0d): expected %0d, got %0d%s",
                                     name, y, x, e, got[y * W + x],
                                     seen[y * W + x] ? "" : " (no output)");
                    end
                end else if (seen[y * W + x]) begin
                    errs++;
                    if (errs <= 5)
                        $display("  UNEXPECTED output on border %s (y=%0d,x=%0d)", name, y, x);
                end
            end
        end

        if (n_valid != expected_valid) begin
            errs++;
            $display("  %s: expected %0d valid outputs, saw %0d", name, expected_valid, n_valid);
        end
        if (n_bad_index != 0) begin
            errs += n_bad_index;
            $display("  %s: %0d outputs landed outside the image", name, n_bad_index);
        end
        if (n_idle_violations != 0) begin
            errs += n_idle_violations;
            $display("  %s: valid_out was high %0d times while valid_in was low", name, n_idle_violations);
        end
        return errs;
    endfunction

    // ------------------------------------------------------------------
    // PGM (ASCII, P2) read and write
    // ------------------------------------------------------------------
    // Reads the next unsigned integer from an ASCII PGM, skipping whitespace
    // and '#' comment lines (many photos carry an embedded comment that
    // ImageMagick copies into the header). Returns -1 at end of file.
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
        if (c1 != "P" || c2 != "2")
            $fatal(1, "%s is not an ASCII PGM (expected P2 header)", path);

        next_int(fd, w);
        next_int(fd, h);
        next_int(fd, maxv);
        if (w < 3 || h < 3 || maxv < 1)
            $fatal(1, "Bad PGM header in %s (width %0d, height %0d, maxval %0d)", path, w, h, maxv);
        if (w > dut.WIDTH)
            $fatal(1, "Image is %0d wide but the module's line buffers hold %0d pixels (raise the WIDTH parameter)", w, dut.WIDTH);

        W = w;
        H = h;
        img = new[w * h];
        for (int i = 0; i < w * h; i++) begin
            next_int(fd, v);
            if (v < 0) $fatal(1, "%s ended early: expected %0d pixels, found %0d", path, w * h, i);
            img[i] = 8'((v * 255) / maxv);
        end
        $fclose(fd);
    endtask

    task automatic write_pgm(input string path);
        int fd;
        fd = $fopen(path, "w");
        if (fd == 0) $fatal(1, "Cannot open output file %s", path);
        $fwrite(fd, "P2\n%0d %0d\n255\n", W, H);
        for (int y = 0; y < H; y++) begin
            for (int x = 0; x < W; x++) $fwrite(fd, "%0d ", got[y * W + x]);
            $fwrite(fd, "\n");
        end
        $fclose(fd);
    endtask

    // ------------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------------
    localparam int N_SIZES = 6;
    localparam int SIZE_W [N_SIZES] = '{128, 37, 8, 5, 3, 100};
    localparam int SIZE_H [N_SIZES] = '{64,  23, 8, 5, 3, 60};

    int    total_errors;
    int    n_tests;
    int    errs;
    string in_path;
    string out_path;
    string name;

    initial begin
        total_errors = 0;
        n_tests      = 0;
        valid_in     = 1'b0;
        rst          = 1'b1;

        if ($value$plusargs("in=%s", in_path)) begin
            // ---------------- file mode ----------------
            if (!$value$plusargs("out=%s", out_path)) out_path = "sobel_out.pgm";
            read_pgm(in_path);
            $display("Loaded image: %0dx%0d", W, H);
            stream_image(1'b0);
            errs = check_image(in_path);
            write_pgm(out_path);
            $display("Output written to %s", out_path);
            if (errs == 0) $display("Matches the software Sobel model.");
            else           $fatal(1, "Output differs from the software Sobel model (%0d problems)", errs);
        end else begin
            // ---------------- regression mode ----------------
            for (int k = 0; k < N_KINDS; k++) begin
                for (int s = 0; s < N_SIZES; s++) begin
                    make_pattern(k, SIZE_W[s], SIZE_H[s]);
                    stream_image(1'b0);
                    name = $sformatf("%s_%0dx%0d", pattern_name(k), W, H);
                    errs = check_image(name);
                    n_tests++;
                    total_errors += errs;
                    $display("%s %s", (errs == 0) ? "PASS" : "FAIL", name);
                end
            end

            // noise with random stalls on valid_in
            make_pattern(4, 37, 23);
            stream_image(1'b1);
            name = "noise_37x23_with_stalls";
            errs = check_image(name);
            n_tests++;
            total_errors += errs;
            $display("%s %s", (errs == 0) ? "PASS" : "FAIL", name);

            if (total_errors == 0) $display("ALL %0d TESTS PASSED", n_tests);
            else $fatal(1, "%0d problems across %0d tests", total_errors, n_tests);
        end

        $finish;
    end

endmodule