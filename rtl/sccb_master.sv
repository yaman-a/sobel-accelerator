// SCCB (OV7670's I2C-like control bus) master, write only: one 3-byte write transaction
//   START, 0x42 (device, write), register, data, STOP
// SCCB's 9th bit after each byte is the camera's acknowledge. ack_ok reports whether all
// three were seen, which is a handy check that the camera is wired up and powered.
//
// SCL is driven push-pull (the camera never stretches the clock). SDA is driven by the
// FPGA except during the three acknowledge bits, when sda_oe goes low so the camera can
// pull it down. A weak pull-up on the SDA pin keeps it high otherwise, so no external
// resistors are needed.
//
// One SCL period is 4*DIV clocks: 100 MHz and DIV = 250 gives 100 kHz.
module sccb_master #(
    parameter int DIV = 250
)(
    input  logic       clk,
    input  logic       rst,
    input  logic       start,          // one-clock pulse; ignored while busy
    input  logic [7:0] reg_addr,
    input  logic [7:0] reg_data,
    output logic       busy,
    output logic       done,           // one-clock pulse at the end of a transaction
    output logic       ack_ok,         // valid with done

    output logic       scl,
    output logic       sda_o,
    output logic       sda_oe,
    input  logic       sda_i
);

    localparam logic [7:0] DEV_WRITE = 8'h42;
    localparam int CNT_W = $clog2(2 * DIV + 1);

    typedef enum logic [3:0] {
        S_IDLE, S_START1, S_START2, S_FALL, S_SET, S_HIGH, S_STOP1, S_STOP2, S_STOP3
    } state_t;
    state_t state = S_IDLE;

    logic [CNT_W-1:0] cnt     = '0;
    logic [4:0]       idx     = '0;          // bit number 0..26
    logic [26:0]      sh      = '0;          // bits still to send, next bit at the top
    logic             cur_sda = 1'b1;
    logic             cur_oe  = 1'b1;
    logic             ack_all = 1'b1;

    logic is_ack_slot;
    assign is_ack_slot = (idx == 5'd8) || (idx == 5'd17) || (idx == 5'd26);

    // synchronise the camera's SDA
    logic sda_m = 1'b1, sda_s = 1'b1;
    always_ff @(posedge clk) begin
        sda_m <= sda_i;
        sda_s <= sda_m;
    end

    // line levels follow the state
    always_comb begin
        scl    = 1'b1;
        sda_o  = cur_sda;
        sda_oe = cur_oe;
        case (state)
            S_IDLE, S_START1:  begin scl = 1'b1; sda_o = 1'b1; sda_oe = 1'b1; end
            S_START2:          begin scl = 1'b1; sda_o = 1'b0; sda_oe = 1'b1; end
            S_FALL, S_SET:     begin scl = 1'b0; end
            S_HIGH:            begin scl = 1'b1; end
            S_STOP1:           begin scl = 1'b0; sda_o = 1'b0; sda_oe = 1'b1; end
            S_STOP2:           begin scl = 1'b1; sda_o = 1'b0; sda_oe = 1'b1; end
            S_STOP3:           begin scl = 1'b1; sda_o = 1'b1; sda_oe = 1'b1; end
            default: ;
        endcase
    end

    assign busy = (state != S_IDLE);

    always_ff @(posedge clk) begin
        done <= 1'b0;

        if (rst) begin
            state   <= S_IDLE;
            cnt     <= '0;
            idx     <= '0;
            cur_sda <= 1'b1;
            cur_oe  <= 1'b1;
            ack_all <= 1'b1;
            ack_ok  <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    cnt <= '0;
                    if (start) begin
                        sh      <= {DEV_WRITE, 1'b1, reg_addr, 1'b1, reg_data, 1'b1};
                        idx     <= '0;
                        ack_all <= 1'b1;
                        state   <= S_START1;
                    end
                end

                S_START1: begin                       // both lines high, settle
                    if (cnt == CNT_W'(DIV - 1)) begin
                        cnt <= '0; state <= S_START2;
                    end else cnt <= cnt + 1'b1;
                end

                S_START2: begin                       // SDA falls while SCL is high: START
                    if (cnt == CNT_W'(DIV - 1)) begin
                        cnt     <= '0;
                        cur_sda <= 1'b0;
                        cur_oe  <= 1'b1;
                        state   <= S_FALL;
                    end else cnt <= cnt + 1'b1;
                end

                S_FALL: begin                         // SCL low, SDA still holds the old bit
                    if (cnt == CNT_W'(DIV - 1)) begin
                        cnt     <= '0;
                        cur_sda <= sh[26];
                        cur_oe  <= !is_ack_slot;      // release SDA for the acknowledge bit
                        state   <= S_SET;
                    end else cnt <= cnt + 1'b1;
                end

                S_SET: begin                          // SCL low, new bit on SDA
                    if (cnt == CNT_W'(DIV - 1)) begin
                        cnt <= '0; state <= S_HIGH;
                    end else cnt <= cnt + 1'b1;
                end

                S_HIGH: begin                         // SCL high; sample the acknowledge late
                    if (is_ack_slot && cnt == CNT_W'(2 * DIV - 2) && sda_s) ack_all <= 1'b0;
                    if (cnt == CNT_W'(2 * DIV - 1)) begin
                        cnt <= '0;
                        if (idx == 5'd26) begin
                            state <= S_STOP1;
                        end else begin
                            idx   <= idx + 1'b1;
                            sh    <= {sh[25:0], 1'b0};
                            state <= S_FALL;
                        end
                    end else cnt <= cnt + 1'b1;
                end

                S_STOP1: begin
                    if (cnt == CNT_W'(DIV - 1)) begin
                        cnt <= '0; state <= S_STOP2;
                    end else cnt <= cnt + 1'b1;
                end

                S_STOP2: begin
                    if (cnt == CNT_W'(DIV - 1)) begin
                        cnt <= '0; state <= S_STOP3;
                    end else cnt <= cnt + 1'b1;
                end

                S_STOP3: begin                        // SDA rises while SCL is high: STOP
                    if (cnt == CNT_W'(DIV - 1)) begin
                        cnt     <= '0;
                        cur_sda <= 1'b1;
                        cur_oe  <= 1'b1;
                        ack_ok  <= ack_all;
                        done    <= 1'b1;
                        state   <= S_IDLE;
                    end else cnt <= cnt + 1'b1;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
