"""Builds the App Store images: screenshots per device, the header and the search results asset.

Usage: python3 build.py [iphone] [ipad] [duo] [header] [search]. The images land in `out/`.
"""
import os, subprocess, sys
from PIL import Image

from composite import composite

HERE = os.path.dirname(os.path.abspath(__file__))
CAPTURES = os.path.join(HERE, "captures")
OUT = os.path.join(HERE, "out")
WORK = os.path.join(OUT, "work")

FRAMES = [
    ("1-live", "work/live-{k}.png", "Two iPhones.<br><em>One baby monitor.</em>",
     "Live picture and sound, straight from the nursery."),
    ("2-private", "{k}/role.png", "<em>No account.</em><br>No subscription.",
     "No ads, no tracking. Picture and sound go straight from one device to the other."),
    ("3-alerts", "{k}/settings.png", "Know when<br><em>baby wakes</em>",
     "Noise or cry alerts, at the sensitivity you choose."),
    ("4-soothe", "work/commands-{k}.png", "Soothe from<br><em>the next room</em>",
     "Night light, lullaby, white noise and talk-back."),
    ("5-pairing", "{k}/pairing.png", "Paired in<br><em>seconds</em>",
     "Scan the code once. No sign-up, nothing to configure."),
    ("6-spare", "{k}/baby-idle.png", "A spare iPhone<br><em>is the camera</em>",
     "Works with the iPhones and iPads you already own."),
]

CLOSE_UPS = {"3-alerts": {"phone": 0.9, "pad": 0.96}, "2-private": {"pad": 1.3}, "5-pairing": {"pad": 1.3}}
# On the iPad and the iPhone Duo the captions name no particular device.
PAD_HEADS = {"1-live": "Two devices.<br><em>One baby monitor.</em>", "6-spare": "A spare iPad<br><em>is the camera</em>"}

# name: (width, height, capture set, headline size in vw, sub size in vw, device height in vh, corner radius as % of device width)
FORMATS = {
    "iphone": (1320, 2868, "phone", 9.6, 4.0, 71.5, 13.5),
    "ipad": (2064, 2752, "pad", 6.6, 2.7, 72.0, 4.2),
    "duo": (2007, 2853, "pad", 6.9, 2.9, 71.0, 4.2),
}

CSS = """
@font-face{font-family:"Rounded";src:url(file:///System/Library/Fonts/SFNSRounded.ttf);font-weight:100 900}
*{box-sizing:border-box;margin:0;padding:0}
html,body{width:100vw;height:100vh;overflow:hidden}
body{font-family:"Rounded",-apple-system,sans-serif;text-wrap:balance;color:#F4F1EA;
 background:
  radial-gradient(ellipse 70% 38% at 50% 62%, rgba(242,182,109,.20), rgba(242,182,109,0) 70%),
  radial-gradient(ellipse 120% 60% at 50% 0%, #1B2443 0%, rgba(27,36,67,0) 70%),
  linear-gradient(#0F1524,#070A12);
 -webkit-font-smoothing:antialiased}
em{font-style:normal;color:#F2B66D}
.stars{position:absolute;inset:0;background-image:
  radial-gradient(circle at 8% 6%, #F4F1EA 0, #F4F1EA .16vw, transparent .2vw),
  radial-gradient(circle at 91% 9%, #F4F1EA 0, #F4F1EA .12vw, transparent .16vw),
  radial-gradient(circle at 82% 3%, #F2B66D 0, #F2B66D .14vw, transparent .18vw),
  radial-gradient(circle at 15% 19%, #F4F1EA 0, #F4F1EA .10vw, transparent .14vw),
  radial-gradient(circle at 95% 22%, #F4F1EA 0, #F4F1EA .14vw, transparent .18vw),
  radial-gradient(circle at 4% 31%, #F2B66D 0, #F2B66D .10vw, transparent .14vw),
  radial-gradient(circle at 97% 47%, #F4F1EA 0, #F4F1EA .10vw, transparent .14vw),
  radial-gradient(circle at 3% 58%, #F4F1EA 0, #F4F1EA .14vw, transparent .18vw);
 opacity:.55}
.device{position:absolute;background:#04050A;border:.35vw solid #39415F;
 box-shadow:0 0 0 .12vw #0b0e18, 0 3vw 9vw rgba(0,0,0,.65), 0 0 14vw rgba(242,182,109,.10)}
.device img{display:block;width:100%;height:100%}
"""


