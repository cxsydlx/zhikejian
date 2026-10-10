# -*- coding: utf-8 -*-
"""复核：新参数（FUSE=24 / EXPO=1.2）下的葫芦 + 图标放大检查。"""
from PIL import Image, ImageDraw
import liquid_render as NR

BOXW = 300



# ---- A. 时间轴网格 ----
TIMES = [0, 20, 40, 60, 160, 520, 620, 680, 720, 780, 840, 878]
Z, COLS = 2.2, 3
tiles = []
for t in TIMES:
    im, info = NR.frame(BOXW, t, True)
    im = im.resize((int(im.width * Z), int(im.height * Z)), Image.LANCZOS)
    tiles.append((t, im, info))
tw, th = tiles[0][1].width, tiles[0][1].height
rows = (len(tiles) + COLS - 1) // COLS
gx, gy = 12, 26
sh = Image.new('RGB', (COLS * tw + (COLS + 1) * gx, rows * (th + gy) + gy), (240, 242, 246))
d = ImageDraw.Draw(sh)
for i, (t, im, info) in enumerate(tiles):
    r, c = divmod(i, COLS)
    x, y = gx + c * (tw + gx), gy + r * (th + gy)
    sh.paste(im, (x, y), im)
    d.text((x, y - 16), 't=%dms  %s' % (t, info), fill=(10, 10, 20))
sh.save('liquid-frames.png')

# ---- B. 图标放大（t=0 麦克风 / t=878 呼吸灯）----
ics = []
for t in (0, 878):
    im, _ = NR.frame(BOXW, t, True)
    cx = int(NR.PAD + (1 - NR.prog(t, NR.DUR_ORB, 0)) * (BOXW - NR.H) + NR.R)
    cy = int(NR.PAD + NR.R)
    box = im.crop((cx - 45, cy - 45, cx + 45, cy + 45))
    box = box.resize((box.width * 5, box.height * 5), Image.NEAREST)
    ics.append((t, box))
w, h = ics[0][1].size
s2 = Image.new('RGB', (2 * (w + 12) + 12, h + 30), (240, 242, 246))
d2 = ImageDraw.Draw(s2)
for i, (t, im) in enumerate(ics):
    x = 12 + i * (w + 12)
    s2.paste(im, (x, 26), im)
    d2.text((x, 8), 'icon t=%dms  (circle diameter = %d)' % (t, NR.H * 5), fill=(0, 0, 0))
s2.save('liquid-icon.png')
print('ok', sh.size, s2.size)
