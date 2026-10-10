# -*- coding: utf-8 -*-
"""真 gooey（长条 ∪ 圆，σ=12 + 阈值 0.444） vs 本模型 —— 同一场景、同一 gap。

之前的验证都只在"两个圆"上做，没测过"长条 + 圆"。
本脚本补上这一格，并顺手量出真值的缝中点位置与两翼对称性。
"""
import math
from PIL import Image, ImageDraw, ImageFilter

import liquid_render as LR

K = 3
CUT = int(0.444 * 255)
BOXW = 1762.0 / (134.0 / 60.0)      # 真机 boxW（vp）


def scene_true(gap, boxW=BOXW, sigma=12.0):
    pL = (60.0 + gap) / LR.SPAN
    cw = int((boxW + 2 * LR.PAD) * K)
    ch = int((LR.H + 2 * LR.PAD) * K)
    im = Image.new('L', (cw, ch), 0)
    d = ImageDraw.Draw(im)
    pillL = (LR.PAD + pL * LR.SPAN) * K
    pillR = (LR.PAD + boxW - LR.SPAN + LR.SPAN) * K
    orbX = LR.PAD * K
    top = LR.PAD * K
    bot = (LR.PAD + LR.H) * K
    r = LR.R * K
    d.rounded_rectangle((pillL, top, pillR, bot), radius=r, fill=255)
    d.ellipse((orbX, top, orbX + LR.H * K, bot), fill=255)
    im = im.filter(ImageFilter.GaussianBlur(sigma * K))
    px = im.load()
    out = Image.new('RGBA', (cw, ch), (246, 247, 250, 255))
    op = out.load()
    for y in range(ch):
        for x in range(cw):
            if px[x, y] > CUT:
                op[x, y] = (10, 89, 247, 255)
    return out, gap


def profile_true(gap, boxW=BOXW):
    im, _ = scene_true(gap, boxW)
    px = im.load()
    W, Hh = im.size
    out = []
    for xi in range(0, W):
        col = None
        for y in range(Hh):
            if px[xi, y][2] > 200 and px[xi, y][0] < 70:
                col = y
                break
        out.append((xi / K, None if col is None else col / K))
    return out


if __name__ == '__main__':
    print('真 gooey：拓扑（缝中点之后是否断开）随 gap 变化')
    print('  gap   缝中点x   腰上边界y   腰厚    状态')
    for gap in (-4.0, 0.0, 4.0, 8.0, 12.0, 14.0, 14.9, 16.0):
        pL = (60.0 + gap) / LR.SPAN
        pillL = LR.PAD + pL * LR.SPAN
        orbX = LR.PAD
        jc = (pillL + orbX + LR.H) / 2.0
        pr = profile_true(gap)
        # 在 jc 附近找最厚的连续段（= 腰）
        cand = [(x, y) for x, y in pr if y is not None and abs(x - jc) < 3]
        if not cand:
            print('  %5.1f  %7.1f   —— 断开（无材料）' % (gap, jc))
            continue
        ytop = min(y for _, y in cand)
        # 腰厚：同列向下数到材料结束
        pL2 = (60.0 + gap) / LR.SPAN
        print('  %5.1f  %7.1f   %8.1f   %s' % (gap, jc, ytop, ''))

    # 逐列上边界（真值 vs 模型）
    print()
    print('=' * 100)
    print('上边界对照（y，vh 相对画布顶；同一场景长条+圆）')
    for gap in (0.0, 8.0, 12.0, 14.0):
        pL = (60.0 + gap) / LR.SPAN
        pillL = LR.PAD + pL * LR.SPAN
        orbX = LR.PAD
        jc = (pillL + orbX + LR.H) / 2.0
        pr = dict(profile_true(gap))
        top, bot, gg, ff = LR.outline(BOXW, 1.0, pL, 1.0)
        md = {round(x, 1): y for x, y in top}
        print('  ---- gap %.1f   (jc=%.1f, 缝中点) ----' % (gap, jc))
        xs = [round(jc + d, 1) for d in range(-34, 35, 6)]
        row1, row2 = [], []
        for x in xs:
            v = pr.get(x)
            row1.append('  --' if v is None else '%4.1f' % v)
            row2.append('%4.1f' % md.get(x, float('nan')))
        print('    x      :' + ''.join('%6.1f' % x for x in xs))
        print('    真gooey:' + ''.join('%6s' % s for s in row1))
        print('    本模型 :' + ''.join('%6s' % s for s in row2))

    sheet_rows = []
    for gap in (0.0, 8.0, 12.0, 14.0):
        a, _ = scene_true(gap)
        pL = (60.0 + gap) / LR.SPAN
        cw, ch = int((BOXW + 2 * LR.PAD) * LR.SS), int((LR.H + 2 * LR.PAD) * LR.SS)
        b = Image.new('RGBA', (cw, ch), (246, 247, 250, 255))
        top, bot, gg, ff = LR.outline(BOXW, 1.0, pL, 1.0)
        poly = [(x * LR.SS, y * LR.SS) for x, y in top] + \
               [(x * LR.SS, y * LR.SS) for x, y in reversed(bot)]
        ImageDraw.Draw(b).polygon(poly, fill=(10, 89, 247, 255))
        b = b.resize((int(BOXW + 2 * LR.PAD), int(LR.H + 2 * LR.PAD)), Image.LANCZOS)
        sheet_rows.append((gap, a, b))
    # 裁剪同一区间：x 0..200 vp
    box = (0, 0, int(200 * K), sheet_rows[0][1].height)
    W = 640
    tiles = []
    for gap, a, b in sheet_rows:
        aa = a.crop(box)
        aa = aa.resize((W, int(aa.height * W / aa.width)), Image.LANCZOS)
        bb = b.crop((0, 0, 200, b.height))
        bb = bb.resize((W, int(bb.height * W / bb.width)), Image.LANCZOS)
        tiles.append((gap, aa, bb))
    th = tiles[0][1].height
    sheet = Image.new('RGB', (W * 2 + 24, (th + 24) * len(tiles) + 24), (255, 255, 255))
    d = ImageDraw.Draw(sheet)
    d.text((8, 4), 'TRUE gooey (sigma=12, scene)', fill=(200, 0, 0))
    d.text((W + 16, 4), 'MODEL (current)', fill=(0, 90, 200))
    for k, (gap, aa, bb) in enumerate(tiles):
        y = 20 + k * (th + 24)
        d.text((8, y), 'gap=%.1f' % gap, fill=(20, 20, 20))
        sheet.paste(aa, (8, y + 14))
        sheet.paste(bb, (W + 16, y + 14))
    sheet.save('scene-true-vs-model.png')
    print()
    print('-> scene-true-vs-model.png %s' % (sheet.size,))
