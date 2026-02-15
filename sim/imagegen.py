import numpy as np
from PIL import Image

img = np.zeros((128,128), dtype=np.uint8)
img[:, :64] = 0
img[:, 64:] = 255

Image.fromarray(img).save("images/edge.pgm")