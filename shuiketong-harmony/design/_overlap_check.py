# -*- coding: utf-8 -*-
"""关键验证：**重叠**（缝为负）时，真 metaball 的上边界 vs 我的模型。

怀疑点：
  `VALLEY` 是在**正缝 8~14** 上抽的归一化形状，尾巴伸到 ±36vp。
  一旦套到**负缝**（两块重叠、fill 很小），`fill × VALLEY(Δ)` 整条尾巴趋近 0，
  而 `min(清晰并集, 山谷)` 就会拿这条"接近 0 的尾巴"去**削平圆球自己的圆弧顶**
  → 圆看起来变方。

本脚本：
  ① 真跑 长条∪圆 的 gooey（σ=12、阈值 0.444），缝从 −24 到 +14
  ② 同场景同一缝，算我的模型（crisp min fill·VALLEY）
  ③ 逐点打印两个上边界，看从哪里开始分岔
"""
import math

from PIL import Image, ImageDraw, ImageFilter

K = 6
R = 30.0
H = 60.0
PAD = 24.0
SIGMA = 12.0
CUT = int(0.444 * 255)

FILL_G0 = -24.0
FILL_STEP = 2.0
FILL = [0.3, 0.7, 1.0, 1.3, 1.8, 2.3, 3.0, 3.7, 4.3, 5.0,
        6.0, 6.8, 8.0, 9.5, 11.0, 12.8, 14.8, 17.2, 20.3, 25.2]
FILL_G_LAST = 14.0
NECK_GAP_MAX = 14.9
VALLEY = [1.000, 0.983, 0.930, 0.855, 0.772, 0.678, 0.577, 0.487, 0.400, 0.320,
          0.249, 0.188, 0.133, 0.090, 0.055, 0.031, 0.012, 0.002, 0.000]
VALLEY_STEP = 2.0
VALLEY_MAX = (len(VALLEY) - 1) * VALLEY_STEP


def neck_fill(gap):
    if gap <= FILL_G0 or gap >= NECK_GAP_MAX:
        return 0.0
    if gap >= FILL_G_LAST:
        t = (gap - FILL_G_LAST) / (NECK_GAP_MAX - FILL_G_LAST)
        return FILL[-1] + (R - FILL[-1]) * t
    f = (gap - FILL_G0) / FILL_STEP
    i = int(f)
    return FILL[i] + (FILL[i + 1] - FILL[i]) * (f - i)


def valley_at(d):
    d = abs(d)
    if d >= VALLEY_MAX:
        return 0.0
    f = d / VALLEY_STEP
    i = int(f)
    return VALLEY[i] + (VALLEY[i + 1] - VALLEY[i]) * (f - i)


def crisp_bar(x, L, Rr):
    if L <= x <= Rr:
        if x < L + R:
            d = x - (L + R)
            return R - math.sqrt(max(R * R - d * d, 0))
        if x > Rr - R:
            d = x - (Rr - R)
            return R - math.sqrt(max(R * R - d * d, 0))
        return 0.0
    return None


def crisp_orb(x, ox):
    dx = x - (ox + R)
    if abs(dx) <= R:
        return R - math.sqrt(max(R * R - dx * dx, 0))
    return None


def crisp(x, L, Rr, ox):
    a, b = crisp_bar(x, L, Rr), crisp_orb(x, ox)
    if a is None:
        return b
    if b is None:
        return a
    return min(a, b)


TAPER_IN = 12.0
TAPER_OUT = 28.0


def model_top(x, L, Rr, ox, jc, fill):
    """旧模型：min(清晰并集, fill·VALLEY)  —— 尾巴会削平圆弧肩部"""
    c = crisp(x, L, Rr, ox)
    if c is None:
        c = R
    if fill > 0.01 and abs(x - jc) < VALLEY_MAX:
        v = fill * valley_at(x - jc)
        if v < c:
            c = v
        elif v - c < 5.0:
            d = v - c
            c = c + d * d / 20.0
    return c


