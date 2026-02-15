// This will show up as an error, but it works i promise verilator needs these two lines to work
#include "Vsobel.h" // must match verilog module name with V as the prefix (e.g. module.v = Vmodule.h)
#include "verilated.h"

#include <iostream>
#include <fstream>
#include <vector>
#include <string>

int main(int argc, char** argv) {
    // Input and argument handling
    if (argc < 3) {
        std::cout << "Usage: ./Vsobel input.pgm output.pgm\n";
        return 1;
    }

    std::string input_file = argv[1];
    std::string output_file = argv[2];

    // -----------------------------
    // Load PGM file and parse input
    // -----------------------------
    std::ifstream infile(input_file);
    if (!infile) {
        std::cout << "Failed to open input file\n";
        return 1;
    }
    std::string magic;
    int width, height, maxval;
    infile >> magic;
    infile >> width >> height;
    infile >> maxval;

    std::vector<int> image(width * height);

    // repeat for all rows/cols
    for (int i = 0; i < width * height; i++) {
        infile >> image[i];
    }
    infile.close();

    std::cout << "Loaded image: " << width << "x" << height << "\n";

    // ---------------------------------------------
    // Create instance of the sobel verilator module
    // ---------------------------------------------
    Vsobel* top = new Vsobel; 

    // Set initial states
    top->clk = 0;
    top->rst = 1;
    top->valid_in = 0;
    top->pixel_in = 0;
    
    // reset for a few cycles then release
    for (int i = 0; i < 5; i++) {
        top->clk = !top->clk;
        top->eval();
    }
    top->rst = 0;

    std::vector<int> output(width * height, 0);

    int pixel_index = 0;

    // ---------------------------------
    // Stream image into hardware module
    // ---------------------------------
    for (int i = 0; i < width * height; i++) {
        // pass through 
        top->valid_in = 1;
        top->pixel_in = image[i];

        // One clock cycle
        top->clk = 0;
        top->eval();
        top->clk = 1;
        top->eval();

        if (top->valid_out) {
            output[i] = top->pixel_out;
        }
    }

    delete top;

    // ---------------------
    // Write output PGM file
    // ---------------------
    std::ofstream outfile(output_file);

    outfile << "P2\n";
    outfile << width << " " << height << "\n";
    outfile << "255\n";

    for (int i = 0; i < width * height; i++) {
        outfile << output[i] << " ";
        if ((i + 1) % width == 0) {
            outfile << "\n";
        }
    }

    outfile.close();

    std::cout << "Output written to " << output_file << "\n";

    return 0;
}