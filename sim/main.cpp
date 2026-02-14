#include "Vsobel.h"
#include "verilated.h"
#include <iostream>

int main() {
    // Verilated::commandArgs(argc, argv); 
    // dont actually need commandline args as its boilerplate

    // Create instance of the sobel module
    Vsobel* top = new Vsobel; 

    // Set initial states
    top->clk = 0;
    top->rst = 1;
    top->valid_in = 0;
    top->pixel_in = 0;
    
    // reset for a few cycles
    for (int i = 0; i < 5; i++) {
        top->clk = !top->clk;
        top->eval();
    }

    // Release reset state
    top->rst = 0;

    // Pass through input for 256 cycles
    for (int i = 0; i < 384; i++) {
        // pass through 
        top->valid_in = 1;
        top->pixel_in = i * 20;

        // One clock cycle
        top->clk = 0;
        top->eval();
        top->clk = 1;
        top->eval();

        // now we print the pixel output
        std::cout << "col approx: " << i % 128
        << " row approx: " << i / 128
        << " out: " << (int)top->pixel_out
        << std::endl;
    }

    delete top;
    return 0;
}