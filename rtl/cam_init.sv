// Writes the OV7670 start-up configuration over SCCB, then stops.
//
// Result: 320x240 (QVGA), YUV422 with the brightness (Y) byte second (U Y V Y), full 00..FF range,
// camera auto exposure / gain / white balance left at their power-on defaults.
// Setting test_pattern (read while the table runs, i.e. just after reset) makes the camera
// output its built-in colour bars, which checks the whole capture path without a picture.
//
// The table is the list at the bottom. Entry {FE, n} waits n milliseconds, {FF, FF} ends.
module cam_init #(
    parameter int UNIT = 100_000,       // clocks per millisecond
    parameter int DIV  = 250            // SCCB: clocks per quarter SCL period
)(
    input  logic clk,
    input  logic rst,
    input  logic test_pattern,
    input  logic darker,                // extra-dark exposure profile (read at reset)

    output logic scl,
    output logic sda_o,
    output logic sda_oe,
    input  logic sda_i,

    output logic done,                  // the whole table has been written
    output logic ack_fail               // sticky: some transaction was not acknowledged
);

    function automatic logic [15:0] rom(input int i, input logic tp, input logic dk);
        case (i)
            0:  rom = {8'hFE, 8'd30};                       // wait 30 ms after power-up
            1:  rom = {8'h12, 8'h80};                       // COM7: software reset
            2:  rom = {8'hFE, 8'd10};                       // wait for the reset
            3:  rom = {8'h11, 8'h01};                       // CLKRC: internal clock divider /2
            4:  rom = {8'h3A, 8'h04};                       // TSLB: bit 2 = Y last (U Y V Y), as seen on the board
            5:  rom = {8'h12, 8'h10};                       // COM7: QVGA, YUV
            6:  rom = {8'h40, 8'hC0};                       // COM15: full range 00..FF
            7:  rom = {8'h3D, 8'hC0};                       // COM13: gamma on, UV saturation auto
            8:  rom = {8'h0C, 8'h04};                       // COM3: enable down-sampling
            9:  rom = {8'h3E, 8'h19};                       // COM14: scaling, pixel clock /2
            10: rom = {8'h70, 8'h3A};                       // SCALING_XSC (bit 7: test pattern)
            11: rom = {8'h71, tp ? 8'hB5 : 8'h35};          // SCALING_YSC (bit 7: colour bars)
            12: rom = {8'h72, 8'h11};                       // down-sample by 2 in x and y
            13: rom = {8'h73, 8'hF1};                       // pixel clock divider
            14: rom = {8'hA2, 8'h02};                       // pixel clock delay
            15: rom = {8'h17, 8'h16};                       // HSTART
            16: rom = {8'h18, 8'h04};                       // HSTOP
            17: rom = {8'h32, 8'h24};                       // HREF
            18: rom = {8'h19, 8'h02};                       // VSTART
            19: rom = {8'h1A, 8'h7A};                       // VSTOP
            20: rom = {8'h03, 8'h0A};                       // VREF
            21: rom = {8'h14, 8'h18};                       // COM9: AGC ceiling 4x (power-on default 16x is too bright indoors)
            22: rom = {8'h24, dk ? 8'h30 : 8'h48};          // AEW: auto exposure target, upper bound (default 75)
            23: rom = {8'h25, dk ? 8'h20 : 8'h38};          // AEB: auto exposure target, lower bound (default 63)
            24: rom = {8'h55, dk ? 8'hA0 : 8'h90};          // BRIGHT: sign-magnitude, 0x90 = -16, 0xA0 = -32
            default: rom = {8'hFF, 8'hFF};
        endcase
    endfunction

    typedef enum logic [2:0] {S_FETCH, S_DECODE, S_SEND, S_WAIT, S_DELAY, S_DONE} state_t;
    state_t state = S_FETCH;

    logic [5:0]  idx = '0;
    logic [15:0] entry = '0;
    logic [31:0] delay_cnt = '0;

    logic       sc_start = 1'b0;
    logic       sc_busy, sc_done, sc_ack_ok;

    sccb_master #(.DIV(DIV)) u_sccb (
        .clk(clk), .rst(rst),
        .start(sc_start), .reg_addr(entry[15:8]), .reg_data(entry[7:0]),
        .busy(sc_busy), .done(sc_done), .ack_ok(sc_ack_ok),
        .scl(scl), .sda_o(sda_o), .sda_oe(sda_oe), .sda_i(sda_i)
    );

    initial begin
        done     = 1'b0;
        ack_fail = 1'b0;
    end

    always_ff @(posedge clk) begin
        sc_start <= 1'b0;

        if (rst) begin
            state     <= S_FETCH;
            idx       <= '0;
            done      <= 1'b0;
            ack_fail  <= 1'b0;
            delay_cnt <= '0;
        end else begin
            case (state)
                S_FETCH: begin
                    entry <= rom(int'(idx), test_pattern, darker);
                    state <= S_DECODE;
                end

                S_DECODE: begin
                    if (entry[15:8] == 8'hFF) begin
                        state <= S_DONE;
                    end else if (entry[15:8] == 8'hFE) begin
                        delay_cnt <= 32'(entry[7:0]) * 32'(UNIT);
                        state     <= S_DELAY;
                    end else begin
                        sc_start <= 1'b1;
                        state    <= S_SEND;
                    end
                end

                S_SEND: state <= S_WAIT;              // let busy rise

                S_WAIT: begin
                    if (sc_done) begin
                        if (!sc_ack_ok) ack_fail <= 1'b1;
                        idx   <= idx + 1'b1;
                        state <= S_FETCH;
                    end
                end

                S_DELAY: begin
                    if (delay_cnt == 32'd0) begin
                        idx   <= idx + 1'b1;
                        state <= S_FETCH;
                    end else begin
                        delay_cnt <= delay_cnt - 1'b1;
                    end
                end

                S_DONE: done <= 1'b1;

                default: state <= S_FETCH;
            endcase
        end
    end

    logic unused;
    assign unused = &{1'b0, sc_busy};

endmodule
