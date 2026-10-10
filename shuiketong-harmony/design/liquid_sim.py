# -*- coding: utf-8 -*-
"""数值仿真 LiquidToggle 的腰（葫芦）几何 —— 没有真机时唯一能验证形状的办法。

照着 entry/src/main/ets/view/LiquidToggle.ets 的公式逐条复算：
  时间轴 pOrb/pL/pR、两端缝隙、腰深 h、腰最细处厚度。
"""

H = 60.0
PAD = 20.0
GAP = 28.0
SPAN = H + GAP
R = H / 2

DUR_ORB = 580.0
DUR_FAST, DELAY_FAST = 320.0, 50.0
DUR_SLOW, DELAY_SLOW = 600.0, 280.0
TOTAL = max(DUR_ORB, DELAY_SLOW + DUR_SLOW)


def bez(t, c1, c2):
    """cubic-bezier(.4,0,.2,1) 的 y(x=t)。先解 x(u)=t，再取 y(u)。"""
    lo, hi = 0.0, 1.0
    for _ in range(60):
        u = (lo + hi) / 2
        x = 3 * (1 - u) ** 2 * u * c1 + 3 * (1 - u) * u ** 2 * c2 + u ** 3
        if x < t:
            lo = u
        else:
            hi = u
    u = (lo + hi) / 2
    return 3 * (1 - u) ** 2 * u * 0.0 + 3 * (1 - u) * u ** 2 * 1.0 + u ** 3


def prog(el, dur, delay):
    x = (el - delay) / dur
    if x <= 0:
        return 0.0
    if x >= 1:
        return 1.0
    return bez(x, 0.4, 0.2)


def run(boxW, going_on=True):
    print('=' * 78)
    print('容器宽 boxW = %.0f   （圆盖间距 = 缝 + 2R = 缝 + 60）' % boxW)
    print('  t(ms)  pOrb   pL     pR   |  pillL pillR  orbX |  缝   腰深h  腰最细 状态')
    rows = []
    for t in range(0, 921, 20):
        eOrb = prog(t, DUR_ORB, 0)
        eFast = prog(t, DUR_FAST, DELAY_FAST)
        eSlow = prog(t, DUR_SLOW, DELAY_SLOW)
        eL = eSlow if going_on else eFast
        eR = eFast if going_on else eSlow
        pOrb = eOrb
        pL = eL
        pR = eR
        pillL = PAD + pL * SPAN
        pillR = PAD + boxW - SPAN + pR * SPAN
        orbX = PAD + (1 - pOrb) * (boxW - H)
        gapR = orbX - pillR
        gapL = pillL - (orbX + H)
        if 0.5 < gapR < GAP:
            gap, side = gapR, 'R'
        elif 0.5 < gapL < GAP:
            gap, side = gapL, 'L'
        else:
            gap, side = 0.0, '-'
        if gap > 0:
            h = (4 * R / 3) * (min(gap / GAP, 1.0)) ** 1.6
            thin = H - 1.5 * h          # 三次贝塞尔中点下陷 = 0.75h
            state = '腰 %s' % side
        else:
            h = 0.0
            thin = H
            overlap = max(-gapR, -gapL)
            state = '重叠' if overlap > 0.5 else '分离'
        rows.append((t, gap, thin, state))
        if t % 80 == 0 or (gap > 0):
            print('  %5d  %.3f  %.3f  %.3f | %5.1f %5.1f %5.1f | %5.1f %6.1f %6.1f %s'
                  % (t, pOrb, pL, pR, pillL, pillR, orbX, gap, h, thin, state))
    necks = [r for r in rows if r[1] > 0]
    if necks:
        print('  → 腰可见时长 ≈ %d ms（%d~%d ms），最细处 %.1f vp（H=60）'
              % (necks[-1][0] - necks[0][0], necks[0][0], necks[-1][0],
                 min(n[2] for n in necks)))
    else:
        print('  → ⚠️ 全程没有出现腰（葫芦永远不会出现）')


run(300.0)
run(190.0)
run(430.0)
