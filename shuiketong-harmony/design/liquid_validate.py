# -*- coding: utf-8 -*-
"""验证新模型在**全区间**（重叠 → 接触 → 拉丝 → 断裂）都贴合真 metaball。

重叠区间（缝 < 0）同样是动画里很长的可见段（圆从长条左端挤出来），
gooey 会把那个 V 形缺口填成一个浅谷 —— 必须确认模型也填。

同时打印动画时间轴：每一时刻的缝宽，用来定"葫芦该给多少时长"。
"""
from PIL import Image, ImageDraw

import liquid_shape as LS
from liquid_shape import R, H, PAD, K, NECK_THIN, NECK_MAX, NECK_THIN_OLD, NECK_MAX_OLD

LS.SHAPE_STEPS, LS.SHAPE_VALS = LS.extract_shape()


def table(gaps):
    print('=' * 104)
    print('① 上边界逐点对照（vp，0 = 圆顶）   Δ = 距缝中点')
    for gap in gaps:
        jc = R + gap / 2.0
        hdr, r1, r2 = [], [], []
        mx = 0.0
        for d in range(-32, 33, 4):
            rel = jc + d
            tv, nv = LS.true_top(gap, rel), LS.model_top(rel, gap)
            f = lambda v: '--' if v is None else '%.0f' % v
            hdr.append('%5.0f' % d)
            r1.append('%3s' % f(tv))
            r2.append('%3s' % f(nv))
            if tv is not None and nv is not None:
                mx = max(mx, abs(tv - nv))
        print('  ---- 缝 %+5.1f ----   最大偏差 %.1f vp' % (gap, mx))
        print('    Δ :' + ''.join(hdr))
        print('    真 :' + ''.join(r1))
        print('    新 :' + ''.join(r2))


def timeline(boxW, tess=(0, 120, 200, 300, 400, 480, 520, 560, 600, 650, 700, 750, 800, 860, 900)):
    """当前时序：DUR_ORB=580 / FAST 320+50 / SLOW 600+280"""
    DUR_ORB, DUR_FAST, DELAY_FAST, DUR_SLOW, DELAY_SLOW = 580.0, 320.0, 50.0, 600.0, 280.0
    SPAN = H + 28

    def bez(t, c1=0.4, c2=0.2):
        lo, hi = 0.0, 1.0
        for _ in range(60):
            u = (lo + hi) / 2
            x = 3*(1-u)**2*u*c1 + 3*(1-u)*u*u*c2 + u**3
            if x < t:
                lo = u
            else:
                hi = u
        u = (lo + hi) / 2
        return 3*(1-u)**2*u*0.0 + 3*(1-u)*u*u*1.0 + u**3

    def prog(el, dur, delay):
        x = (el - delay) / dur
        return 0.0 if x <= 0 else (1.0 if x >= 1 else bez(x))

    def slow(x):
        X1, X2, Y1, Y2 = 0.18, 0.40, 0.682, 0.845
        if x <= 0:
            return 0.0
        if x >= 1:
            return 1.0
        if x < X1:
            return Y1 * bez(x / X1)
        if x < X2:
            return Y1 + (Y2 - Y1) * bez((x - X1) / (X2 - X1))
        return Y2 + (1 - Y2) * bez((x - X2) / (1 - X2))

    print()
    print('=' * 104)
    print('② 当前时序下 boxW=%.0f 的缝宽（缝 = 88·pL − 60 − (boxW−60)(1−pOrb)）' % boxW)
    print('   t(ms)  pOrb   pL     pR   |  pillL  orbX+H |  左缝   右缝   状态')
    for t in tess:
        pOrb = prog(t, DUR_ORB, 0)
        pR = prog(t, DUR_FAST, DELAY_FAST)
        pL = slow((t - DELAY_SLOW) / DUR_SLOW)
        pillL = PAD + pL * SPAN
        pillR = PAD + boxW - SPAN + pR * SPAN
        orbX = PAD + (1 - pOrb) * (boxW - H)
        gl = pillL - (orbX + H)
        gr = orbX - pillR
        st = []
        for g, nm in ((gl, 'L'), (gr, 'R')):
            if g < -0.5:
                st.append('%s重叠%.0f' % (nm, -g))
            elif g < 0.5:
                st.append('%s接触' % nm)
            elif g < NECK_MAX:
                st.append('%s拉丝%.1f' % (nm, g))
            else:
                st.append('%s分离%.1f' % (nm, g))
        print('   %5d  %.3f  %.3f  %.3f | %6.1f %6.1f | %6.1f %6.1f  %s'
              % (t, pOrb, pL, pR, pillL, orbX + H, gl, gr, ' '.join(st)))


if __name__ == '__main__':
    table((-24.0, -16.0, -8.0, 0.0, 6.0, 12.0, 14.0))
    timeline(746.0)
    timeline(340.0)
