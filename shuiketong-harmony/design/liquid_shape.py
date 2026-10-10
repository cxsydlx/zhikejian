# -*- coding: utf-8 -*-
"""量出真 metaball 的"山谷形状"，并用它重建轮廓 —— 与真值并排比对。

背景（2026-10-02）：
  用户第三次反馈"不像葫芦 / 从最上面和最下面开始 / 像抽搐的线屏"。
  根因不是参数量得不准，而是**构造方式错了**：
    旧几何 = 从"圆盖顶点"到"圆盖顶点"拉一条三次贝塞尔，整条下陷挤在 gap 宽的范围里
    → 缝越小，下陷摊得越窄 → 尖刺 / 蝴蝶结。
  真值（design/interaction-preview.html 的 gooWide：σ=12、阈值 0.444）量出来是
    一条**宽 ±35vp 的平缓山谷**，最深点在下陷处，两侧缓慢收回到圆顶。

本脚本做的事：
  ① 从真值抽出**归一化山谷形状** S(Δ)（Δ = 距缝中点的距离，vp），跨缝宽取平均
  ② 用 S 重建轮廓： yTop(x) = min( 并集的清晰上边界, PAD + A·S(Δ) )
     其中 A = (H − 腰厚)/2，腰厚来自 goo_calib.py 的 σ=12 实测表
  ③ 真值 / 新模型 / 现役几何 三排并排渲染 + 上边界数值逐点对照
"""
import math
from PIL import Image, ImageDraw, ImageFilter

R = 30.0
H = 2 * R
PAD = 24.0
SIGMA = 12.0
CUT = int(0.444 * 255)
K = 6
WIN = 40.0          # 山谷窗口半宽（vp）

# goo_calib.py（σ=12）量出来的真值表
NECK_THIN = [43.9, 41.1, 38.1, 34.5, 30.5, 25.5, 19.3, 9.3]
NECK_MAX = 14.60
# 现役 .ets 里那张表（σ=18 的，错的）
NECK_THIN_OLD = [50.4, 47.9, 45.1, 42.1, 38.9, 35.1, 30.9, 25.6, 18.6, 5.4]
NECK_MAX_OLD = 18.2


def thin_of(gap, table, gmax, step=2.0):
    if gap >= gmax:
        return None
    f = gap / step
    i = int(f)
    if i >= len(table) - 1:
        t = (gap - (len(table) - 1) * step) / (gmax - (len(table) - 1) * step)
        return table[-1] * (1 - max(0.0, min(1.0, t)))
    return table[i] + (table[i + 1] - table[i]) * (f - i)


# ---------------- 真值 ----------------

def true_alpha(gap, k=K):
    W = int((4 * R + gap + 2 * PAD) * k)
    Hh = int((H + 2 * PAD) * k)
    im = Image.new('L', (W, Hh), 0)
    d = ImageDraw.Draw(im)
    cy = (PAD + R) * k
    cx1 = (PAD + R) * k
    cx2 = (PAD + R + 2 * R + gap) * k
    for cx in (cx1, cx2):
        d.ellipse((cx - R * k, cy - R * k, cx + R * k, cy + R * k), fill=255)
    im = im.filter(ImageFilter.GaussianBlur(SIGMA * k))
    return im, cx1, cy


def true_top(gap, rel):
    """rel = 距左圆心的 vp 距离 → 上边界下陷（vp，0 = 清晰圆顶）。None = 该处无形状"""
    im, cx1, cy = true_alpha(gap)
    px = im.load()
    x = int(round(cx1 + rel * K))
    col = [y for y in range(im.height) if px[x, y] > CUT]
    if not col:
        return None
    return (col[0] - cy) / K + R


def true_bot(gap, rel):
    im, cx1, cy = true_alpha(gap)
    px = im.load()
    x = int(round(cx1 + rel * K))
    col = [y for y in range(im.height) if px[x, y] > CUT]
    if not col:
        return None
    return (col[-1] - cy) / K + R


# ---------------- 归一化山谷形状 S(Δ) ----------------

