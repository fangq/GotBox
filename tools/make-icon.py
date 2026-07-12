#!/usr/bin/env python3
"""Generate the GotBox application icon (an isometric box in the brand green).

Produces, under assets/:
  - gotbox.ico            multi-size Windows/embedded icon (MAINICON)
  - icons/<N>x<N>/gotbox.png   hicolor-theme PNGs for Linux desktop integration

Run from the repo root:  python3 tools/make-icon.py
Requires Pillow (PIL).
"""

import os
import struct
from PIL import Image, ImageDraw

# brand palette (matches the "synced" green used by the tray status dots)
TOP   = (88, 214, 141)   # #58d68d  light  (top face)
LEFT  = (46, 204, 113)   # #2ecc71  mid    (left face)
RIGHT = (34, 153, 84)    # #229954  dark   (right face)
EDGE  = (20, 83, 45)     # #14532d  outline
TAPE  = (241, 243, 244)  # #f1f3f4  packing-tape highlight

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "assets")
MASTER = 1024            # render big, then downscale with LANCZOS for crispness
MARGIN = 0.09            # inset so the G stroke isn't clipped at the edges

# Normalized isometric-cube vertices, lifted from the assets/icons/gbox.svg
# mockup. The three faces are shaded from the brand green; the "G" is traced
# along the cube's own edges in a constant light tone (see GEDGES).
V = {"top": (0.50, 0.00), "ul": (0.00, 0.25), "ur": (1.00, 0.25),
     "c":   (0.50, 0.50), "ll": (0.00, 0.75), "lr": (1.00, 0.75),
     "bot": (0.50, 1.00)}
FACES = [("top", ["top", "ur", "c", "ul"]),
         ("left", ["ul", "c", "bot", "ll"]),
         ("right", ["c", "ur", "lr", "bot"])]
# The G: walk the silhouette top->ul->ll->bot->lr->ur (skipping the top->ur edge,
# which leaves the G's mouth), then ur->c as the inward tongue.
GEDGES = [("top", "ul"), ("ul", "ll"), ("ll", "bot"),
          ("bot", "lr"), ("lr", "ur"), ("ur", "c")]


def render(n):
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    def P(k):
        x, y = V[k]
        s = 1 - 2 * MARGIN
        return ((MARGIN + x * s) * n, (MARGIN + y * s) * n)

    face_fill = {"top": TOP, "left": LEFT, "right": RIGHT}
    for name, verts in FACES:
        d.polygon([P(k) for k in verts], fill=face_fill[name])

    # the constant "G" outline traced along the box edges (round joins/caps)
    ew = max(1, int(n * 0.05))
    for a, b in GEDGES:
        d.line([P(a), P(b)], fill=TAPE, width=ew, joint="curve")
    r = ew * 0.5
    for k in {e for pair in GEDGES for e in pair}:
        x, y = P(k)
        d.ellipse([x - r, y - r, x + r, y + r], fill=TAPE)

    return img


def render_badge(n, kind):
    """A small status badge for a Windows Explorer icon overlay: a filled disc
    with a white glyph. kind is 'synced' | 'modified' | 'conflict'. Rendered big
    then downscaled by write_ico for crisp small overlays."""
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    fill = {"synced": LEFT, "modified": (243, 156, 18),   # amber
            "conflict": (231, 76, 60)}[kind]              # red
    pad = n * 0.06
    ew = max(1, int(n * 0.05))
    d.ellipse([pad, pad, n - pad, n - pad], fill=fill, outline=EDGE, width=ew)
    W = (255, 255, 255)
    gw = max(1, int(n * 0.11))
    if kind == "synced":                                  # check mark
        d.line([(n * 0.30, n * 0.52), (n * 0.44, n * 0.66), (n * 0.72, n * 0.34)],
               fill=W, width=gw, joint="curve")
    elif kind == "modified":                              # solid dot
        r = n * 0.15
        d.ellipse([n * 0.5 - r, n * 0.5 - r, n * 0.5 + r, n * 0.5 + r], fill=W)
    else:                                                 # exclamation mark
        d.line([(n * 0.5, n * 0.28), (n * 0.5, n * 0.58)], fill=W, width=gw)
        r = n * 0.075
        d.ellipse([n * 0.5 - r, n * 0.70 - r, n * 0.5 + r, n * 0.70 + r], fill=W)
    return img


def _dib(img):
    """Uncompressed 32-bit BGRA DIB for one ICO entry (XOR data + empty AND mask).
    Pillow stores ICO entries as PNG, which LCL's icon reader rejects ('Bitmap
    with unknown compression'); a plain BI_RGB DIB is what LCL expects."""
    img = img.convert("RGBA")
    w, h = img.size
    px = img.load()
    xor = bytearray()
    for y in range(h - 1, -1, -1):           # DIB rows are bottom-up
        for x in range(w):
            r, g, b, a = px[x, y]
            xor += bytes((b, g, r, a))
    and_row = ((w + 31) // 32) * 4            # 1bpp mask, rows padded to 4 bytes
    andmask = b"\x00" * (and_row * h)
    # BITMAPINFOHEADER: biHeight is doubled (XOR+AND), BI_RGB (0), 32bpp
    hdr = struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0,
                      len(xor) + len(andmask), 0, 0, 0, 0)
    return hdr + bytes(xor) + andmask


def write_ico(path, master, sizes):
    imgs = [(s, master.resize((s, s), Image.LANCZOS)) for s in sizes]
    dibs = [(s, _dib(im)) for s, im in imgs]
    off = 6 + 16 * len(dibs)
    entries = b""
    for s, dib in dibs:
        b1 = s if s < 256 else 0
        entries += struct.pack("<BBBBHHII", b1, b1, 0, 0, 1, 32, len(dib), off)
        off += len(dib)
    with open(path, "wb") as f:
        f.write(struct.pack("<HHH", 0, 1, len(dibs)))   # ICONDIR: reserved, type=icon, count
        f.write(entries)
        for _, dib in dibs:
            f.write(dib)


def main():
    os.makedirs(ASSETS, exist_ok=True)
    master = render(MASTER)

    write_ico(os.path.join(ASSETS, "gotbox.ico"), master,
              [16, 24, 32, 48, 64, 128, 256])

    for s in [16, 22, 24, 32, 48, 64, 128, 256]:
        d = os.path.join(ASSETS, "icons", f"{s}x{s}")
        os.makedirs(d, exist_ok=True)
        master.resize((s, s), Image.LANCZOS).save(os.path.join(d, "gotbox.png"))

    # status badges for the Windows Explorer icon overlays (Phase 3 DLL)
    for kind in ("synced", "modified", "conflict"):
        write_ico(os.path.join(ASSETS, f"overlay-{kind}.ico"),
                  render_badge(MASTER, kind), [16, 20, 24, 32, 48])

    print("wrote", os.path.join(ASSETS, "gotbox.ico"),
          "the overlay-*.ico badges,",
          "and hicolor PNGs under", os.path.join(ASSETS, "icons"))


if __name__ == "__main__":
    main()
