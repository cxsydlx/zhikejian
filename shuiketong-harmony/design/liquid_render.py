# -*- coding: utf-8 -*-
"""LiquidToggle 的**唯一真源**：几何 + 时序 + 绘制，与 entry/.../view/LiquidToggle.ets 逐条对应。

## 为什么是"复制一份画出来"
本组件连续四轮翻车（v1 像素回读 → v2 逐帧 @State → v3 参数照抄 → v4 自编腰公式），
每轮都是"改完就发、靠用户眼睛验收"。真机一轮 5 分钟，而这个脚本 2 秒出图。
**改任何几何/时序前，先在这里看一遍。**

## 几何结论（都是量出来的，不是推的）
参考实现 = design/interaction-preview.html 的 `#gooWide`：σ=12、alpha 阈值 18a−8 (0.4444)。

1. `fill(gap)` —— 缝中点处上边界相对"清晰顶线"的下陷量（vp）。
   由 `goo_calib.py` 量出。**它就是山谷的深度**，等价于 (H−腰厚)/2。
   · 缝 −24 时只有 0.3（gooey 把 V 形缺口几乎填平）
   · 缝 0 时 8.0（两个圆刚接触就已经有浅谷）
   · 缝 14 时 25.2 → 腰厚 9.3
   · 缝 ≥ 14.9 → 30 = R → 上边界够到中线 → **断裂**
2. `VALLEY(Δ)` —— **归一化**的山谷形状（Δ = 距缝中点 vp，1.0 = 最深）。
   量出来的形状**宽 ±36vp**，不是一条窄缝。
   ⚠️ 旧几何从"圆盖顶点"到"圆盖顶点"拉一条三次贝塞尔，整条下陷挤在 ~±14vp 里
      → 尖刺 / 蝴蝶结 / "抽搐的线屏"。**这是那三轮"不像葫芦"的真正根因。**
3. 合成规则：`yTop(x) = 清晰并集(x) ∧ 山谷(x)`，其中山谷 = `fill·VALLEY(Δ)`，
   但**只在 |Δ| ≤ TAPER_OUT 的窗口内生效**，且从 TAPER_IN 起平滑并回清晰并集。
   `∧`（软 min）同时表达两件事：把凹角**填平**（缝为负时），把连接处**捏细**（缝为正时）。
   ⚠️ 2026-10-02 修：旧版把山谷铺满 ±36vp。缝为负时 `fill` 很小，那条趋近 0 的长尾
     会把圆球自己的圆弧肩部一起削平 —— 真机上就是"圆胶囊周围突然变方"。
     加窗口后缝附近误差从 5.8vp 降到 1.2vp（`_overlap_check.py` 逐点量真值验证）。

## 时序结论
缝 = 88·pL − 60 − (boxW−60)·(1−pOrb)。boxW=746 时第二项权重是 686 —— 只要圆还在动，
缝几乎完全由**圆的位置**主导，左端的位移被淹没。原时序（圆 580ms、左端 280ms 起）下：
  缝从 0 走到 14.4 只花了 **45ms**（0.75 帧群），葫芦根本来不及被看见。
新时序：**圆先到位（400ms），左端才开始退（400→920）**，于是缝只由 pL 决定，
三段曲线把 45% 的时长分给"缝 0→14.9"这一段 → 葫芦可见 234ms（14 帧 @60fps）。
"""
import math

from PIL import Image, ImageDraw

# ---------------- 几何常量（= .ets 的 H/PAD/GAP/SPAN） ----------------
H = 60.0
PAD = 20.0
GAP = 28.0
SPAN = H + GAP
R = H / 2
PI2 = math.pi * 2

# ---------------- 实测表 ----------------
# 缝 → 缝中点下陷量（vp）。design/goo_calib.py 量的，σ=12。
FILL_G0 = -24.0
FILL_STEP = 2.0
FILL = [0.3, 0.7, 1.0, 1.3, 1.8, 2.3, 3.0, 3.7, 4.3, 5.0,
        6.0, 6.8, 8.0, 9.5, 11.0, 12.8, 14.8, 17.2, 20.3, 25.2]
FILL_G_LAST = 14.0        # FILL 末项的缝宽
FILL_RAMP_TO = 14.9       # 从这里到断裂点线性收尾（下陷 25.2 → 30 = R）
NECK_GAP_MAX = 14.9

