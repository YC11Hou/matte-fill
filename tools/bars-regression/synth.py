"""Synthetic black-bar cases for `matte-fill --analyze`: screen-sized shots (2000x1301, 45 px notch band)."""
import os
import numpy as np
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "samples")
os.makedirs(OUT, exist_ok=True)
W, H, band = 2000, 1301, 45
def picture(w, h, seed):
    r = np.random.default_rng(seed)
    small = r.uniform(40, 200, (h // 40 + 2, w // 40 + 2, 3)).astype(np.uint8)
    p = np.asarray(Image.fromarray(small).resize((w, h), Image.BICUBIC)).astype(int)
    p += r.integers(-12, 12, (h, w, 1))
    return np.clip(p, 0, 255).astype(np.uint8)
def canvas(): return np.zeros((H, W, 3), np.uint8)
def save(a, n): Image.fromarray(a).save(os.path.join(OUT, n))
T = 230                                          # letterbox bar in px (of 2000-wide shot)
def letter(seed=2):
    a = canvas(); a[band + T:H - T] = picture(W, H - band - 2 * T, seed); return a
lb = letter(); save(lb, 's_letter.png'); save(letter(5), 's_letter2.png')
# Esc hint box (flat) + white title text in the top bar
d = Image.fromarray(lb.copy()); g = ImageDraw.Draw(d)
g.rounded_rectangle((800, 100, 1200, 170), 18, fill=(70, 70, 70)); g.text((900, 125), "Press Esc to exit", fill=(255, 255, 255))
save(np.asarray(d), 's_letter_esc.png')
# dark scene inside the letterbox: picture nearly black, one bright patch mid-frame
ds = lb.copy(); ds[band + T:H - T] = (ds[band + T:H - T] * 0.12).astype(np.uint8); ds[600:800, 900:1100] = 200; save(ds, 's_letter_dark.png')
# dark top/bottom of the picture (night sky) with a lit building touching the true edge on 12% of width
dt = lb.copy()
for y0, y1 in ((band + T, band + T + 200), (H - T - 200, H - T)):
    dt[y0:y1] = (dt[y0:y1] * 0.1).astype(np.uint8); dt[y0:y1, 1400:1640] = lb[y0:y1, 1400:1640]
save(dt, 's_letter_darktop.png')
# same but no lit patch at all (truly indistinguishable; any answer acceptable)
dn = lb.copy()
for y0, y1 in ((band + T, band + T + 200), (H - T - 200, H - T)): dn[y0:y1] = (dn[y0:y1] * 0.1).astype(np.uint8)
save(dn, 's_letter_darkband.png')
# full frame, and full frame whose top/bottom 130px are dark except a lit patch touching the screen edge (the bug)
ff = canvas(); ff[band:] = picture(W, H - band, 3); save(ff, 's_full.png')
fd = ff.copy()
for y0, y1 in ((band, band + 130), (H - 130, H)): fd[y0:y1] = (fd[y0:y1] * 0.1).astype(np.uint8); fd[y0:y1, 1420:1600] = ff[y0:y1, 1420:1600]
save(fd, 's_full_darkedge.png')
fa = fd.copy()
for y0, y1 in ((band, band + 130), (H - 130, H)): fa[y0:y1, 1420:1600] = (fa[y0:y1, 1420:1600] * 0.1).astype(np.uint8)
save(fa, 's_full_darkall.png')
# pillarbox 4:3 with a flat white icon in the right bar, picture's top dark like the bug
pb = canvas(); pb[band:, 168:1820] = picture(1652, H - band, 4)
pb[band:band + 130, 168:1820] = (pb[band:band + 130, 168:1820] * 0.1).astype(np.uint8); pb[band:band + 130, 1420:1600] = picture(180, 130, 9)
d = Image.fromarray(pb); ImageDraw.Draw(d).rounded_rectangle((1885, 1100, 1950, 1160), 12, fill=(235, 235, 235)); save(np.asarray(d), 's_pillar_icon.png')
# The system's full-screen exit (and entry) animation: the app's picture shrinks toward a window over a dark
# desktop, one frame per 1/30 s. Its edges move every frame, so no bar may ever be adopted from it.
wall = np.clip(14 + np.linspace(0, 10, H)[:, None, None] + np.random.default_rng(7).integers(0, 4, (H, W, 1)), 0, 255).astype(np.uint8)
movie = picture(W, H - band, 11)
for k in range(15):
    s = 1 - 0.45 * k / 14
    w_, h_ = int(W * s), int((H - band) * s)
    a = np.broadcast_to(wall, (H, W, 3)).copy(); a[:band] = 0
    x0, y0 = (W - w_) // 2, band + (H - band - h_) // 2
    a[y0:y0 + h_, x0:x0 + w_] = np.asarray(Image.fromarray(movie).resize((w_, h_)))
    save(a, f's_exit_{k:02d}.png'); save(a, f's_enter_{14 - k:02d}.png')
