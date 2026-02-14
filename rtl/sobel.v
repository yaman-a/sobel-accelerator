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
    reg [15:0] col;
    reg [15:0] row;

always @(posedge clk) begin
    if (rst) begin
        valid_out <= 0;
        pixel_out <= 0;
        valid_out <= 0;
        pixel_out <= 0;
    end else begin
        if (valid_in) begin
            // increment column
            if (col == WIDTH - 1) begin
                col <= 0;
                row <= row + 1;
            end else begin
                col <= col + 1;
            end

            // we're still doing a passthrough for now
            pixel_out <= pixel_in;
            valid_out <= 1;
        end else begin
            valid_out <= 0;
        end
    end
end


endmodule