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

    

    // column and row counters
    reg [6:0] col;
    reg [15:0] row;

    // first line buffer (1 row delay)
    reg [7:0] line_buffer1 [0:WIDTH-1];
    reg [7:0] prev_row_pixel;

    // second line buffer
    reg [7:0] line_buffer2 [0:WIDTH-1];
    reg [7:0] prev2_row_pixel;

    // 3x3 window shift registers
    reg [7:0] r0_0, r0_1, r0_2;
    reg [7:0] r1_0, r1_1, r1_2;
    reg [7:0] r2_0, r2_1, r2_2;

    // sobel kernel declarations
    reg signed [11:0] gx;
    reg signed [11:0] gy;
    reg signed [11:0] abs_gx;
    reg signed [11:0] abs_gy;
    reg [11:0] grad_mag;



always @(posedge clk) begin
    if (rst) begin
        col <= 0;
        row <= 0;
        valid_out <= 0;
        pixel_out <= 0;

        r0_0 <= 0; r0_1 <= 0; r0_2 <= 0;
        r1_0 <= 0; r1_1 <= 0; r1_2 <= 0;
        r2_0 <= 0; r2_1 <= 0; r2_2 <= 0;


    end else begin
        if (valid_in) begin

            // read prev row pixel before overwriting
            // vertical pipeline (top to bottom)
            prev_row_pixel <= line_buffer1[col];
            line_buffer1[col] <= pixel_in;

            prev2_row_pixel <= line_buffer2[col];
            line_buffer2[col] <= prev_row_pixel;

            // horizontal shift (bottom row)
            r0_2 <= r0_1;
            r0_1 <= r0_0;
            r0_0 <= pixel_in;

            // horizontal shift (middle row)
            r1_2 <= r1_1;
            r1_1 <= r1_0;
            r1_0 <= prev_row_pixel;

            // horizontal shift (top row)
            r2_2 <= r2_1;
            r2_1 <= r2_0;
            r2_0 <= prev2_row_pixel;

            // increment column
            if (col == 7'd127) begin
                col <= 0;
                row <= row + 1;
            end else begin
                col <= col + 1;
            end

            // output XOR of rightmost column of the 3x3
            
            if (row >= 2 && col >= 2) begin
                gx <= -$signed({4'b0000,r2_2}) + $signed({4'b0000,r2_0})
                    -($signed({4'b0000,r1_2}) <<< 1) + ($signed({4'b0000,r1_0}) <<< 1)
                    -$signed({4'b0000,r0_2}) + $signed({4'b0000,r0_0});

                gy <= $signed({4'b0000,r2_2}) + ($signed({4'b0000,r2_1}) <<< 1)
                    + $signed({4'b0000,r2_0}) - $signed({4'b0000,r0_2}) 
                    - ($signed({4'b0000,r0_1}) <<< 1) - $signed({4'b0000,r0_0});


                abs_gx <= (gx < 0) ? -gx : gx;
                abs_gy <= (gy < 0) ? -gy : gy;

                grad_mag <= abs_gx + abs_gy;

                // clamp to 8 bit
                if (grad_mag > 12'd255) begin
                    pixel_out <= 8'd255;
                end else begin
                    pixel_out <= grad_mag[7:0];
                end

                valid_out <= 1;
            end else begin
                pixel_out <= 0;
                valid_out <= 0;
            end

        end else begin
            valid_out <= 0;
        end
    end
end


endmodule