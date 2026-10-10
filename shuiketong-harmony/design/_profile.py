# -*- coding: utf-8 -*-
"""量真机帧里蓝色液体的**上边界轮廓**，定位"变方"。
用法: python _profile.py <帧文件> <x起> <x止> <步长> <y起> <y止>
"""
import sys
from PIL import Image

path = sys.argv[1]
xa, xb, st, ya, yb = (int(v) for v in sys.argv[2:7])

im = Image.open(path).convert('RGB')
px = im.load()
W, H = im.size

BLUE = (10, 89, 247)


def is_blue(p):
    return abs(p[0] - BLUE[0]) < 45 and abs(p[1] - BLUE[1]) < 45 and abs(p[2] - BLUE[2]) < 45


print('file=%s size=%s' % (path, (W, H)))
print('  x    y_top  y_bot  厚(px)  厚(vp)')
for x in range(xa, xb + 1, st):
    top, bot = -1, -1
    for y in range(ya, yb + 1):
        if is_blue(px[x, y]):
            top = y
            break
    for y in range(yb, ya - 1, -1):
        if is_blue(px[x, y]):
            bot = y
            break
    if top < 0:
        print('%5d     -      -      0' % x)
    else:
        t = bot - top + 1
        print('%5d  %5d  %5d  %5d  %6.1f' % (x, top, bot, t, t / 2.233))