def extract_shape():
    """跨缝宽平均出 S(Δ)：Δ 单位 vp，S(0)=1，远处→0"""
    steps = [i * 2.0 for i in range(0, int(WIN / 2) + 1)]
    acc = [0.0] * len(steps)
    used = 0
    for gap in (8.0, 10.0, 12.0, 14.0):
        jc = R + gap / 2.0
        # ⚠️ 基准必须取**远场**（左圆自己的顶点 rel=0），不能取 Δ=-22 ——
        #    那里已经在山谷里了，归一化后形状会被硬截断在 Δ≈22。
        base = true_top(gap, 0.0)
        peak = true_top(gap, jc)                 # 缝中点
        span = peak - base
        for i, d in enumerate(steps):
            v = true_top(gap, jc + d)
            acc[i] += max(0.0, (v - base) / span)
        used += 1
    return steps, [a / used for a in acc]


# ---------------- 新模型 ----------------

SHAPE_STEPS: list = []
SHAPE_VALS: list = []


def shape_at(d):
    d = abs(d)
    if d >= SHAPE_STEPS[-1]:
        return 0.0
    i = int(d / 2.0)
    if i >= len(SHAPE_VALS) - 1:
        return SHAPE_VALS[-1]
    return SHAPE_VALS[i] + (SHAPE_VALS[i + 1] - SHAPE_VALS[i]) * (d / 2.0 - i)


def crisp_top(rel, gap):
    """两圆并集的清晰上边界（下陷 vp）。不在形状里返回 None"""
    best = None
    for c in (0.0, 2 * R + gap):
        dx = rel - c
        if abs(dx) <= R:
            v = R - math.sqrt(R * R - dx * dx)
            best = v if best is None else min(best, v)
    return best


def model_top(rel, gap, table=NECK_THIN, gmax=NECK_MAX):
    """返回**下陷量**（vp，0 = 清晰圆顶）。与 true_top 同量纲。"""
    t = thin_of(gap, table, gmax)
    A = None if t is None else (H - t) / 2.0
    c = crisp_top(rel, gap)
    jc = R + gap / 2.0
    d = rel - jc
    if A is None or abs(d) > WIN:
        return c
    v = A * shape_at(d)
    if c is None:
        return v
    return min(c, v)


# ---------------- 旧模型（现役 ArkTS 几何） ----------------

def old_top(rel, gap, table, gmax):
    """现役：从 pill 右盖顶点 (pillR-R) 到 圆中心 (orbX+R) 的三次贝塞尔。
    两圆模型里 = 左圆右顶点 → 右圆中心 x。"""
    t = thin_of(gap, table, gmax)
    if t is None:
        return None
    h = (H - t) / 1.5
    a = R                       # 左圆右顶点
    b = 2 * R + gap             # 右圆中心（= 右圆顶点）
    if rel < a or rel > b:
        return None
    u = (rel - a) / (b - a)
    k1 = a + 0.34 * (b - a)
    k2 = b - 0.34 * (b - a)
    mt = 1 - u
    y = (mt**3 * 0 + 3 * mt * mt * u * h + 3 * mt * u * u * h + u**3 * 0)
    return y


# ---------------- 渲染 ----------------

def render_true(gap):
    im, cx1, cy = true_alpha(gap)
    px = im.load()
    W, Hh = im.size
    out = Image.new('RGBA', (W, Hh), (246, 247, 250, 255))
    op = out.load()
    for y in range(Hh):
        for x in range(W):
            if px[x, y] > CUT:
                op[x, y] = (10, 89, 247, 255)
    return out, cx1


def render_model(gap, mode):
    W = int((4 * R + gap + 2 * PAD) * K)
    Hh = int((H + 2 * PAD) * K)
    im = Image.new('RGBA', (W, Hh), (246, 247, 250, 255))
    d = ImageDraw.Draw(im)
    cx1 = (PAD + R) * K
    rels = [(i / 2.0) for i in range(int((-R + 0.5) * 2), int((3 * R + gap - 0.5) * 2) + 1)]
    for sign in (-1, 1):
        pts = []
        for rel in rels:
            if mode == 'new':
                v = model_top(rel, gap)
            elif mode == 'new_oldtable':
                v = model_top(rel, gap, NECK_THIN_OLD, NECK_MAX_OLD)
            else:
                v = old_top(rel, gap, NECK_THIN_OLD, NECK_MAX_OLD)
            if v is None:
                continue
            y = (PAD + R + sign * (R - v)) * K
            pts.append((cx1 + rel * K, y))
        if sign == -1:
            top = pts
        else:
            bot = pts
    if top and bot:
        d.polygon([(x, y) for x, y in top] + [(x, y) for x, y in reversed(bot)],
                  fill=(10, 89, 247, 255))
    return im, cx1