def model_top_new(x, L, Rr, ox, jc, fill):
    """新模型：山谷只在缝附近生效，远处把控制权**交还**给清晰并集"""
    c = crisp(x, L, Rr, ox)
    if c is None:
        c = R
    if fill > 0.01:
        ad = abs(x - jc)
        if ad < VALLEY_MAX:
            v = fill * valley_at(x - jc)
            t = v
            if ad > TAPER_IN:
                w = 0.0 if ad >= TAPER_OUT else 1.0 - (ad - TAPER_IN) / (TAPER_OUT - TAPER_IN)
                t = c + (v - c) * w
            if t < c:
                c = t
            elif t - c < 5.0:
                d = t - c
                c = c + d * d / 20.0
    return c


def true_profile(L, Rr, ox):
    """真 gooey 的上边界（下陷 vp）。x 采样范围 [ox-14, ox+H+14]"""
    W = int((Rr + H + 80) * K)
    Hh = int((H + 2 * PAD) * K)
    im = Image.new('L', (W, Hh), 0)
    d = ImageDraw.Draw(im)
    cy = (PAD + R) * K
    d.rounded_rectangle((L * K, PAD * K, Rr * K, (PAD + H) * K), radius=R * K, fill=255)
    d.ellipse(((ox) * K, PAD * K, (ox + H) * K, (PAD + H) * K), fill=255)
    im = im.filter(ImageFilter.GaussianBlur(SIGMA * K))
    px = im.load()
    prof = {}
    x = ox - 14.0
    while x <= ox + H + 14.0:
        xi = int(round(x * K))
        col = [y for y in range(Hh) if px[xi, y] > CUT]
        prof[x] = None if not col else (col[0] - PAD * K) / K
        x += 2.0
    return prof


def run(gap):
    L = PAD
    Rr = PAD + 88.0
    ox = Rr + gap
    jc = (Rr + ox) / 2.0
    fill = neck_fill(gap)
    prof = true_profile(L, Rr, ox)
    print('=' * 104)
    print('缝 = %+.1f   缝中点 jc=%.1f   fill(模型)=%.2f   '
          'crisp(jc)=%.1f' % (gap, jc, fill, crisp(jc, L, Rr, ox) or R))
    mo = mn = so = sn = 0.0
    print("   x_相对圆左端 |  Δ距缝中点 |  真gooey  |  清晰并集 | 旧模型 | 旧误差 | 新模型 | 新误差")
    x = ox - 14.0
    while x <= ox + H + 14.0:
        t = prof[x]
        c = crisp(x, L, Rr, ox)
        m = model_top(x, L, Rr, ox, jc, fill)
        n = model_top_new(x, L, Rr, ox, jc, fill)
        dt = '  --' if t is None else '%5.1f' % t
        dc = '  --' if c is None else '%5.1f' % c
        if t is None:
            d1 = d2 = '   --'
        else:
            d1 = '%+5.1f' % (m - t)
            d2 = '%+5.1f' % (n - t)
        print('     %+6.1f     |   %+6.1f   | %s    |  %s   | %5.1f | %s  | %5.1f | %s'
              % (x - ox, x - jc, dt, dc, m, d1, n, d2))
        if t is not None:
            mo = max(mo, abs(m - t))
            mn = max(mn, abs(n - t))
            if abs(x - jc) <= 40.0:
                so = max(so, abs(m - t))
                sn = max(sn, abs(n - t))
        x += 4.0
    print('  >>> 全区间 旧%.2f→新%.2f | 缝附近(|D|<=40) 旧%.2f→新%.2f' % (mo, mn, so, sn))


if __name__ == '__main__':
    for g in (-23.0, -20.0, -16.0, -12.0, -8.0, -4.0, 0.0, 4.0, 8.0, 12.0, 14.5):
        run(g)
