#!/usr/bin/env python3
"""Draws the app icon (1024x1024) and writes every iOS size.
  python3 tool/make_icon.py        (needs Pillow)
A blue screen with a pointer on it, on a dark ground, with two signal arcs:
a computer you drive from here, over the network. iOS rounds the corners."""
import os
from PIL import Image, ImageDraw, ImageFilter

S = 4 * 1024                      # draw big, shrink: smooth edges
BG_TOP, BG_BOTTOM = (22, 30, 48), (8, 10, 16)
BLUE_TOP, BLUE_BOTTOM = (98, 160, 255), (52, 104, 230)
WHITE = (255, 255, 255)


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def vgradient(size, top, bottom):
    w, h = size
    col = Image.new("RGB", (1, h))
    for y in range(h):
        col.putpixel((0, y), lerp(top, bottom, y / (h - 1)))
    return col.resize((w, h))


def u(v):
    return round(v * S / 1024)


img = vgradient((S, S), BG_TOP, BG_BOTTOM)
d = ImageDraw.Draw(img)

# the screen: a filled rounded rectangle with a slightly lighter bezel
sx0, sy0, sx1, sy1 = u(170), u(250), u(854), u(700)
glow = Image.new("L", (S, S), 0)
ImageDraw.Draw(glow).rounded_rectangle((sx0, sy0, sx1, sy1), radius=u(56), fill=150)
glow = glow.filter(ImageFilter.GaussianBlur(u(60)))
img.paste(Image.new("RGB", (S, S), (60, 110, 230)), (0, 0), glow)
d = ImageDraw.Draw(img)
d.rounded_rectangle((sx0 - u(18), sy0 - u(18), sx1 + u(18), sy1 + u(18)), radius=u(72), fill=(44, 54, 78))
screen = vgradient((sx1 - sx0, sy1 - sy0), BLUE_TOP, BLUE_BOTTOM)
mask = Image.new("L", screen.size, 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, screen.size[0] - 1, screen.size[1] - 1), radius=u(48), fill=255)
img.paste(screen, (sx0, sy0), mask)

# stand
d.rounded_rectangle((u(462), u(716), u(562), u(792)), radius=u(10), fill=(44, 54, 78))
d.rounded_rectangle((u(362), u(786), u(662), u(826)), radius=u(20), fill=(44, 54, 78))

# the pointer, white with a soft shadow, a little right of center
px, py, k = u(470), u(345), u(1)
arrow = [(0, 0), (0, 250), (62, 196), (108, 296), (152, 276), (108, 180), (190, 180)]
pts = [(px + x * k, py + y * k) for x, y in arrow]
shadow = Image.new("L", (S, S), 0)
ImageDraw.Draw(shadow).polygon([(x + u(10), y + u(14)) for x, y in pts], fill=120)
shadow = shadow.filter(ImageFilter.GaussianBlur(u(14)))
img.paste(Image.new("RGB", (S, S), (10, 20, 60)), (0, 0), shadow)
d = ImageDraw.Draw(img)
d.polygon(pts, fill=WHITE)

# two signal arcs above the screen's top-right corner
cx, cy = u(800), u(215)
for r, wdt in ((u(70), u(26)), (u(130), u(26))):
    d.arc((cx - r, cy - r, cx + r, cy + r), start=-150, end=-30, fill=(150, 200, 255), width=wdt)
d.ellipse((cx - u(20), cy - u(20), cx + u(20), cy + u(20)), fill=(150, 200, 255))

icon = img.resize((1024, 1024), Image.LANCZOS)
here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, "..", "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset")
icon.save(os.path.join(here, "icon-1024.png"))
for name in os.listdir(out):
    if name.startswith("Icon-App-") and name.endswith(".png"):
        spec = name[len("Icon-App-"):-4]          # e.g. 20x20@3x, 83.5x83.5@2x
        pt, scale = spec.split("@")
        px_size = round(float(pt.split("x")[0]) * int(scale[:-1]))
        icon.resize((px_size, px_size), Image.LANCZOS).save(os.path.join(out, name))
print("icon written")
