# -*- coding: utf-8 -*-
"""把真机连拍帧裁成按钮条，拼成对比表。
用法: python _strip.py <帧目录> <x0> <x1> <y0> <y1> <每表帧数> <缩放> <输出前缀>
"""
import os
import sys
from PIL import Image, ImageDraw

d = sys.argv[1]
x0, x1, y0, y1 = (int(v) for v in sys.argv[2:6])
per = int(sys.argv[6])
sc = float(sys.argv[7])
pre = sys.argv[8]

names = sorted((n for n in os.listdir(d) if n.startswith('s') and n.endswith('.jpeg')),
               key=lambda n: int(n[1:-5]))

tiles = []
for n in names:
    im = Image.open(os.path.join(d, n)).convert('RGB').crop((x0, y0, x1, y1))
    im = im.resize((int(im.width * sc), int(im.height * sc)), Image.LANCZOS)
    tiles.append((n[:-5], im))

tw, th = tiles[0][1].width, tiles[0][1].height
for k in range(0, len(tiles), per):
    chunk = tiles[k:k + per]
    sheet = Image.new('RGB', (tw + 120, (th + 6) * len(chunk) + 8), (255, 255, 255))
    dd = ImageDraw.Draw(sheet)
    for i, (name, im) in enumerate(chunk):
        y = 4 + i * (th + 6)
        dd.text((8, y + th // 2 - 5), name, fill=(20, 20, 20))
        sheet.paste(im, (114, y))
    out = '%s%d.png' % (pre, k // per)
    sheet.save(out)
    print(out, sheet.size)
