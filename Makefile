# Directories
IN_DIR  := images_in
PGM_DIR := build_pgm
OUT_DIR := images_out

# Default target
all: sobel process

# Build sobel executable
sobel:
	verilator --cc rtl/sobel.v --exe sim/main.cpp --build

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
			convert "$$file" -colorspace Gray -depth 8 -compress none \
			    -define pgm:format=ascii "$(PGM_DIR)/$$safe_name.pgm"; \
			./obj_dir/Vsobel "$(PGM_DIR)/$$safe_name.pgm" \
			    "$(PGM_DIR)/$${safe_name}_out.pgm"; \
			convert "$(PGM_DIR)/$${safe_name}_out.pgm" \
			    "$(OUT_DIR)/$${safe_name}_sobel.png"; \
		fi; \
	done
	@echo "Done."

clean:
	rm -rf obj_dir
	rm -rf "$(PGM_DIR)"
	rm -rf "$(OUT_DIR)"
