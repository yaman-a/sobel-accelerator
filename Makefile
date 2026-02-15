# -------- CONFIG --------
SIM        = obj_dir/Vsobel
INPUT_DIR  = images_in
PGM_DIR    = build_pgm
OUTPUT_DIR = images_out

# Supported extensions
EXTS = jpg png jpeg

# Find input files
IMAGES := $(foreach ext,$(EXTS),$(wildcard $(INPUT_DIR)/*.$(ext)))

# Extract base names
BASE := $(notdir $(basename $(IMAGES)))

# Final output targets
OUT_IMAGES := $(addprefix $(OUTPUT_DIR)/,$(addsuffix _sobel.png,$(BASE)))

# -------- DEFAULT TARGET --------
all: build $(OUT_IMAGES)

# -------- BUILD --------
build:
	verilator --cc rtl/sobel.v --exe sim/main.cpp --build

# -------- MAIN RULE --------
$(OUTPUT_DIR)/%_sobel.png:
	mkdir -p $(PGM_DIR)
	mkdir -p $(OUTPUT_DIR)

	# Find matching input file automatically
	input_file=$$(ls $(INPUT_DIR)/$*.*); \
	echo "Processing $$input_file"; \
	convert $$input_file -colorspace Gray -depth 8 -compress none -define pgm:format=ascii $(PGM_DIR)/$*.pgm; \
	./$(SIM) $(PGM_DIR)/$*.pgm $(PGM_DIR)/$*_out.pgm; \
	convert $(PGM_DIR)/$*_out.pgm $@

# -------- CLEAN --------
clean:
	rm -rf obj_dir
	rm -rf $(PGM_DIR)
	rm -rf $(OUTPUT_DIR)
