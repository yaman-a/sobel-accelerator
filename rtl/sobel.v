module sobel #(
    parameter WIDTH = 128
)(
    input wire clk,
    input wire rst,
    input wire valid_in,
    input wire [7:0] pixel_in,
    output reg valid_out,
    output reg [7:0] pixel_out
);

    localparam COL_BITS = $clog2(WIDTH);

    // column and row counters
    reg [COL_BITS-1:0] col;
    reg [15:0] row;

    // line buffers
    reg [7:0] line_buffer1 [0:WIDTH-1];
    reg [7:0] prev_row_pixel;
    reg [7:0] line_buffer2 [0:WIDTH-1];
    reg [7:0] prev2_row_pixel;

    // 3x3 window shift registers
    reg [7:0] r0_0, r0_1, r0_2;
    reg [7:0] r1_0, r1_1, r1_2;
    reg [7:0] r2_0, r2_1, r2_2;

    // sobel combinational maths
    wire signed [11:0] gx_wire;
    wire signed [11:0] gy_wire;
    wire signed [11:0] abs_gx_wire;
    wire signed [11:0] abs_gy_wire;
    wire [11:0] grad_wire;

    assign gx_wire =
        -$signed({4'b0000,r2_2}) + $signed({4'b0000,r2_0})
        - ($signed({4'b0000,r1_2}) <<< 1) + ($signed({4'b0000,r1_0}) <<< 1)
        - $signed({4'b0000,r0_2}) + $signed({4'b0000,r0_0});

    assign gy_wire =
          $signed({4'b0000,r2_2}) + ($signed({4'b0000,r2_1}) <<< 1)
        +  $signed({4'b0000,r2_0}) -  $signed({4'b0000,r0_2})
        - ($signed({4'b0000,r0_1}) <<< 1) -  $signed({4'b0000,r0_0});

    assign abs_gx_wire = (gx_wire < 0) ? -gx_wire : gx_wire;
    assign abs_gy_wire = (gy_wire < 0) ? -gy_wire : gy_wire;

    assign grad_wire = abs_gx_wire + abs_gy_wire;

// main sequence block
always @(posedge clk) begin
    if (rst) begin
        col <= 0;
        row <= 0;
        valid_out <= 0;
        pixel_out <= 0;

        r0_0 <= 0; r0_1 <= 0; r0_2 <= 0;
        r1_0 <= 0; r1_1 <= 0; r1_2 <= 0;
        r2_0 <= 0; r2_1 <= 0; r2_2 <= 0;

    end else if (valid_in) begin
        // read from buffers first
        prev_row_pixel  <= line_buffer1[col];
        prev2_row_pixel <= line_buffer2[col];

        // write to buffers after using prev values
        line_buffer1[col] <= pixel_in;
        line_buffer2[col] <= prev_row_pixel;

        // shift sliding window
        r0_2 <= r0_1;
        r0_1 <= r0_0;
        r0_0 <= pixel_in;

        r1_2 <= r1_1;
        r1_1 <= r1_0;
        r1_0 <= prev_row_pixel;

        r2_2 <= r2_1;
        r2_1 <= r2_0;
        r2_0 <= prev2_row_pixel;   

        //update counter
        if (col == COL_BITS'(WIDTH-1)) begin
            col <= 0;
            row <= row + 1;
        end else begin 
            col <= col + 1;
        end

        // sobel output (only if window is valid)
        if (row >= 2 && col >= 2) begin
            valid_out <= 1;
            if (grad_wire > 12'd255)
                pixel_out <= 8'd255;
            else
                pixel_out <= grad_wire[7:0];

        end else begin
            valid_out <= 0;
        end


    end
end


endmodule