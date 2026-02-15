import numpy as np

img = np.random.randint(0,256,(128,128),dtype=np.uint8)

with open("noise.pgm", "w") as f:
    f.write("P2\n128 128\n255\n")
    for row in img:
        f.write(" ".join(map(str,row)) + "\n")
