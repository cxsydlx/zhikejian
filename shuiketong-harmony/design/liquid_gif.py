# -*- coding: utf-8 -*-
"""把仿真帧合成成真速 GIF —— 装包之前先看动效。

用 msyh（微软雅黑）渲染中文标签，尽量贴近真机观感。
几何/时序仍是 LiquidToggle.ets 的逐条复算，不是另画一版。
"""
import os
from PIL import Image, ImageDraw, ImageFont
import liquid_render as NR




BOXW = 300
BG = (241, 243, 245)
FONT = None
for p in ('C:/Windows/Fonts/msyh.ttc', 'C:/Windows/Fonts/msyhbd.ttc',
          'C:/Windows/Fonts/simhei.ttf'):
    if os.path.exists(p):
        FONT = ImageFont.truetype(p, 15)
        print('font:', p)
        break


def composited(t, listening):
    im, _gap, _fill = NR.frame(BOXW, t, listening)
    base = Image.new('RGB', im.size, BG)
    base.paste(im, (0, 0), im)
    if FONT is not None:
        d = ImageDraw.Draw(base)
        txt = '停止听课' if listening else '开始听课'
        # 文字块中心 = 容器中心 + ±SPAN/2（与 ArkTS 的 labelShift 同一条推导）
        shift = NR.SPAN / 2 if listening else -NR.SPAN / 2
        cx = NR.PAD + BOXW / 2 + shift
        # ⚠️ 只平移。不加 shadow / opacity / scale ——
        # 用户 2026-10-07：「文字移动就行了，你加高光干什么」。
        d.text((cx, NR.PAD + NR.H / 2), txt, font=FONT, fill=(255, 255, 255),
               anchor='mm')
    return base


frames = []
# 静止 4 帧 → 去程 → 停 3 帧 → 回程 → 静 3 帧
for _ in range(4):
    frames.append(composited(0, False))
step = 20
t = 0
while t <= NR.TOTAL_MS:
    frames.append(composited(t, True))
    t += step
for _ in range(3):
    frames.append(composited(NR.TOTAL_MS, True))
t = NR.TOTAL_MS
while t >= 0:
    frames.append(composited(t, False))
    t -= step
for _ in range(4):
    frames.append(composited(0, False))

frames[0].save('liquid-preview.gif', save_all=True, append_images=frames[1:],
               duration=step, loop=0, optimize=False)
print('gif frames=%d  size=%s' % (len(frames), frames[0].size))