# 归一化山谷形状 S(Δ)，Δ = 0,2,...,36（vp）
VALLEY = [1.000, 0.983, 0.930, 0.855, 0.772, 0.678, 0.577, 0.487, 0.400, 0.320,
          0.249, 0.188, 0.133, 0.090, 0.055, 0.031, 0.012, 0.002, 0.000]
VALLEY_STEP = 2.0
VALLEY_MAX = (len(VALLEY) - 1) * VALLEY_STEP   # 36
# 软 min 带宽（= .ets 的 BLEND）。硬 min 会在山谷与圆盖弧的交点留下凸角折痕。
BLEND = 5.0
# 山谷的作用窗口（= .ets 的 TAPER_IN/TAPER_OUT）。
# ⚠️ 山谷**只能在缝附近说话**，远处必须把控制权平滑交还给"清晰并集"。
#    否则缝为负（两块重叠）时 fill 很小，`fill·VALLEY(Δ)` 拖着一条到 ±36vp 的长尾，
#    整条尾巴都≈0，`min` 就会把**圆球自己的圆弧肩部削成一条平线** —— 真机上看就是
#    "圆的周围突然变方"。2026-10-02 用 _overlap_check.py 逐点量真 metaball 抓到的：
#      缝 −22、Δ=+35：真值 5.8vp，旧模型 0.0vp（差 5.8）；加窗口后 4.6（差 1.2）。
TAPER_IN = 12.0
TAPER_OUT = 28.0

# ---------------- 时序 ----------------
# ⚠️ 2026-10-07：400→900（用户拍板总时长 1.42s）。原话「你这个动画的本质就是让它快速
#    移动，是不是？我说的是让它融合」—— 728vp/400ms 峰值 3410 vp/s，融合过程被位移
#    速度盖掉，只看得到一道蓝光划过去。900ms 后峰值 1520 vp/s，"交融成一整块"才看得见。
DUR_ORB = 900.0
# 快端 = 起步极快的 Hermite（用户拍板的方案 B）。旧值 320ms + FastOutSlowIn 的
# 起步斜率是 0，前期几乎不动 ⇒ gap 全靠圆推，峰值 5569 vp/s，凹槽在 33ms（2 帧）
# 内暴增 36.4vp —— 真机上就是"突然变大"。现在凹槽缩到 ~10ms，落在帧间空隙里。
DUR_FAST, DELAY_FAST = 70.0, 0.0
FAST_M0 = 4.0
DUR_SLOW, DELAY_SLOW = 520.0, 900.0
TOTAL_MS = DUR_SLOW + DELAY_SLOW               # 920
# 慢端位移节点与导数 —— 与 .ets 的 SLOW_* 一一对应。
# ⚠️ 段内**不是** easing，是三次 Hermite：FastOutSlowIn 两端导数为 0，三段各跑一条
#    会拼成「走-停-走-停-走」= 用户说的"抽搐"，回程时就是"细腰突然变大"。
#    节点导数显式给 ⇒ 全程 C¹ 连续，段边界不再归零。
SLOW_X1, SLOW_Y1, SLOW_M1 = 0.35, 0.682, 0.45
SLOW_X2, SLOW_Y2, SLOW_M2 = 0.80, 0.847, 0.15
SLOW_M0 = SLOW_M3 = 0.0
BREATHE_MS = 1600.0
VIS_OUT_START, VIS_OUT_END = 0.0, 110.0
# 淡入窗口跟着 DUR_ORB 走：圆 900ms 才到位，早于它淡入就会出现「幽灵呼吸灯」
VIS_IN_START, VIS_IN_END = DUR_ORB, DUR_ORB + 140.0

# ⚠️ 文字**只平移**。这里曾经有过 ink_at() 模拟白字晕染（shadow 扩散 + 淡出 + 微放大），
#    已按用户要求撤掉 —— 2026-10-07：「文字移动就行了，你加高光干什么」。


def bez_y(t, c1=0.4, c2=0.2):
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
    return 0.0 if x <= 0 else (1.0 if x >= 1 else bez_y(x))


