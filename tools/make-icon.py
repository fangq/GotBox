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

# brand palette
LEFT  = (46, 204, 113)   # #2ecc71  (badge fill)
EDGE  = (20, 83, 45)     # #14532d  outline
# the app/brand icon matches the tray icon (gboxmain MakeBox / gbox.svg): a flat
# single-tone box with a light "G" traced along its edges -- so every place the
# icon appears (tray, taskbar, indicator fallback) is the same G-outlined box.
BODY  = (39, 158, 95)    # #279e5f  flat box body (the tray "synced" green)
GCOL  = (237, 237, 237)  # #ededed  the constant light "G"

# per-status body colours -- MUST match gboxmain MakeBox so the tray and the
# indicator (which resolves gotbox-<state> from the icon theme) look identical.
# The color code is documented in the README.
STATES = {"idle": (149, 165, 166), "synced": (39, 158, 95),
          "syncing": (52, 152, 219), "conflict": (243, 156, 18),
          "error": (231, 76, 60), "paused": (149, 165, 166),
          "offline": (127, 140, 141)}

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
# flat box silhouette (hexagon), single tone
BODYPTS = ["top", "ur", "lr", "bot", "ll", "ul"]
# The G: walk the silhouette top->ul->ll->bot->lr->ur (skipping the top->ur edge,
# which leaves the G's mouth), then ur->c as the inward tongue.
GEDGES = [("top", "ul"), ("ul", "ll"), ("ll", "bot"),
          ("bot", "lr"), ("lr", "ur"), ("ur", "c")]


def render(n, body=BODY):
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    def P(k):
        x, y = V[k]
        s = 1 - 2 * MARGIN
        return ((MARGIN + x * s) * n, (MARGIN + y * s) * n)

    # flat single-tone box body (colour encodes the status)
    d.polygon([P(k) for k in BODYPTS], fill=body)

    # the constant light "G" traced along the box edges (round joins/caps)
    ew = max(2, int(n * 0.11))
    for a, b in GEDGES:
        d.line([P(a), P(b)], fill=GCOL, width=ew, joint="curve")
    r = ew * 0.5
    for k in {e for pair in GEDGES for e in pair}:
        x, y = P(k)
        d.ellipse([x - r, y - r, x + r, y + r], fill=GCOL)

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

    # per-status masters, rendered big then downscaled per size for crispness
    state_masters = {st: render(MASTER, col) for st, col in STATES.items()}

    for s in [16, 22, 24, 32, 48, 64, 128, 256]:
        d = os.path.join(ASSETS, "icons", f"{s}x{s}")
        os.makedirs(d, exist_ok=True)
        master.resize((s, s), Image.LANCZOS).save(os.path.join(d, "gotbox.png"))
        # per-status themed icons: the indicator advertises gotbox-<state> and
        # the panel resolves these from the icon theme (installed by make install)
        for st, m in state_masters.items():
            m.resize((s, s), Image.LANCZOS).save(
                os.path.join(d, f"gotbox-{st}.png"))

    # status badges for the file-manager icon overlays
    for kind in ("synced", "modified", "conflict"):
        badge = render_badge(MASTER, kind)
        # Windows Explorer overlay DLL wants .ico
        write_ico(os.path.join(ASSETS, f"overlay-{kind}.ico"),
                  badge, [16, 20, 24, 32, 48])
        # macOS Finder Sync extension wants an NSImage-loadable .png
        badge.resize((128, 128), Image.LANCZOS).save(
            os.path.join(ASSETS, f"overlay-{kind}.png"))

    print("wrote", os.path.join(ASSETS, "gotbox.ico"),
          "the overlay-*.ico / overlay-*.png badges,",
          "and hicolor PNGs under", os.path.join(ASSETS, "icons"))


if __name__ == "__main__":
    main()
