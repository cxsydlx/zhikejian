# -*- coding: utf-8 -*-
"""从**真正的 metaball 数学**里量出腰的粗细 —— 不再自己编公式。

参考实现就是 design/interaction-preview.html 里听课键用的那个滤镜：
  <filter id="gooWide"><feGaussianBlur stdDeviation="12"/>
    <feColorMatrix ... "0 0 0 18 -8"/></filter>
即：两圆 → 高斯模糊 σ=12 → alpha 阈值 8/18 = 0.4444。

⚠️ σ 必须与 HTML 一致。曾误记成 18（R=30 时那样腰会粗一截，形状明显不同）。
   HTML 原文：gooWide → stdDeviation=12；goo（选择器）→ stdDeviation=7。

输出：
  A) 缝宽 g → 腰最细处厚度（就是 LiquidToggle.ets 里 NECK_THIN 表的来源）
  B) 缝宽 g → 上边界沿 x 的下陷 profile（看下陷是"局部捏细"还是"整条被啃"）
  C) 断裂点 g*（二分搜索）
"""
import sys
from PIL import Image, ImageDraw, ImageFilter

R = 30.0                 # 圆半径（vp）
SIGMA = 12.0             # 模糊 σ（vp）—— 与 HTML 的 gooWide 一致
K = 10                   # 每 vp 多少像素
CUT = int(0.444 * 255)   # 阈值 8/18
PADC = 80.0              # 画布留边（vp，要 > 3σ 否则模糊被裁）


def alpha_map(gap, sigma=None):
    s = SIGMA if sigma is None else sigma
    W = int((2 * R + gap + 2 * PADC) * K)
    Hh = int((2 * R + 2 * PADC) * K)
    im = Image.new('L', (W, Hh), 0)
    d = ImageDraw.Draw(im)
    cy = Hh / 2.0
    cx1 = PADC * K + R * K
    cx2 = cx1 + (2 * R + gap) * K
    for cx in (cx1, cx2):
        d.ellipse((cx - R * K, cy - R * K, cx + R * K, cy + R * K), fill=255)
    im = im.filter(ImageFilter.GaussianBlur(s * K))
    return im, cx1, cx2, cy


def neck_thickness(gap, sigma=None):
    im, cx1, cx2, cy = alpha_map(gap, sigma)
    px = im.load()
    xm = int((cx1 + cx2) / 2)
    ys = [y for y in range(im.height) if px[xm, y] > CUT]
    if not ys:
        return 0.0
    return (ys[-1] - ys[0] + 1) / K


def neck_break(sigma=None):
    lo, hi = 0.0, 40.0
    for _ in range(40):
        m = (lo + hi) / 2
        if neck_thickness(m, sigma) > 0:
            lo = m
        else:
            hi = m
    return (lo + hi) / 2


def profile(gap, sigma=None):
    """沿 x 采样上边界（相对圆心线的下陷量，单位 vp）"""
    im, cx1, cx2, cy = alpha_map(gap, sigma)
    px = im.load()
    out = []
    x0 = cx1 + R * K - 8 * K
    x1 = cx2 - R * K + 8 * K
    for x in range(int(x0), int(x1) + 1, K):
        col = [y for y in range(im.height) if px[x, y] > CUT]
        rel_x = (x - cx1) / K
        if not col:
            out.append((rel_x, None))
        else:
            out.append((rel_x, (col[0] - cy) / K + R))   # 距顶部下陷
    return out


if __name__ == '__main__':
    print('=' * 76)
    print('A) 腰最细处厚度    σ=%.0f  R=%.0f  H=%.0f  CUT=%.3f' % (SIGMA, R, 2 * R, CUT / 255))
    print('   缝g | 真metaball腰厚')
    table = []
    for gap in range(0, 21, 2):
        t = neck_thickness(float(gap))
        table.append(t)
        print('  %5.1f | %14.1f' % (gap, t))
    print('  表（可直接粘进 LiquidToggle.ets 的 NECK_THIN）=')
    print('  [%s]' % ', '.join('%.1f' % v for v in table))
    gstar = neck_break()
    print('  断裂点 g* = %.2f  （≈ %.2f·σ）' % (gstar, gstar / SIGMA))

    print()
    print('=' * 76)
    print('B) 上边界下陷 profile（0 = 与圆顶齐平；坐标是"距左圆心"，单位 vp）')
    for gap in (0.0, 8.0, 14.0, 18.0):
        pr = profile(gap)
        print('  --- 缝 %.1f ---' % gap)
        print('   ' + '  '.join('%+.0f:%s' % (x, '--' if d is None else '%.0f' % d)
                               for x, d in pr))

    if len(sys.argv) > 1 and sys.argv[1] == 'sigma':
        print()
        print('=' * 76)
        print('C) σ 扫描：σ 越大断裂点越靠后，但有上限')
        for s in (7.0, 10.0, 12.0, 14.0, 16.0, 18.0, 22.0):
            print('  σ=%4.1f → g*=%.2f' % (s, neck_break(s)))
