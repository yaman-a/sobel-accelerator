// Streaming 3x3 Sobel edge detector.
//
// Input:  one greyscale pixel per clock (row-major) while valid_in is high.
// Output: gradient magnitude |gx| + |gy|, clamped to 255.
//
// Timing: the result for the window centred on input pixel n appears with
// valid_out high on the clock edge n + image_width + 3, where the edge that
// accepts input pixel 0 is edge 0. The one-pixel border has no full window,
// so no output is produced for it.
//
// Pipeline (all stages advance together, only when valid_in is high):
//   1. window registers load from the line buffers and the input pixel
//   2. gx and gy are computed from the window and registered
//   3. |gx| + |gy| is computed, clamped to 255 and registered to pixel_out
// Splitting the arithmetic over stages 2 and 3 keeps each stage short enough
// to meet a 100 MHz clock on an Artix-7.
module sobel #(
    // parameter int WIDTH = 4096   // maximum image width (line buffer depth)
)(
    input  logic        clk,
    input  logic        rst,
    input  logic [15:0] image_width,   // actual image width
    input  logic        valid_in,
    input  logic [7:0]  pixel_in,
    output logic        valid_out,
    output logic [7:0]  pixel_out
);

    localparam int COL_W = $clog2(WIDTH);

    // position of the pixel currently being accepted
    logic [COL_W-1:0] col;
    logic [15:0]      row;

    // line buffers: line_buffer1 holds the previous row, line_buffer2 the one before
    logic [7:0] line_buffer1 [WIDTH];
    logic [7:0] line_buffer2 [WIDTH];

    // 3x3 window shift registers (r0 = newest row, r2 = oldest row)
    logic [7:0] r0_0, r0_1, r0_2;
    logic [7:0] r1_0, r1_1, r1_2;
    logic [7:0] r2_0, r2_1, r2_2;

    // high when the window registers hold a complete 3x3 window
    logic win_valid;

    // pipeline stage 2: gradients computed from the window
    logic signed [11:0] gx_wire;
    logic signed [11:0] gy_wire;

    // pipeline stage 2 -> 3 registers
    logic signed [11:0] gx_reg;
    logic signed [11:0] gy_reg;
    logic               stage2_valid;

    // pipeline stage 3: magnitude computed from the registered gradients
    logic signed [11:0] abs_gx_wire;
    logic signed [11:0] abs_gy_wire;
    logic        [11:0] grad_wire;

    assign gx_wire =
        -$signed({4'b0000, r2_2}) + $signed({4'b0000, r2_0})
        - ($signed({4'b0000, r1_2}) <<< 1) + ($signed({4'b0000, r1_0}) <<< 1)
        - $signed({4'b0000, r0_2}) + $signed({4'b0000, r0_0});

    assign gy_wire =
          $signed({4'b0000, r2_2}) + ($signed({4'b0000, r2_1}) <<< 1)
        + $signed({4'b0000, r2_0}) - $signed({4'b0000, r0_2})
        - ($signed({4'b0000, r0_1}) <<< 1) - $signed({4'b0000, r0_0});

    assign abs_gx_wire = (gx_reg < 0) ? -gx_reg : gx_reg;
    assign abs_gy_wire = (gy_reg < 0) ? -gy_reg : gy_reg;

    assign grad_wire = abs_gx_wire + abs_gy_wire;

    always_ff @(posedge clk) begin
        if (rst) begin
            col          <= '0;
            row          <= '0;
            win_valid    <= 1'b0;
            stage2_valid <= 1'b0;
            valid_out    <= 1'b0;
            pixel_out    <= '0;
            gx_reg       <= '0;
            gy_reg       <= '0;

            r0_0 <= '0; r0_1 <= '0; r0_2 <= '0;
            r1_0 <= '0; r1_1 <= '0; r1_2 <= '0;
            r2_0 <= '0; r2_1 <= '0; r2_2 <= '0;

        end else begin
            valid_out <= 1'b0;

            if (valid_in) begin
                // line buffers: read the old value at this column, then overwrite it.
                // Reading and shifting in the same cycle keeps all three rows
                // in the same column.
                line_buffer1[col] <= pixel_in;
                line_buffer2[col] <= line_buffer1[col];

                // stage 1: shift sliding window
                r0_2 <= r0_1;
                r0_1 <= r0_0;
                r0_0 <= pixel_in;

                r1_2 <= r1_1;
                r1_1 <= r1_0;
                r1_0 <= line_buffer1[col];

                r2_2 <= r2_1;
                r2_1 <= r2_0;
                r2_0 <= line_buffer2[col];

                // The window being loaded this cycle is complete once two full
                // rows and two columns have gone in. Flag it alongside the window.
                win_valid <= (row >= 2) && (col >= 2);

                // stage 2: gradients from the window loaded on the previous valid cycle
                gx_reg       <= gx_wire;
                gy_reg       <= gy_wire;
                stage2_valid <= win_valid;

                // stage 3: magnitude from the gradients registered on the previous valid cycle
                valid_out <= stage2_valid;
                if (grad_wire > 12'd255) begin
                    pixel_out <= 8'd255;
                end else begin
                    pixel_out <= grad_wire[7:0];
                end

                // update counters
                if (16'(col) == image_width - 16'd1) begin
                    col <= '0;
                    row <= row + 1'b1;
                end else begin
                    col <= col + 1'b1;
                end
            end
        end
    end

endmodule