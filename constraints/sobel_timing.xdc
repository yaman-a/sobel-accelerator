## sobel_timing.xdc
##
## Timing constraint for synthesising and implementing sobel.sv on its own.
##
## The Basys3 oscillator runs at 100 MHz, which is a 10 ns period. This tells
## Vivado what clock the design must meet, so the timing report can say
## whether the Sobel arithmetic fits in one cycle.
##
## No input or output delays are set on purpose. Without them Vivado only
## checks register to register paths, which is exactly what we want to
## measure here. The IO pins have no board connection yet, so IO timing
## would be meaningless.

create_clock -period 10.000 -name sys_clk [get_ports clk]

## To try other clocks, change the period:
##   50 MHz  -> 20.000
##   25 MHz  -> 40.000   (the VGA pixel clock, about 25.175 MHz)
