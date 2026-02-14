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
    reg [6:0] col; // 7 bits is fine for 128
    reg [15:0] row;

    // first line buffer (1 row delay)
    reg [7:0] line_buffer1 [0:WIDTH-1];
    reg [7:0] prev_row_pixel;


always @(posedge clk) begin
    if (rst) begin
        col <= 0;
        row <= 0;
        valid_out <= 0;
        pixel_out <= 0;
        prev_row_pixel <= 0;

    end else begin
        if (valid_in) begin

            // read prev row pixel before overwriting
            prev_row_pixel <= line_buffer1[col];

            // store current pixel into buffer
            line_buffer1[col] <= pixel_in;

            // increment column
            if (col == 7'd127) begin
                col <= 0;
                row <= row + 1;
            end else begin
                col <= col + 1;
            end

            // output previous row pixel for now
            pixel_out <= prev_row_pixel;
            valid_out <= 1;
        end else begin
            valid_out <= 0;
        end
    end
end


endmodule