def source(path):
    """A capture from the app, or a picture made by `prepare`."""
    return os.path.join(OUT, path) if path.startswith("work/") else os.path.join(CAPTURES, path)


# The crib is placed and sized for each picture: (transform of the crib, width, height).
SCENES = {
    "phone": ("translate(465 690) rotate(-4) scale(0.78)", 1320, 2868),
    "pad": ("translate(500 690) rotate(-4) scale(0.92)", 2064, 2752),
    "wide": ("translate(500 700) rotate(-4) scale(0.95)", 1500, 2100),
}


def prepare():
    """Draws the nursery for each size, and puts it behind the controls of the live captures.

    The simulator has no camera, so the captures of the live screen show no picture.
    """
    os.makedirs(WORK, exist_ok=True)
    svg = open(os.path.join(HERE, "scene.svg")).read()
    for name, (transform, w, h) in SCENES.items():
        open(os.path.join(WORK, f"scene-{name}.svg"), "w").write(svg.replace("translate(500 700) rotate(-4)", transform))
        html = os.path.join(WORK, f"scene-{name}.html")
        open(html, "w").write("<!doctype html><html><body style='margin:0;background:#05070d'>"
                              f"<img src='scene-{name}.svg' style='width:100vw;height:100vh;object-fit:cover;display:block'></body></html>")
        png = os.path.join(WORK, f"scene-{name}.png")
        subprocess.run([os.path.join(HERE, "render.sh"), html, png, str(w), str(h)], check=True)
        Image.open(png).convert("RGB").save(png)
    for kind in ("phone", "pad"):
        for screen in ("live", "commands"):
            composite(os.path.join(CAPTURES, kind, f"{screen}.png"), os.path.join(WORK, f"scene-{kind}.png"),
                      os.path.join(WORK, f"{screen}-{kind}.png"), kind)


def page(body, extra=""):
    return f"<!doctype html><html><head><meta charset='utf-8'><style>{CSS}{extra}</style></head><body><div class='stars'></div>{body}</body></html>"


def render(html, name, w, h):
    os.makedirs(OUT, exist_ok=True)
    src = os.path.join(OUT, name + ".html")
    png = os.path.join(OUT, name + ".png")
    open(src, "w").write(html)
    subprocess.run([os.path.join(HERE, "render.sh"), src, png, str(w), str(h)], check=True)
    im = Image.open(png)
    assert im.size == (w, h), (name, im.size)
    im.convert("RGB").save(png)  # no alpha
    return png


def device(src, style, radius, pad="1.1vw"):
    return (f"<div class='device' style='{style};padding:{pad};border-radius:{radius}'>"
            f"<img src='file://{src}' style='border-radius:calc({radius} - {pad})'></div>")


def screenshots(fmt):
    w, h, k, hs, ss, dh, rad = FORMATS[fmt]
    for name, shot, head, sub in FRAMES:
        src = source(shot.format(k=k))
        sw, sh = Image.open(src).size
        dev_h = h * dh / 100
        dev_w = dev_h * sw / sh
        radius = f"{dev_w * rad / 100:.0f}px"
        place = f"left:{(w - dev_w) / 2:.0f}px;bottom:{h * 0.028:.0f}px;width:{dev_w:.0f}px;height:{dev_h:.0f}px"
        if k == "pad":
            head = PAD_HEADS.get(name, head)
        if k in CLOSE_UPS.get(name, {}):
            dev_w = w * CLOSE_UPS[name][k]
            dev_h = dev_w * sh / sw
            radius = f"{dev_w * rad / 100:.0f}px"
            place = f"left:{(w - dev_w) / 2:.0f}px;top:{h * (100 - dh - 2.8) / 100:.0f}px;width:{dev_w:.0f}px;height:{dev_h:.0f}px"
        dev = device(src, place, radius)
        zoom = CLOSE_UPS.get(name, {}).get(k, 0)
        if zoom > 1:  # a full-width panel on the screen's content, without the status bar
            top = h * (100 - dh - 2.8) / 100
            dev = (f"<div style='position:absolute;left:0;right:0;top:{top:.0f}px;bottom:0;overflow:hidden;"
                   f"border-top:.35vw solid #39415F;box-shadow:0 0 14vw rgba(242,182,109,.10)'>"
                   f"<img src='file://{src}' style='display:block;width:{zoom * w:.0f}px;"
                   f"margin-left:{-(zoom - 1) / 2 * w:.0f}px;margin-top:{-0.034 * zoom * w:.0f}px'></div>")
        body = f"""
<div style='position:absolute;left:6vw;right:6vw;top:4.6vh;text-align:center'>
 <div style='font-weight:800;font-size:{hs}vw;line-height:1.06;letter-spacing:-.01em'>{head}</div>
 <div style='margin:2.2vw auto 0;max-width:80vw;font-weight:500;font-size:{ss}vw;line-height:1.28;color:#A9B1C6'>{sub}</div>
</div>
{dev}
"""
        render(page(body), f"{fmt}-{name}", w, h)


