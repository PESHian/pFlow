#!/usr/bin/env python3
"""Builds the Windows tray icons from the Pesh talking-pig mark (one-off; the .ico files are committed).

The mark is the head with its two sound waves, as in Assets/Pesh.ico (the app, Start and Installed
apps icon, kept exactly as first published) and the Mac PeshMark. Handed whole to Windows, the
256 px frame is mostly transparent margin, so the tray showed a tiny head. Here the margins are
cropped and the gap between head and waves closed, so head and waves fill the square: the 32/40/48 px
frames are the original artwork; at 16/20/24 px the head is the original and its two waves are
redrawn as two clean arcs in the waves' own colour (the thin originals blur into one smudge there).
TrayOnLight.ico (a light taskbar) is the mark as is. TrayOnDark.ico (a dark taskbar) adds a thin light
rim around the mark's outline, so the dark head does not sink into a dark taskbar. Usage: tray-icons.py <Assets folder>   (needs Pillow)
"""
import io, math, struct, sys
from PIL import Image, ImageDraw, ImageFilter

assets = sys.argv[1]
SIZES = [16, 20, 24, 32, 40, 48]
WAVE = (186, 160, 255, 255)  # the mean colour of the original waves

def frames(path):
    data = open(path, 'rb').read(); count = struct.unpack('<H', data[4:6])[0]; out = {}
    for i in range(count):
        w, h, _, _, _, _, size, offset = struct.unpack('<BBBBHHII', data[6 + 16 * i:22 + 16 * i])
        out[w or 256] = data[offset:offset + size]
    return out

def write_ico(path, images):
    """images: {size: RGBA Image}; every frame stored as PNG, as Pesh.ico is."""
    entries, blobs = [], []
    offset = 6 + 16 * len(images)
    for size in sorted(images):
        buffer = io.BytesIO(); images[size].save(buffer, 'PNG'); blob = buffer.getvalue()
        entries.append(struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(blob), offset)); blobs.append(blob); offset += len(blob)
    with open(path, 'wb') as f:
        f.write(struct.pack('<HHH', 0, 1, len(images))); f.write(b''.join(entries)); f.write(b''.join(blobs))

mark = Image.open(io.BytesIO(frames(f'{assets}/Pesh.ico')[256])).convert('RGBA')
# The head (without the faint ring's outer tips) and the waves of the 256 px mark.
head, waves = mark.crop((39, 53, 170, 196)), mark.crop((208, 74, 256, 170))

def large():
    """32-48 px: the original head and waves, 6 px apart instead of 21, in a square they fill edge to edge."""
    gap = 6; width = head.width + gap + waves.width; side = max(width, head.height)
    square = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    square.paste(head, ((side - width) // 2, (side - head.height) // 2), head)
    square.paste(waves, ((side - width) // 2 + head.width + gap, (side - waves.height) // 2), waves)
    return square

def small(side=320):
    """16-24 px: the original head at 78% of the height and two clean arcs for the waves, to its right."""
    square = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    height = int(side * 0.78); width = int(head.width * height / head.height)
    face = head.resize((width, height), Image.LANCZOS); square.paste(face, (0, (side - height) // 2), face)
    draw = ImageDraw.Draw(square); stroke = max(1, int(side * 0.075)); cy = side / 2; x0 = width + side * 0.035
    for middle, end, span in ((x0 + side * 0.085, x0 - side * 0.02, 58), (side - stroke * 0.5 - 1, x0 + side * 0.06, 64)):
        radius = (middle - end) / (1 - math.cos(math.radians(span))); cx = middle - radius
        draw.arc((cx - radius, cy - radius, cx + radius, cy + radius), -span, span, fill=WAVE, width=stroke)
    return square

big, little = large(), small()
tray = {s: (little if s <= 24 else big).resize((s, s), Image.LANCZOS) for s in SIZES}
RIM = (236, 236, 236)  # light grey: reads on a dark taskbar, not mistaken for the waves' lilac

def rimmed(image):
    """A one-pixel light ring just outside the head's outline (not around the ears or the waves, which are
    already light), drawn under the mark."""
    alpha = image.getchannel('A').point(lambda a: 255 if a > 96 else 0)
    dark = Image.composite(image.convert('L').point(lambda v: 255 if v < 110 else 0), Image.new('L', image.size, 0), alpha)
    near_head = dark.filter(ImageFilter.MaxFilter(5 if image.width < 32 else 7))
    outside = Image.composite(Image.new('L', image.size, 0), alpha.filter(ImageFilter.MaxFilter(3)), alpha)
    ring = Image.composite(outside, Image.new('L', image.size, 0), near_head)
    out = Image.new('RGBA', image.size, RIM + (0,))
    out.putalpha(ring.point(lambda a: 190 if a else 0))
    out.alpha_composite(image)
    return out

write_ico(f'{assets}/TrayOnDark.ico', {s: rimmed(image) for s, image in tray.items()})
write_ico(f'{assets}/TrayOnLight.ico', tray)
print('wrote TrayOnDark.ico, TrayOnLight.ico from Pesh.ico')
