# -*- coding: utf-8 -*-
"""修前后对照：真 metaball / 旧模型（山谷铺满）/ 新模型（山谷带窗口）。
聚焦**重叠段**（缝 < 0）—— 那正是真机上"圆胶囊周围突然变方"出现的地方。
"""
from PIL import Image, ImageDraw

import _overlap_check as OC

K = OC.K
R = OC.R
H = OC.H
PAD = OC.PAD
L = PAD
Rr = PAD + 88.0


def render(gap, mode):
    ox = Rr + gap
    jc = (Rr + ox) / 2.0
    fill = OC.neck_fill(gap)
    W = int((Rr + H + 80) * K)
    Hh = int((H + 2 * PAD) * K)
    im = Image.new('RGB', (W, Hh), (246, 247, 250))
    d = ImageDraw.Draw(im)
    xs = []
    x = ox - 42.0
    while x <= ox + H + 42.0:
        xs.append(x)
        x += 0.25
    top, bot = [], []
    for x in xs:
        if mode == 'true':
            c = OC.true_profile(L, Rr, ox).get(round(x * 2) / 2)
            if c is None:
                continue
        elif mode == 'old':
            c = OC.model_top(x, L, Rr, ox, jc, fill)
        else:
            c = OC.model_top_new(x, L, Rr, ox, jc, fill)
        top.append((x * K, OC.PAD * K + c * K))
        bot.append((x * K, (OC.PAD + H - c) * K))
    if top:
        d.polygon([(a, b) for a, b in top] + [(a, b) for a, b in reversed(bot)],
                  fill=(10, 89, 247))
    # 参考线：圆的理想轮廓（细红）
    d.arc(((ox) * K, PAD * K, (ox + H) * K, (PAD + H) * K), 0, 360, fill=(230, 60, 60), width=2)
    return im.crop((int((ox - 46) * K), 0, int((ox + H + 46) * K), Hh))


gaps = (-22.0, -14.0, -8.0, -2.0)
names = ('TRUE metaball', 'OLD  valley full ±36', 'NEW  valley windowed')
pad = 10
rows = []
for g in gaps:
    rows.append((g, render(g, 'true'), render(g, 'old'), render(g, 'new')))

cw = rows[0][1].width
ch = rows[0][1].height
sheet = Image.new('RGB', (cw * 3 + pad * 4 + 70, (ch + 30) * len(rows) + 40), (255, 255, 255))
dd = ImageDraw.Draw(sheet)
for i, n in enumerate(names):
    dd.text((76 + i * (cw + pad), 10), n, fill=(20, 20, 20))
dd.text((10, 10), '红圈 = 圆球\n理想轮廓', fill=(200, 40, 40))
for r, (g, a, b, c) in enumerate(rows):
    y = 40 + r * (ch + 30)
    dd.text((8, y + ch // 2), 'gap=%.0f' % g, fill=(20, 20, 20))
    for i, im in enumerate((a, b, c)):
        sheet.paste(im, (76 + i * (cw + pad), y))
sheet.save('liquid-valley-window.png')
print('-> liquid-valley-window.png', sheet.size)
