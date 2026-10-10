# -*- coding: utf-8 -*-
"""把真 metaball 的**完整上边界轮廓**量出来（不只缝中点一点），并和我的几何并排渲染。

动机：用户反馈"过渡是从最上面和最下面开始的，不是从中间那一小段开始"。
只量"缝中点厚度"看不出问题 —— 必须看**整条轮廓的形状**。

输出：
  ① 轮廓数值表：每个缝宽 g，上边界相对 y=top 的下陷 d(x)，x 从 -R+2 到 3R+g-2
  ② PNG：上排 = 真 metaball，下排 = 当前 ArkTS 几何（圆盖顶点↔圆盖顶点的贝塞尔腰）
"""
from PIL import Image, ImageDraw, ImageFilter

R = 30.0
SIGMA = 12.0
CUT = int(0.444 * 255)
K = 6                    # 输出像素/vp
MARGIN = 24.0


def true_alpha(gap, k=K):
    W = int((2 * R + gap + 2 * MARGIN) * k)
    Hh = int((2 * R + 2 * MARGIN) * k)
    im = Image.new('L', (W, Hh), 0)
    d = ImageDraw.Draw(im)
    cy = (MARGIN + R) * k
    cx1 = (MARGIN + R) * k
    cx2 = (MARGIN + R + R + gap + R) * k
    for cx in (cx1, cx2):
        d.ellipse((cx - R * k, cy - R * k, cx + R * k, cy + R * k), fill=255)
    im = im.filter(ImageFilter.GaussianBlur(SIGMA * k))
    return im, cx1, cx2, cy


def top_profile(gap):
    """返回 [(x 相对左圆心, 下陷 vp 或 None)]，步长 1vp"""
    im, cx1, cx2, cy = true_alpha(gap)
    px = im.load()
    out = []
    xs = [(-R + 2) + i for i in range(int(2 * R + gap - 4) + 1)]
    for rel in xs:
        x = int(round(cx1 + rel * K))
        col = [y for y in range(im.height) if px[x, y] > CUT]
        out.append((rel, None if not col else (col[0] - cy) / K + R))
    return out


def bez(p0, p1, p2, p3, n=60):
    pts = []
    for i in range(n + 1):
        t = i / n
        mt = 1 - t
        pts.append((mt**3*p0[0] + 3*mt*mt*t*p1[0] + 3*mt*t*t*p2[0] + t**3*p3[0],
                    mt**3*p0[1] + 3*mt*mt*t*p1[1] + 3*mt*t*t*p2[1] + t**3*p3[1]))
    return pts


# ---- 当前 ArkTS 的几何（与 LiquidToggle.ets 的 neck() 逐条对应）----
NECK_THIN_ETS = [50.4, 47.9, 45.1, 42.1, 38.9, 35.1, 30.9, 25.6, 18.6, 5.4]
NECK_THIN_TRUE = [43.9, 41.1, 38.1, 34.5, 30.5, 25.5, 19.3, 9.3]


def thin(gap, table, gmax):
    if gap >= gmax:
        return None
    step = 2.0
    f = gap / step
    i = int(f)
    if i >= len(table) - 1:
        t = (gap - (len(table) - 1) * step) / (gmax - (len(table) - 1) * step)
        return table[-1] * (1 - max(0.0, min(1.0, t)))
    return table[i] + (table[i + 1] - table[i]) * (f - i)


def mine_poly(gap, table, gmax):
    """当前几何：从右盖顶点到左盖顶点画贝塞尔腰（此处作为两圆之间的腰）"""
    t = thin(gap, table, gmax)
    if t is None:
        return None
    Hh = 2 * R
    h = (Hh - t) / 1.5
    top, bot = MARGIN, MARGIN + Hh
    aCapX = MARGIN + 2 * R                 # 左圆右顶点
    bCapX = MARGIN + 2 * R + gap           # 右圆左顶点
    k = (bCapX - aCapX) * 0.34
    pts = bez((aCapX, top), (aCapX + k, top + h), (bCapX - k, top + h), (bCapX, top))
    pts.append((bCapX, bot))
    pts += bez((bCapX, bot), (bCapX - k, bot - h), (aCapX + k, bot - h), (aCapX, bot))
    return pts, h, t