def safe(x, y, w, h, show):
    return (f"<div style='position:absolute;left:{x}px;top:{y}px;width:{w}px;height:{h}px;"
            f"outline:6px dashed #ff3b8d'></div>") if show else ""


def header(debug=False):
    w, h = 3840, 1646
    live = source("work/live-phone.png")
    scene = os.path.join(WORK, "scene-wide.png")
    body = f"""
<div style='position:absolute;left:-140px;top:-240px;width:1500px;height:2100px;
  background:url(file://{scene}) center/cover;
  -webkit-mask-image:radial-gradient(ellipse 50% 50% at 50% 50%, #000 52%, transparent 100%)'></div>
{device(live, "left:2890px;top:150px;width:800px;height:1738px", "108px", "22px")}
<div style='position:absolute;left:1097px;top:493px;width:1646px;height:661px;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center'>
 <div style='font-weight:800;font-size:178px;line-height:1.06;letter-spacing:-.01em'>Two iPhones.<br><em>One baby monitor.</em></div>
 <div style='margin-top:44px;font-weight:600;font-size:66px;color:#A9B1C6'>No account &nbsp;·&nbsp; No subscription &nbsp;·&nbsp; No tracking</div>
</div>
{safe(1097, 493, 1646, 661, debug)}
"""
    extra = "body{background:radial-gradient(ellipse 45% 70% at 50% 50%, #1B2443 0%, rgba(27,36,67,0) 75%),linear-gradient(#0F1524,#070A12)}"
    return render(page(body, extra), "header" + ("-debug" if debug else ""), w, h)


def search(debug=False):
    w, h = 3840, 2560
    live = source("work/live-phone.png")
    alerts = source("phone/settings.png")
    body = f"""
{device(live, "left:60px;top:330px;width:880px;height:1912px", "118px", "24px")}
{device(alerts, "left:2900px;top:330px;width:880px;height:1912px", "118px", "24px")}
<div style='position:absolute;left:836px;top:765px;width:2168px;height:1030px;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center'>
 <div style='font-weight:800;font-size:226px;line-height:1.06;letter-spacing:-.01em'>Two iPhones.<br><em>One baby monitor.</em></div>
 <div style='margin-top:64px;font-weight:600;font-size:88px;color:#A9B1C6'>No account &nbsp;·&nbsp; No subscription &nbsp;·&nbsp; No tracking</div>
</div>
{safe(836, 765, 2168, 1030, debug)}
"""
    extra = "body{background:radial-gradient(ellipse 50% 60% at 50% 50%, #1B2443 0%, rgba(27,36,67,0) 75%),linear-gradient(#0F1524,#070A12)}"
    return render(page(body, extra), "search" + ("-debug" if debug else ""), w, h)


if __name__ == "__main__":
    what = sys.argv[1:] or ["iphone", "ipad", "duo", "header", "search"]
    prepare()
    for item in what:
        if item in FORMATS:
            screenshots(item)
        elif item == "header":
            header(); header(True)
        elif item == "search":
            search(); search(True)
    # contact sheets for review
    for item in what:
        files = sorted(f for f in os.listdir(OUT) if f.startswith(item) and f.endswith(".png") and "sheet" not in f)
        ims = [Image.open(os.path.join(OUT, f)) for f in files]
        th = 700 if item in FORMATS else 420
        ims = [i.resize((int(i.width * th / i.height), th)) for i in ims]
        if item in FORMATS:
            sheet = Image.new("RGB", (sum(i.width for i in ims[:3]) + 40, th * 2 + 30), "#888")
            for n, i in enumerate(ims):
                sheet.paste(i, (10 + (n % 3) * (i.width + 10), 10 + (n // 3) * (th + 10)))
        else:
            sheet = Image.new("RGB", (max(i.width for i in ims) + 20, sum(i.height for i in ims) + 30), "#888")
            y = 10
            for i in ims:
                sheet.paste(i, (10, y)); y += i.height + 10
        sheet.save(os.path.join(OUT, f"sheet-{item}.png"))
