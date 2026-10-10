# -*- coding: utf-8 -*-
"""A/B：同一 gap 下，Python 模型渲染 vs 真机帧，并排对齐看。

用途：把"ArkTS 实现有 bug"和"模型本身形状不对"这两件事分开。
（2026-10-02 结论：是**后者** —— 模型两翼不对称、比真 metaball 陡。）
"""
from PIL import Image, ImageDraw

import liquid_render as LR

DEV_SC = 134.0 / 60.0        # 真机 px/vp
DEV_X0 = 519.0               # 真机帧里听课键左端
DEV_Y0 = 440.0               # 真机帧里顶线（key 的 y 起点）
BOXW = 1762.0 / DEV_SC       # 真机上算出的 boxW（vp）
CROP = (480, 415, 940, 600)  # 真机裁剪框（px）


def render_at_gap(gap, boxW=BOXW):
    """pOrb=1（圆已到位）时由 gap 反解 pL，pR=1，直接出场景图"""
    pL = (60.0 + gap) / LR.SPAN
    cw, ch = int((boxW + 2 * LR.PAD) * LR.SS), int((LR.H + 2 * LR.PAD) * LR.SS)
    im = Image.new('RGBA', (cw, ch), (246, 247, 250, 255))
    d = ImageDraw.Draw(im)
    top, bot, gg, ff = LR.outline(boxW, 1.0, pL, 1.0)
    poly = [(x * LR.SS, y * LR.SS) for x, y in top] + \
           [(x * LR.SS, y * LR.SS) for x, y in reversed(bot)]
    d.polygon(poly, fill=(10, 89, 247, 255))
    return im.resize((int(boxW + 2 * LR.PAD), int(LR.H + 2 * LR.PAD)), Image.LANCZOS), gg, ff


def dev_crop(i):
    return Image.open('_cap/c%d.jpeg' % i).convert('RGB').crop(CROP)


def py_crop(gap):
    im, gg, ff = render_at_gap(gap)
    x0 = LR.PAD + (CROP[0] - DEV_X0) / DEV_SC
    y0 = LR.PAD + (CROP[1] - DEV_Y0) / DEV_SC
    x1 = LR.PAD + (CROP[2] - DEV_X0) / DEV_SC
    y1 = LR.PAD + (CROP[3] - DEV_Y0) / DEV_SC
    im = im.crop((int(round(x0)), int(round(y0)), int(round(x1)), int(round(y1))))
    w = CROP[2] - CROP[0]
    return im.resize((w, int(round(im.height * w / im.width))), Image.LANCZOS), gg, ff


if __name__ == '__main__':
    pairs = [(1, -4.0), (2, 12.4), (3, 15.6)]
    rows = []
    for i, gap in pairs:
        b, gg, ff = py_crop(gap)
        rows.append((i, dev_crop(i), b, gg, ff))
    w = CROP[2] - CROP[0]
    h = rows[0][2].height
    sheet = Image.new('RGB', (w * 2 + 24, (h + 26) * len(rows) + 22), (255, 255, 255))
    d = ImageDraw.Draw(sheet)
    d.text((8, 4), 'device (real phone)', fill=(200, 0, 0))
    d.text((w + 16, 4), 'python model (same gap)', fill=(0, 90, 200))
    for k, (i, a, b, gg, ff) in enumerate(rows):
        y = 22 + k * (h + 26)
        d.text((8, y), '#%d   model gap=%.1f  fill=%.1f' % (i, gg, ff), fill=(20, 20, 20))
        sheet.paste(a, (8, y + 16))
        sheet.paste(b, (w + 16, y + 16))
    sheet.save('_cap/ab.png')
    print(sheet.size)
