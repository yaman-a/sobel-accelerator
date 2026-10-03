// Small synchronous FIFO with a first-word-fall-through read side:
// dout always shows the oldest entry, valid whenever empty is low.
// Writes while full are dropped (the caller watches full to detect that).
module fifo_sync #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 64          // power of two
)(
    input  logic             clk,
    input  logic             rst,
    input  logic             push,
    input  logic [WIDTH-1:0] din,
    input  logic             pop,
    output logic [WIDTH-1:0] dout,
    output logic             empty,
    output logic             full
);

    localparam int AW = $clog2(DEPTH);

    logic [WIDTH-1:0] mem [DEPTH];
    logic [AW:0]      wr_ptr = '0;    // one extra bit tells full from empty
    logic [AW:0]      rd_ptr = '0;

    assign empty = (wr_ptr == rd_ptr);
    assign full  = (wr_ptr[AW] != rd_ptr[AW]) && (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]);
    assign dout  = mem[rd_ptr[AW-1:0]];

    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
        end else begin
            if (push && !full) begin
                mem[wr_ptr[AW-1:0]] <= din;
                wr_ptr              <= wr_ptr + 1'b1;
            end
            if (pop && !empty) begin
                rd_ptr <= rd_ptr + 1'b1;
            end
        end
    end

endmodule
