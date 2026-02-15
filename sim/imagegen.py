import sys
import numpy as np


def write_pgm(filename, image):
    h, w = image.shape
    with open(filename, "w") as f:
        f.write("P2\n")
        f.write(f"{w} {h}\n")
        f.write("255\n")
        for row in image:
            f.write(" ".join(str(int(p)) for p in row))
            f.write("\n")


# ---------------------------
# Test 1: Vertical Split
# ---------------------------
def vertical_split(width, height, filename):
    img = np.zeros((height, width))
    img[:, width // 2:] = 255
    write_pgm(filename, img)


# ---------------------------
# Test 2: Horizontal Split
# ---------------------------
def horizontal_split(width, height, filename):
    img = np.zeros((height, width))
    img[height // 2:, :] = 255
    write_pgm(filename, img)


# ---------------------------
# Test 3: Checkerboard
# ---------------------------
def checkerboard(width, height, filename, block_size=8):
    img = np.zeros((height, width))
    for y in range(height):
        for x in range(width):
            if ((x // block_size) + (y // block_size)) % 2 == 0:
                img[y, x] = 0
            else:
                img[y, x] = 255
    write_pgm(filename, img)


# ---------------------------
# Test 4: Diagonal Line
# ---------------------------
def diagonal(width, height, filename):
    img = np.zeros((height, width))
    for i in range(min(width, height)):
        img[i, i] = 255
    write_pgm(filename, img)


# ---------------------------
# Test 5: Random Noise
# ---------------------------
def random_noise(width, height, filename):
    img = np.random.randint(0, 256, (height, width))
    write_pgm(filename, img)


# ---------------------------
# Main
# ---------------------------
if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: python generate_tests.py width height test_type")
        print("test_type = vertical | horizontal | checker | diagonal | noise")
        sys.exit(1)

    width = int(sys.argv[1])
    height = int(sys.argv[2])
    test_type = sys.argv[3]

    filename = f"{test_type}_{width}x{height}.pgm"

    if test_type == "vertical":
        vertical_split(width, height, filename)
    elif test_type == "horizontal":
        horizontal_split(width, height, filename)
    elif test_type == "checker":
        checkerboard(width, height, filename)
    elif test_type == "diagonal":
        diagonal(width, height, filename)
    elif test_type == "noise":
        random_noise(width, height, filename)
    else:
        print("Unknown test type.")
        sys.exit(1)

    print(f"Generated {filename}")