def main():
    global SHAPE_STEPS, SHAPE_VALS
    steps, vals = extract_shape()
    SHAPE_STEPS, SHAPE_VALS = steps, vals
    print('=' * 100)
    print('① 归一化山谷形状 S(Δ)   （Δ = 距缝中点 vp；1.0 = 最深处）')
    print('   Δ :' + ''.join('%6.0f' % s for s in steps))
    print('   S :' + ''.join('%6.3f' % v for v in vals))
    print('   嵌入 ArkTS 用：')
    print('   const VALLEY: number[] = [%s];' % ', '.join('%.3f' % v for v in vals))
    print('   const VALLEY_STEP: number = 2;')

    print()
    print('=' * 100)
    print('② 上边界逐点对照（vp，0 = 圆顶；"--" = 那里没有形状）')
    for gap in (0.0, 6.0, 10.0, 14.0):
        print('  ---- 缝 %.1f ----' % gap)
        jc = R + gap / 2.0
        hdr, r1, r2, r3 = [], [], [], []
        for d in range(-34, 35, 4):
            rel = jc + d
            tv = true_top(gap, rel)
            nv = model_top(rel, gap)
            ov = old_top(rel, gap, NECK_THIN_OLD, NECK_MAX_OLD)
            f = lambda v: '  --' if v is None else '%4.1f' % v
            hdr.append('%5.0f' % d)
            r1.append('  ' + f(tv).strip().rjust(2))
            r2.append('  ' + f(nv).strip().rjust(2))
            r3.append('  ' + f(ov).strip().rjust(2))
        print('    Δ 距缝中点:' + ''.join(hdr))
        print('    真 metaball:' + ''.join(r1))
        print('    新模型     :' + ''.join(r2))
        print('    现役几何   :' + ''.join(r3))

    print()
    print('=' * 100)
    print('③ 并排渲染')
    gaps = (0.0, 5.0, 9.0, 12.0, 14.0)
    rows = []
    for gap in gaps:
        a, cx = render_true(gap)
        b, _ = render_model(gap, 'new')
        c, _ = render_model(gap, 'old')
        e, _ = render_model(gap, 'new_oldtable')
        x0 = int(cx - 38 * K)
        x1 = int(cx + (2 * R + gap + 38) * K)
        rows.append((gap, a.crop((x0, 0, x1, a.height)),
                     e.crop((x0, 0, x1, e.height)),
                     b.crop((x0, 0, x1, b.height)),
                     c.crop((x0, 0, x1, c.height))))
    pad = 8
    cellw = max(r[1].width for r in rows) + 2
    rowh = rows[0][1].height
    sheet = Image.new('RGB', (cellw * 4 + pad * 5, (rowh + 26) * len(rows) + 34), (255, 255, 255))
    dd = ImageDraw.Draw(sheet)
    names = ('TRUE metaball s=12', 'NEW  (s=12 table)', 'NEW  (s=18 table)', 'OLD  (current ArkTS)')
    for i, n in enumerate(names):
        dd.text((pad + i * (cellw + pad) + 4, 8), n, fill=(20, 20, 20))
    for r, (gap, *ims) in enumerate(rows):
        y = 34 + r * (rowh + 26)
        dd.text((pad, y + 2), 'gap=%.1f' % gap, fill=(20, 20, 20))
        for i, im in enumerate(ims):
            sheet.paste(im, (pad + i * (cellw + pad), y + 18), im)
    sheet.save('liquid-shape-compare.png')
    print('  -> liquid-shape-compare.png %s' % (sheet.size,))


if __name__ == '__main__':
    main()
