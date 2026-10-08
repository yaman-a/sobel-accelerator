# Directories
IN_DIR  := images_in
PGM_DIR := build_pgm
OUT_DIR := images_out
SV_DIR  := build_sv

.PHONY: all sobel process tb test img_tb process_sv uart_tb uart_test uart_img vga_test svga_test cam_test regress clean

# Default target
all: sobel process

# ---------------------------------------------------------------
# C++ testbench flow
# ---------------------------------------------------------------

# Build sobel executable
sobel:
	verilator --cc rtl/sobel.sv --exe sim/main.cpp --build

# Process all images
process:
	mkdir -p "$(PGM_DIR)"
	mkdir -p "$(OUT_DIR)"
	@for file in "$(IN_DIR)"/*; do \
		if [ -f "$$file" ]; then \
			base=$$(basename "$$file"); \
			name=$${base%.*}; \
			safe_name=$$(echo "$$name" | tr ' ' '_'); \
			echo "Processing $$base"; \
			convert "$$file" -auto-orient -strip -colorspace Gray -depth 8 -compress none \
			    -define pgm:format=ascii "$(PGM_DIR)/$$safe_name.pgm"; \
			./obj_dir/Vsobel "$(PGM_DIR)/$$safe_name.pgm" \
			    "$(PGM_DIR)/$${safe_name}_out.pgm"; \
			convert "$(PGM_DIR)/$${safe_name}_out.pgm" \
			    "$(OUT_DIR)/$${safe_name}_sobel.png"; \
		fi; \
	done
	@echo "Done."

# ---------------------------------------------------------------
# Pure SystemVerilog testbench flow (needs Verilator 5 or newer)
# ---------------------------------------------------------------

VERILATOR_SV := verilator --binary --timing --timescale 1ns/1ps -Wno-fatal

# Self-checking regression: generated patterns vs a software Sobel model
tb:
	mkdir -p $(SV_DIR)
	$(VERILATOR_SV) --top-module sobel_tb \
	    rtl/sobel.sv tb/sobel_tb.sv -Mdir $(SV_DIR)/obj

test: tb
	./$(SV_DIR)/obj/Vsobel_tb

# Image pipeline testbench: PGM in, Sobel, PGM out
img_tb:
	mkdir -p $(SV_DIR)
	$(VERILATOR_SV) --top-module sobel_image_tb \
	    rtl/sobel.sv tb/sobel_image_tb.sv -Mdir $(SV_DIR)/img

# Image -> greyscale PGM -> SystemVerilog sim -> PGM -> image, for everything in images_in
process_sv: img_tb
	mkdir -p "$(PGM_DIR)"
	mkdir -p "$(OUT_DIR)"
	@for file in "$(IN_DIR)"/*; do \
		if [ -f "$$file" ]; then \
			base=$$(basename "$$file"); \
			name=$${base%.*}; \
			safe_name=$$(echo "$$name" | tr ' ' '_'); \
			echo "Processing $$base"; \
			convert "$$file" -auto-orient -strip -colorspace Gray -depth 8 -compress none \
			    -define pgm:format=ascii "$(PGM_DIR)/$$safe_name.pgm"; \
			./$(SV_DIR)/img/Vsobel_image_tb \
			    +in="$(PGM_DIR)/$$safe_name.pgm" \
			    +out="$(PGM_DIR)/$${safe_name}_out.pgm" || exit 1; \
			convert "$(PGM_DIR)/$${safe_name}_out.pgm" \
			    "$(OUT_DIR)/$${safe_name}_sobel.png"; \
		fi; \
	done
	@echo "Done."

# ---------------------------------------------------------------
# Basys3 UART design (sobel_uart_top): bit-level testbench
# ---------------------------------------------------------------

UART_SRC := rtl/sobel.sv rtl/uart_rx.sv rtl/uart_tx.sv rtl/fifo_sync.sv rtl/frame_rx.sv rtl/sobel_uart_top.sv

uart_tb:
	mkdir -p $(SV_DIR)
	$(VERILATOR_SV) --top-module sobel_uart_tb \
	    $(UART_SRC) tb/sobel_uart_tb.sv -Mdir $(SV_DIR)/uart

uart_test: uart_tb
	./$(SV_DIR)/uart/Vsobel_uart_tb

# One image through the simulated UART link: make uart_img IMG=images_in/photo.jpg
uart_img: uart_tb
	mkdir -p "$(PGM_DIR)" "$(OUT_DIR)"
	convert "$(IMG)" -auto-orient -strip -colorspace Gray -depth 8 -compress none \
	    -define pgm:format=ascii "$(PGM_DIR)/uart_in.pgm"
	./$(SV_DIR)/uart/Vsobel_uart_tb +in="$(PGM_DIR)/uart_in.pgm" +out="$(PGM_DIR)/uart_out.pgm"
	convert "$(PGM_DIR)/uart_out.pgm" "$(OUT_DIR)/uart_sobel.png"

# VGA timing + test pattern; writes vga_frame.ppm (one captured frame)
vga_test:
	mkdir -p $(SV_DIR)
	$(VERILATOR_SV) --top-module vga_tb rtl/vga_timing.sv rtl/vga_test_top.sv tb/vga_tb.sv -Mdir $(SV_DIR)/vga
	./$(SV_DIR)/vga/Vvga_tb

# Full system: UART in, Sobel, frame buffers, VGA out (captures and checks the VGA pixels)
svga_test:
	mkdir -p $(SV_DIR)
	$(VERILATOR_SV) --top-module sobel_vga_tb rtl/sobel.sv rtl/uart_rx.sv rtl/uart_tx.sv rtl/fifo_sync.sv \
	    rtl/frame_rx.sv rtl/frame_buf.sv rtl/vga_timing.sv rtl/frame_store.sv rtl/sobel_vga_top.sv tb/sobel_vga_tb.sv -Mdir $(SV_DIR)/svga
	./$(SV_DIR)/svga/Vsobel_vga_tb

# Camera design against a behavioural OV7670 (SCCB set-up, pixel capture, Sobel, VGA). Takes about 30 s.
cam_test:
	mkdir -p $(SV_DIR)
	$(VERILATOR_SV) --top-module sobel_cam_tb rtl/sobel.sv rtl/sccb_master.sv rtl/cam_init.sv \
	    rtl/cam_capture.sv rtl/cam_frame_ctl.sv rtl/frame_buf.sv rtl/vga_timing.sv rtl/frame_store.sv \
	    rtl/sobel_cam_core.sv tb/sobel_cam_tb.sv -Mdir $(SV_DIR)/cam
	./$(SV_DIR)/cam/Vsobel_cam_tb

# Every self-checking test in one go (about a minute). Stops at the first failure.
regress: test uart_test vga_test svga_test cam_test
	@echo "All regression tests done."

clean:
	rm -rf obj_dir
	rm -rf "$(PGM_DIR)"
	rm -rf "$(OUT_DIR)"
	rm -rf "$(SV_DIR)"