def render_true(gap):
    im, cx1, cx2, cy = true_alpha(gap)
    px = im.load()
    W, Hh = im.size
    out = Image.new('RGBA', (W, Hh), (246, 247, 250, 255))
    op = out.load()
    for y in range(Hh):
        for x in range(W):
            if px[x, y] > CUT:
                op[x, y] = (10, 89, 247, 255)
    return out, cx1, cy


def render_mine(gap, table, gmax):
    W = int((2 * R + gap + 2 * MARGIN) * K)
    Hh = int((2 * R + 2 * MARGIN) * K)
    im = Image.new('RGBA', (W, Hh), (246, 247, 250, 255))
    d = ImageDraw.Draw(im)
    cy = (MARGIN + R) * K
    for cx in ((MARGIN + R) * K, (MARGIN + R + R + gap + R) * K):
        d.ellipse((cx - R * K, cy - R * K, cx + R * K, cy + R * K), fill=(10, 89, 247, 255))
    g = mine_poly(gap, table, gmax)
    if g is not None:
        pts, h, t = g
        d.polygon([(x * K, y * K) for x, y in pts], fill=(10, 89, 247, 255))
    return im


def crop(im, gap):
    x0 = int((MARGIN + 2 * R - 34) * K)
    x1 = int((MARGIN + 2 * R + gap + 34) * K)
    return im.crop((x0, 0, x1, im.height))


def main():
    print('=' * 96)
    print('① 真 metaball 上边界下陷（vp，0 = 与圆顶齐平）   σ=%.0f' % SIGMA)
    print('     x 是距左圆心的距离；左圆右顶点在 x=%+.0f，缝中点 x=%+.0f' % (R, R + 0))
    for gap in (0.0, 4.0, 8.0, 12.0, 14.0):
        pr = top_profile(gap)
        # 压缩成 2vp 一列，只印 -8..(2R+g+8)
        cells = []
        for rel, dv in pr:
            if rel % 2:
                continue
            if rel < -10 or rel > 2 * R + gap + 10:
                continue
            cells.append('%s' % ('--' if dv is None else '%.0f' % dv))
        print('  缝 %4.1f: %s' % (gap, ' '.join(cells)))
    print('  （上述每格 = 2vp；缝中点在大约第 %d 格）' % (int((R + 10) / 2)))

    print()
    print('=' * 96)
    print('② 三张并排：真 metaball / 我的几何(σ=18表, 现役) / 我的几何(σ=12表, 修正)')
    gaps = (0.0, 6.0, 10.0, 13.0, 14.5)
    rows = []
    for gap in gaps:
        a, _, _ = render_true(gap)
        b = render_mine(gap, NECK_THIN_ETS, 18.2)
        c = render_mine(gap, NECK_THIN_TRUE, 14.6)
        rows.append((gap, crop(a, gap), crop(b, gap), crop(c, gap)))

    pad = 8
    cellw = max(r[1].width for r in rows) + 2
    rowh = rows[0][1].height
    sheet = Image.new('RGB', (cellw * 3 + pad * 4, (rowh + 26) * len(rows) + 34), (255, 255, 255))
    dd = ImageDraw.Draw(sheet)
    for i, name in enumerate(('TRUE metaball (sigma=12)', 'MINE  sigma=18 table (current)',
                              'MINE  sigma=12 table (fixed)')):
        dd.text((pad + i * (cellw + pad) + 4, 8), name, fill=(20, 20, 20))
    for r, (gap, a, b, c) in enumerate(rows):
        y = 34 + r * (rowh + 26)
        dd.text((pad, y + 2), 'gap=%.1f' % gap, fill=(20, 20, 20))
        for i, im in enumerate((a, b, c)):
            sheet.paste(im, (pad + i * (cellw + pad), y + 18), im)
    sheet.save('liquid-true-vs-mine.png')
    print('  -> liquid-true-vs-mine.png %s' % (sheet.size,))


if __name__ == '__main__':
    main()
