"""Puts the nursery illustration behind the real controls of a live-screen capture."""
import sys
from PIL import Image, ImageFilter, ImageDraw

TEXT = (0xF4, 0xF1, 0xEA)


def composite(shot_path, scene_path, out_path, kind):
    im = Image.open(shot_path).convert("RGB")
    W, H = im.size
    scene = Image.open(scene_path).convert("RGB")
    assert scene.size == im.size, (scene.size, im.size)
    px = im.load()
    # The "picture off" button is lit in the captures (the simulator has no camera): show it idle.
    y0, y1 = (800, 990) if kind == "phone" else (480, 600)
    xs, ys = [], []
    for y in range(y0, y1):
        for x in range(int(W * 0.8), W):
            r, g, b = px[x, y]
            if abs(r - 0xF2) < 10 and abs(g - 0xB6) < 10 and abs(b - 0x6D) < 14:
                xs.append(x); ys.append(y)
    cx = (min(xs) + max(xs)) / 2; cy = (min(ys) + max(ys)) / 2; rad = (max(xs) - min(xs)) / 2
    rail = (0x25, 0x27, 0x2E)
    for y in range(int(cy - rad - 4), int(cy + rad + 5)):
        for x in range(int(cx - rad - 4), int(cx + rad + 5)):
            d = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5
            if d > rad + 3:
                continue
            if d > rad - 3:
                px[x, y] = rail
                continue
            a = 1 - max(0, min(1, (px[x, y][0] - 0x1A) / (0xF2 - 0x1A)))
            px[x, y] = tuple(int(rail[i] + (TEXT[i] - rail[i]) * a) for i in range(3))
    # Everything brighter than the empty picture area is a control.
    r, _, _ = im.split()
    raw = r.point(lambda v: 255 if v > 29 else 0)
    mask = raw.filter(ImageFilter.MaxFilter(21)).filter(ImageFilter.MinFilter(21))
    status_bar = 180 if kind == "phone" else 70
    mask.paste(raw.crop((0, 0, W, status_bar)), (0, 0))
    d = ImageDraw.Draw(mask)
    d.rectangle((W * 0.15, H * 0.35, W * 0.85, H * 0.65), fill=0)  # the "Audio only" notice
    if kind == "pad":
        d.rectangle((W - 90, H - 90, W, H), fill=0)
    mask = mask.filter(ImageFilter.GaussianBlur(1.2))
    Image.composite(im, scene, mask).save(out_path)


if __name__ == "__main__":
    composite(*sys.argv[1:5])
