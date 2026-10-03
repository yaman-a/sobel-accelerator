// Checks vga_test_top: sync timing against the 640x480 standard, then dumps one frame
// as a PPM so the pattern can be looked at.
module vga_tb;
    logic clk = 0, btnC = 1;
    logic [3:0] vgaRed, vgaGreen, vgaBlue;
    logic Hsync, Vsync;
    logic [15:0] led;

    vga_test_top dut (.*);
    always #5 clk = ~clk;

    // pixel-rate sampling: every 4th clock, in step with the design's pix_en
    int errs = 0;
    int hs_width, hs_period, vs_lines, vs_period;
    int frame_pixels;
    int fd;
    logic [3:0] fr [480][640], fg [480][640], fb [480][640];
    int px, py;

    initial begin
        repeat (8) @(posedge clk);
        btnC = 0;
    end

    // measure in pixel units using the DUT's internal pixel enable
    int hs_cnt = 0, hs_low = 0, last_hs_fall = -1, hs_fall_count = 0;
    int line_cnt = 0, vs_low_lines = 0, vs_fall_line = -1, last_vs_fall = -1;
    int pix_cnt = 0, vis_cnt = 0, frames_done = 0;
    logic hs_prev = 1, vs_prev = 1;
    int hs_pix_now = 0;      // pixel counter since reset
    int vs_low_px = 0;
    int line_idx = 0;
    int meas_hperiod = 0, meas_hwidth = 0, meas_vperiod = 0, meas_vwidth = 0;

    always @(posedge clk) if (dut.pix_en && !btnC && dut.rst === 1'b0) begin
        // outputs are registered one pix_en later than hc/vc, so observe the registered pins
        hs_pix_now++;
        if (hs_prev && !Hsync) begin
            if (last_hs_fall >= 0) meas_hperiod = hs_pix_now - last_hs_fall;
            last_hs_fall = hs_pix_now;
            hs_low = 0;
            line_idx++;
        end
        if (!Hsync) hs_low++;
        if (!hs_prev && Hsync) meas_hwidth = hs_low;
        hs_prev = Hsync;

        if (vs_prev && !Vsync) begin
            if (last_vs_fall >= 0) meas_vperiod = hs_pix_now - last_vs_fall;
            last_vs_fall = hs_pix_now;
            vs_low_px = 0;
        end
        if (!Vsync) vs_low_px++;
        if (!vs_prev && Vsync) meas_vwidth = vs_low_px;
        vs_prev = Vsync;
    end

    // capture the first full frame from the DUT's own coordinates
    // (registered colour is one pix_en behind x,y, so delay the coordinates)
    logic [9:0] xd, yd;
    logic       actd;
    int captured = 0;
    always @(posedge clk) if (dut.pix_en) begin
        xd <= dut.x; yd <= dut.y; actd <= dut.active;
        if (actd && captured < 640 * 480 && !btnC) begin
            fr[yd][xd] = vgaRed; fg[yd][xd] = vgaGreen; fb[yd][xd] = vgaBlue;
            captured++;
        end
    end

    initial begin
        // run 3 frames' worth of time
        #(10 * 4 * 800 * 525 * 3 + 1000);
        $display("Hsync period %0d pixels (want 800), low width %0d (want 96)", meas_hperiod, meas_hwidth);
        $display("Vsync period %0d pixels (want %0d), low width %0d pixels (want %0d = 2 lines)",
                 meas_vperiod, 800 * 525, meas_vwidth, 800 * 2);
        if (meas_hperiod != 800)      errs++;
        if (meas_hwidth  != 96)       errs++;
        if (meas_vperiod != 800*525)  errs++;
        if (meas_vwidth  != 800*2)    errs++;
        $display("captured %0d visible pixels (want %0d for the first frame)", captured, 640*480);
        if (captured < 640 * 480) errs++;

        fd = $fopen("vga_frame.ppm", "w");
        $fwrite(fd, "P3\n640 480\n15\n");
        for (int j = 0; j < 480; j++) begin
            for (int i = 0; i < 640; i++) $fwrite(fd, "%0d %0d %0d ", fr[j][i], fg[j][i], fb[j][i]);
            $fwrite(fd, "\n");
        end
        $fclose(fd);

        if (errs == 0) $display("VGA TIMING OK");
        else $fatal(1, "VGA TIMING FAILED (%0d)", errs);
        $finish;
    end
endmodule