def hermite(x0, y0, m0, x1, y1, m1, x):
    """三次 Hermite。m0/m1 是对 x 的导数（dpL/dx）"""
    w = x1 - x0
    u = (x - x0) / w
    u2 = u * u
    u3 = u2 * u
    return ((2 * u3 - 3 * u2 + 1) * y0 + (u3 - 2 * u2 + u) * m0 * w
            + (-2 * u3 + 3 * u2) * y1 + (u3 - u2) * m1 * w)


def fast_ease(el):
    """快端：起步极快（FAST_M0）、末端停稳的三次 Hermite。见 DUR_FAST 注释"""
    if el <= 0:
        return 0.0
    if el >= DUR_FAST:
        return 1.0
    return hermite(0, 0, FAST_M0, 1, 1, 0, el / DUR_FAST)


def slow_ease(x):
    if x <= 0:
        return 0.0
    if x >= 1:
        return 1.0
    if x < SLOW_X1:
        return hermite(0, 0, SLOW_M0, SLOW_X1, SLOW_Y1, SLOW_M1, x)
    if x < SLOW_X2:
        return hermite(SLOW_X1, SLOW_Y1, SLOW_M1, SLOW_X2, SLOW_Y2, SLOW_M2, x)
    return hermite(SLOW_X2, SLOW_Y2, SLOW_M2, 1, 1, SLOW_M3, x)



def neck_fill(gap):
    """缝 → 缝中点下陷量（vp）。缝 ≤ FILL_G0 或无连接 → 0；缝 ≥ 断裂点 → 不画"""
    if gap <= FILL_G0 or gap >= NECK_GAP_MAX:
        return 0.0
    if gap >= FILL_G_LAST:
        t = (gap - FILL_G_LAST) / (FILL_RAMP_TO - FILL_G_LAST)
        return FILL[-1] + (R - FILL[-1]) * t
    f = (gap - FILL_G0) / FILL_STEP
    i = int(f)
    return FILL[i] + (FILL[i + 1] - FILL[i]) * (f - i)


def valley_at(delta):
    d = abs(delta)
    if d >= VALLEY_MAX:
        return 0.0
    f = d / VALLEY_STEP
    i = int(f)
    return VALLEY[i] + (VALLEY[i + 1] - VALLEY[i]) * (f - i)


# ---------------- 场景几何 ----------------

def crisp_top(x, pillL, pillR, orbX):
    """圆 ∪ 长条 的清晰上边界（下陷 vp）。不在形状里 → None"""
    best = None
    if pillL <= x <= pillR:                       # 长条
        if x < pillL + R:
            d = x - (pillL + R)
            best = R - math.sqrt(max(R * R - d * d, 0.0))
        elif x > pillR - R:
            d = x - (pillR - R)
            best = R - math.sqrt(max(R * R - d * d, 0.0))
        else:
            best = 0.0
    c = orbX + R                                  # 圆
    if abs(x - c) <= R:
        d = x - c
        v = R - math.sqrt(max(R * R - d * d, 0.0))
        best = v if best is None else min(best, v)
    return best


def junction(pillL, pillR, orbX):
    """返回 (缝中点 x, 缝宽)。圆在长条右侧取右缝，否则取左缝"""
    cx_pill = (pillL + pillR) / 2.0
    cx_orb = orbX + R
    if cx_orb >= cx_pill:
        return (pillR + orbX) / 2.0, orbX - pillR
    return (pillL + orbX + H) / 2.0, pillL - (orbX + H)


def dep_at(x, pillL, pillR, orbX, jc, fill):
    """上边界相对顶线的下陷量（vp）= min(清晰并集, 山谷)。与 .ets 的 depAt 一一对应"""
    c = crisp_top(x, pillL, pillR, orbX)
    if c is None:
        c = R
    if fill > 0.01:
        ad = abs(x - jc)
        if ad < VALLEY_MAX:
            v = fill * valley_at(x - jc)
            t = v
            # 山谷只在缝附近全权生效；超出 TAPER_IN 后平滑并回清晰并集，
            # 否则小 fill 时那条趋近 0 的长尾会把圆球自己的圆弧肩部削平（"变方"）。
            if ad > TAPER_IN:
                w = 0.0 if ad >= TAPER_OUT else 1.0 - (ad - TAPER_IN) / (TAPER_OUT - TAPER_IN)
                t = c + (v - c) * w
            if t < c:
                c = t
            elif t - c < BLEND:
                d = t - c
                c = c + d * d / (4 * BLEND)
    return c


