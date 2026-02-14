module sobel (
    input wire clk,
    input wire rst,
    input wire valid_in,
    input wire [7:0] pixel_in,
    output reg valid_out,
    output reg [7:0] pixel_out
);
always @(posedge clk) begin
    if (rst) begin
        valid_out <= 0;
        pixel_out <= 0;
    end else begin
        valid_out <= valid_in;
        pixel_out <= pixel_inl // passthrough for the time being
    end
end


endmodule