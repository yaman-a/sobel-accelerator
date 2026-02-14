#include "Vsobel.h"
#include "verilated.h"
#include <iostream>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    Vsobel* top = new Vsobel;

    top->clk = 0;
    top->rst = 1;
    top->valid_in = 0;
    top->pixel_in = 0;
    
    // reset for a few cycles
    for (int i = 0; i < 5; i++) {
        top->clk = !top->clk;
        top->eval();
    }


    top->rst = 0;

    for (int i = 0; i < 5; i++) {
        top->valid_in = 1;
        top->pixel_in = i * 20;

        top->clk = 0;
        top->eval();
        top->clk = 1;
        top->eval();

        std::cout << "output: " << (int)top->pixel_out << std::endl;
    }

    delete top;
    return 0;
}