CAP_DEG = 2.0
STEP_NEAR, STEP_MID, STEP_FAR = 0.8, 1.6, 3.2
SAMPLE_NEAR, SAMPLE_MID, CAP = 24.0, 60.0, 1600


def outline(boxW, pOrb, pL, pR):
    """返回 (top_pts, bot_pts, gap, fill)，画布坐标。
    两端圆盖按**角度**采样（端点是垂直切线，按 x 采样会切出竖直硬棱）。"""
    pillL = PAD + pL * SPAN
    pillR = PAD + boxW - SPAN + pR * SPAN
    orbX = PAD + (1 - pOrb) * (boxW - H)
    jc, gap = junction(pillL, pillR, orbX)
    fill = neck_fill(gap)

    c_l = (pillL + R) if pillL <= orbX else (orbX + R)
    c_r = (pillR - R) if pillR >= orbX + H else (orbX + R)
    xs = []
    a = 0.0
    while a <= 90.0:
        xs.append(c_l - R * math.cos(math.radians(a)))
        a += CAP_DEG
    x = c_l + STEP_FAR
    while x < c_r - STEP_FAR and len(xs) < CAP - 100:
        ad = abs(x - jc)
        xs.append(x)
        x += STEP_NEAR if ad < SAMPLE_NEAR else (STEP_MID if ad < SAMPLE_MID else STEP_FAR)
    a = 90.0
    while a >= 0.0:
        xs.append(c_r + R * math.cos(math.radians(a)))
        a -= CAP_DEG

    top, bot = [], []
    for xx in xs:
        c = dep_at(xx, pillL, pillR, orbX, jc, fill)
        top.append((xx, PAD + c))
        bot.append((xx, PAD + H - c))
    return top, bot, gap, fill


# ---------------- 绘制（1:1 复现 Canvas） ----------------
LIQ = (10, 89, 247)
INK = (255, 255, 255)
SS = 3
IK = 8


