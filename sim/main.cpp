#include "Vsobel.h"
#include "verilated.h"

#include <iostream>
#include <fstream>
#include <vector>
#include <string>

int main(int argc, char** argv) {
    if (argc < 3) {
        std::cout << "Usage: ./Vsobel input.pgm output.pgm\n";
        return 1;
    }

    std::string input_file = argv[1];
    std::string output_file = argv[2];

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

    for (int i = 0; i < width * height; i++) {
        infile >> image[i];
    }
    infile.close();

    std::cout << "Loaded image: " << width << "x" << height << "\n";

    Vsobel* top = new Vsobel;
    top->image_width = width;

    top->clk = 0;
    top->rst = 1;
    top->valid_in = 0;
    top->pixel_in = 0;

    for (int i = 0; i < 5; i++) {
        top->clk = !top->clk;
        top->eval();
    }
    top->rst = 0;

    std::vector<int> output(width * height, 0);

    // The module has a latency of (width + 3) clocks: the result for the window
    // centred on pixel n appears on clock edge n + width + 3. Run a few
    // extra clocks after the last pixel to collect the final results, and store
    // each result at the position of its centre pixel.
    const int total_clocks = width * height + 3;
    for (int i = 0; i < total_clocks; i++) {
        top->valid_in = 1;
        top->pixel_in = (i < width * height) ? image[i] : 0;

        top->clk = 0;
        top->eval();
        top->clk = 1;
        top->eval();

        if (top->valid_out) {
            int centre = i - (width + 3);
            if (centre >= 0 && centre < width * height) {
                output[centre] = top->pixel_out;
            }
        }
    }

    delete top;

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