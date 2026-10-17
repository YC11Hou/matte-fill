"""Undo the screen-blended bars in a screenshot of Matte running, recovering the frame underneath.

Usage: recon.py shot.png out.png. The bar geometry below is the one in that shot; edit it per shot.
"""
import sys
import numpy as np
from PIL import Image
im = np.asarray(Image.open(sys.argv[1]).convert('RGB')).astype(float)
H, W, _ = im.shape
f = im[300, 50] / 255
band = 45; top = 177; bot = 1270; l = 168; r = 1820
out = im.copy() / 255
s = np.clip((out - f) / (1 - f), 0, 1)
s = np.where(s > 0.002, s + 28 / 255, s * 0)  # undo BarsView.videoBlack
rec = im / 255
mask = np.zeros((H, W), bool)
mask[band:top, :] = True; mask[bot:, :] = True; mask[:, :l] = True; mask[:, r:] = True
rec[mask] = np.clip(s[mask], 0, 1)
rec[:band, :] = 0
Image.fromarray((rec * 255).round().astype(np.uint8)).save(sys.argv[2])
