// Image pipeline testbench for sobel.sv. Pure SystemVerilog.
//
//   ./Vsobel_image_tb +in=image.pgm +out=result.pgm
//
// Reads an ASCII (P2) greyscale PGM, streams it through the DUT, checks the
// result against a software Sobel computed here, and writes the result as an
// ASCII PGM. Converting a normal image (PNG, JPG) to and from PGM is done
// outside the simulation, see the process_sv target in the Makefile.

module sobel_image_tb;

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
    logic [7:0] img  [];
    logic [7:0] got  [];
    bit         seen [];
    int         n_valid;
    int         n_bad_index;

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

    // One pixel per clock in row-major order. The result for the window
    // centred on pixel n appears (W + 3) clocks after pixel n goes in, so three
    // extra clocks are run after the last pixel to collect the final results.
    task automatic stream_image();
        int total;
        int centre;

        total = W * H + 3;
        got   = new[W * H];
        seen  = new[W * H];
        for (int i = 0; i < W * H; i++) begin
            got[i]  = 8'd0;
            seen[i] = 1'b0;
        end
        n_valid     = 0;
        n_bad_index = 0;

        image_width = 16'(W);
        reset_dut();

        for (int a = 0; a < total; a++) begin
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
    // ------------------------------------------------------------------
    function automatic int check_image();
        int errs;
        int e;

        errs = 0;
        for (int y = 0; y < H; y++) begin
            for (int x = 0; x < W; x++) begin
                if (y >= 1 && y <= H - 2 && x >= 1 && x <= W - 2) begin
                    e = sobel_ref(y, x);
                    if (!seen[y * W + x] || int'(got[y * W + x]) != e) begin
                        errs++;
                        if (errs <= 5)
                            $display("  MISMATCH (y=%0d,x=%0d): expected %0d, got %0d",
                                     y, x, e, got[y * W + x]);
                    end
                end else if (seen[y * W + x]) begin
                    errs++;
                    if (errs <= 5) $display("  UNEXPECTED output on border (y=%0d,x=%0d)", y, x);
                end
            end
        end
        if (n_valid != (W - 2) * (H - 2)) begin
            errs++;
            $display("  expected %0d valid outputs, saw %0d", (W - 2) * (H - 2), n_valid);
        end
        errs += n_bad_index;
        return errs;
    endfunction

    // ------------------------------------------------------------------
    // Main
    // ------------------------------------------------------------------
    string in_path;
    string out_path;
    int    errs;

    initial begin
        rst      = 1'b1;
        valid_in = 1'b0;

        if (!$value$plusargs("in=%s", in_path))
            $fatal(1, "Usage: ./Vsobel_image_tb +in=input.pgm [+out=output.pgm]");
        if (!$value$plusargs("out=%s", out_path)) out_path = "sobel_out.pgm";

        read_pgm(in_path);
        $display("Loaded image: %0dx%0d", W, H);

        stream_image();
        errs = check_image();
        write_pgm(out_path);
        $display("Output written to %s", out_path);

        if (errs == 0) $display("Matches the software Sobel model.");
        else           $fatal(1, "Output differs from the software Sobel model (%0d problems)", errs);

        $finish;
    end

endmodule