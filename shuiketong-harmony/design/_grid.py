# -*- coding: utf-8 -*-
"""网格拼接：把指定帧的指定区域放大排成 cols 列的网格。
用法: python _grid.py <帧目录> <帧列表,逗号分隔> <x0> <x1> <y0> <y1> <cols> <scale> <输出>
"""
import os
import sys
from PIL import Image, ImageDraw

d = sys.argv[1]
names = sys.argv[2].split(',')
x0, x1, y0, y1 = (int(v) for v in sys.argv[3:7])
cols = int(sys.argv[7])
sc = float(sys.argv[8])
out = sys.argv[9]

tiles = []
for nm in names:
    im = Image.open(os.path.join(d, nm + '.jpeg')).convert('RGB').crop((x0, y0, x1, y1))
    im = im.resize((int(im.width * sc), int(im.height * sc)), Image.LANCZOS)
    tiles.append((nm, im))

tw, th = tiles[0][1].width, tiles[0][1].height
rows = (len(tiles) + cols - 1) // cols
sheet = Image.new('RGB', (cols * (tw + 6) + 74, rows * (th + 24) + 6), (255, 255, 255))
dd = ImageDraw.Draw(sheet)
for i, (nm, im) in enumerate(tiles):
    r, c = divmod(i, cols)
    x = 70 + c * (tw + 6)
    y = 4 + r * (th + 24)
    dd.text((8, y + 8), nm, fill=(20, 20, 20))
    sheet.paste(im, (x, y + 16))
sheet.save(out)
print(out, sheet.size)