def icon_mic(pop):
    S = IK
    im = Image.new('RGBA', (24 * S, 24 * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((9 * S, 2.6 * S, 15 * S, 13.8 * S), radius=3 * S, fill=INK)
    d.arc((12 * S - 6.8 * S, 11.2 * S - 6.8 * S, 12 * S + 6.8 * S, 11.2 * S + 6.8 * S),
          start=0, end=180, fill=INK, width=int(round(2 * S)))
    d.line((12 * S, 18 * S, 12 * S, 21.2 * S), fill=INK, width=int(round(2 * S)))
    n = max(int(26 * pop * SS), 1)      # ⚠️ 目标尺寸要乘 SS（画布是 SS 倍超采样）
    return im.resize((n, n), Image.LANCZOS)


def icon_vis(el):
    if el <= VIS_OUT_START:
        return 1.0
    if el < VIS_OUT_END:
        return 1.0 - (el - VIS_OUT_START) / (VIS_OUT_END - VIS_OUT_START)
    if el < VIS_IN_START:
        return 0.0
    if el < VIS_IN_END:
        return (el - VIS_IN_START) / (VIS_IN_END - VIS_IN_START)
    return 1.0


def frame(boxW, el, listening):
    cw, ch = int((boxW + 2 * PAD) * SS), int((H + 2 * PAD) * SS)
    im = Image.new('RGBA', (cw, ch), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)

    pOrb = prog(el, DUR_ORB, 0)
    pR = fast_ease(el)
    pL = slow_ease((el - DELAY_SLOW) / DUR_SLOW)

    top, bot, gap, fill = outline(boxW, pOrb, pL, pR)
    poly = [(x * SS, y * SS) for x, y in top] + [(x * SS, y * SS) for x, y in reversed(bot)]
    d.polygon(poly, fill=LIQ + (255,))

    # 图标：圆心 = 圆的最左点 + R
    orbX = PAD + (1 - pOrb) * (boxW - H)
    cx, cy = orbX + R, PAD + R
    vis = icon_vis(el)
    if vis > 0.01:
        mic = (1 - pOrb) * vis
        light = pOrb * vis
        if mic > 0.02:
            ic = icon_mic(1 - 0.42 * pOrb)
            ic.putalpha(ic.getchannel('A').point(lambda v: int(v * mic)))
            im.alpha_composite(ic, (int(cx * SS - ic.width / 2), int(cy * SS - ic.height / 2)))
        if light > 0.02:
            br = 0.35 + 0.65 * (0.5 - 0.5 * math.cos(PI2 * (el % BREATHE_MS) / BREATHE_MS))
            pop = 0.6 + 0.4 * pOrb
            lay = Image.new('RGBA', im.size, (0, 0, 0, 0))
            dl = ImageDraw.Draw(lay)
            hr = 9 * pop * (0.72 + 0.5 * br)
            dl.ellipse(((cx - hr) * SS, (cy - hr) * SS, (cx + hr) * SS, (cy + hr) * SS),
                       fill=INK + (int(255 * light * 0.42 * br),))
            cr = 4.5 * pop
            dl.ellipse(((cx - cr) * SS, (cy - cr) * SS, (cx + cr) * SS, (cy + cr) * SS),
                       fill=INK + (int(255 * light),))
            im.alpha_composite(lay)

    # 文字块（示意白条）
    shift = SPAN / 2 if listening else -SPAN / 2
    lc = PAD + boxW / 2 + shift
    lay = Image.new('RGBA', im.size, (0, 0, 0, 0))
    ImageDraw.Draw(lay).rounded_rectangle(
        ((lc - 22) * SS, (PAD + R - 9) * SS, (lc + 22) * SS, (PAD + R + 9) * SS),
        radius=9 * SS, fill=INK + (95,))
    im.alpha_composite(lay)

    return im.resize((int(boxW + 2 * PAD), int(H + 2 * PAD)), Image.LANCZOS), gap, fill


def _demo(boxW=746.0):
    print('=' * 96)
    print('① 新时序下 boxW=%.0f 的缝宽随时间（缝 = 88·pL − 60 − 686(1−pOrb)）' % boxW)
    print('   t(ms)  pOrb   pL     pR   |   缝    下陷   状态')
    neck_ms = 0
    for t in range(0, int(TOTAL_MS) + 1, 20):
        pOrb = prog(t, DUR_ORB, 0)
        pR = prog(t, DUR_FAST, DELAY_FAST)
        pL = slow_ease((t - DELAY_SLOW) / DUR_SLOW)
        pillL = PAD + pL * SPAN
        pillR = PAD + boxW - SPAN + pR * SPAN
        orbX = PAD + (1 - pOrb) * (boxW - H)
        jc, gap = junction(pillL, pillR, orbX)
        f = neck_fill(gap)
        if 0 < gap < NECK_GAP_MAX:
            st = '★拉丝'
            neck_ms += 20
        elif gap < 0:
            st = '重叠 %.0f' % -gap
        elif gap < GAP:
            st = '分离 %.0f' % gap
        else:
            st = '静止分离'
        if t % 80 == 0 or st == '★拉丝':
            print('   %5d  %.3f  %.3f  %.3f | %6.1f %6.1f  %s' % (t, pOrb, pL, pR, gap, f, st))
    print('   → 拉丝可见 ≈ %d ms（%.0f 帧 @60fps）' % (neck_ms, neck_ms / 16.7))

    print()
    print('=' * 96)
    print('② 胶片（boxW=%.0f）' % boxW)
    times = [0, 100, 250, 380, 500, 560, 620, 680, 740, 800, 830, 870]
    tiles = []
    for t in times:
        im, gap, fill = frame(boxW, float(t), True)
        tiles.append((t, im, gap, fill))
    pad = 6
    tw = max(t[1].width for t in tiles)
    th = tiles[0][1].height
    sheet = Image.new('RGB', (tw + pad * 2, (th + 22) * len(tiles) + 10), (250, 251, 253))
    dd = ImageDraw.Draw(sheet)
    for i, (t, im, gap, fill) in enumerate(tiles):
        y = 6 + i * (th + 22)
        dd.text((8, y), 't=%dms   gap=%.1f  fill=%.1f' % (t, gap, fill), fill=(20, 20, 20))
        sheet.paste(im, (pad, y + 14), im)
    sheet.save('liquid-film.png')
    print('   -> liquid-film.png %s' % (sheet.size,))


if __name__ == '__main__':
    _demo()
