// Simple dual-port RAM for a frame: one write port, one read port, same clock.
// The read has one clock of latency. Vivado maps this onto block RAM.
module frame_buf #(
    parameter int DEPTH = 76800,        // 320 x 240
    parameter int DW    = 4,
    parameter int AW    = $clog2(DEPTH)
)(
    input  logic          clk,
    input  logic          we,
    input  logic [AW-1:0] waddr,
    input  logic [DW-1:0] wdata,
    input  logic [AW-1:0] raddr,
    output logic [DW-1:0] rdata
);
    (* ram_style = "block" *) logic [DW-1:0] mem [DEPTH];

    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule
