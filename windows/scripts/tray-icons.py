#!/usr/bin/env python3
"""Builds the Windows tray and small app icons from the Pesh mark (one-off; the .ico files are committed).

The tray needs a solid silhouette: the full mark at 16 px is a 9 px dark head next to faint
sound waves, which is what the owner saw as "tiny". So the head alone fills the frame, as a flat
shape with the pink ears and two eye cut-outs: TrayOnDark.ico (light head, for the dark taskbar),
TrayOnLight.ico (dark head, for the light taskbar), each 16/20/24/32/40/48 px for 100-300% DPI.
Pesh.ico keeps the full mark from 32 px up and gets the outlined head at 16/20/24 (Explorer, the
title bar). Usage: tray-icons.py <Assets folder>   (needs Pillow)
"""
import colorsys, struct, sys
from PIL import Image, ImageDraw, ImageFilter

assets = sys.argv[1]
SIZES = [16, 20, 24, 32, 40, 48]
PINK, LIGHT, DARK = (255, 157, 196, 255), (244, 242, 250, 255), (27, 27, 36, 255)

def frames(path):
    data = open(path, 'rb').read(); count = struct.unpack('<H', data[4:6])[0]; out = {}
    for i in range(count):
        w, h, _, _, _, _, size, offset = struct.unpack('<BBBBHHII', data[6 + 16 * i:22 + 16 * i])
        out[w or 256] = data[offset:offset + size]
    return out

def write_ico(path, images):
    """images: {size: RGBA Image}; every frame stored as PNG, as the original Pesh.ico is."""
    import io
    entries, blobs = [], []
    offset = 6 + 16 * len(images)
    for size in sorted(images):
        buffer = io.BytesIO(); images[size].save(buffer, 'PNG'); blob = buffer.getvalue()
        entries.append(struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(blob), offset)); blobs.append(blob); offset += len(blob)
    with open(path, 'wb') as f:
        f.write(struct.pack('<HHH', 0, 1, len(images))); f.write(b''.join(entries)); f.write(b''.join(blobs))

def head_masks(mark256):
    """The head (columns 22-186, rows 53-195 of the 256 px mark), squared, as a fill mask with the ear and eye regions."""
    head = mark256.crop((22, 53, 187, 196)); W = 165
    canvas = Image.new('RGBA', (W, W), (0, 0, 0, 0)); canvas.paste(head, (0, (W - 143) // 2), head); px = canvas.load()
    mask, ears, eyes = (Image.new('L', (W, W), 0) for _ in range(3)); m, e, y = mask.load(), ears.load(), eyes.load()
    for j in range(W):
        for i in range(W):
            r, g, b, a = px[i, j]
            if a < 90: continue
            m[i, j] = 255
            h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            if s > 0.25 and v > 0.45:
                if (0.78 < h < 0.98 or h < 0.05) and j < W * 0.45: e[i, j] = 255
                elif 0.5 < h < 0.78: y[i, j] = 255
    mask = mask.filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.MinFilter(5))
    inner = mask.filter(ImageFilter.MinFilter(21)); zero = Image.new('L', (W, W), 0)
    ears = Image.composite(Image.composite(ears, zero, mask), zero, inner.point(lambda v: 255 - v))
    # The eyes as two clean ellipses over the detected glow blobs.
    blobs = Image.composite(eyes, zero, inner).filter(ImageFilter.MaxFilter(3)); clean = Image.new('L', (W, W), 0); draw = ImageDraw.Draw(clean)
    for half in ((0, W // 2), (W // 2, W)):
        region = blobs.crop((half[0], 0, half[1], W)).getbbox()
        if region: draw.ellipse((region[0] + half[0], region[1], region[2] + half[0], region[3]), fill=255)
    rim = Image.composite(mask, zero, mask.filter(ImageFilter.MinFilter(13)).point(lambda v: 255 - v))
    return W, mask, ears, clean, rim

def glyph(W, mask, ears, eyes, fill, eye, rim=None):
    g = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    g.paste(Image.new('RGBA', (W, W), fill), (0, 0), mask)
    if rim is not None: g.paste(Image.new('RGBA', (W, W), LIGHT), (0, 0), rim)
    g.paste(Image.new('RGBA', (W, W), PINK), (0, 0), ears)
    g.paste(Image.new('RGBA', (W, W), eye), (0, 0), eyes)
    return g

original = frames(f'{assets}/Pesh.ico')
mark = Image.open(__import__('io').BytesIO(original[256])).convert('RGBA')
W, mask, ears, eyes, rim = head_masks(mark)
on_dark = glyph(W, mask, ears, eyes, LIGHT, DARK)
on_light = glyph(W, mask, ears, eyes, DARK, LIGHT)
outlined = glyph(W, mask, ears, eyes, DARK, LIGHT, rim)
write_ico(f'{assets}/TrayOnDark.ico', {s: on_dark.resize((s, s), Image.LANCZOS) for s in SIZES})
write_ico(f'{assets}/TrayOnLight.ico', {s: on_light.resize((s, s), Image.LANCZOS) for s in SIZES})
app = {s: Image.open(__import__('io').BytesIO(original[s])).convert('RGBA') for s in original if s >= 32}
for s in (16, 20, 24): app[s] = outlined.resize((s, s), Image.LANCZOS)
write_ico(f'{assets}/Pesh.ico', app)
print('wrote TrayOnDark.ico, TrayOnLight.ico, Pesh.ico')
