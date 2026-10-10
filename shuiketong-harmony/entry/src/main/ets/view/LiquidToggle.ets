/*
 * LiquidToggle —— 液体伸缩听课键。
 *
 * 交互原型：design/interaction-preview.html 第 2 节。参考实现是那个文件的
 * `<filter id="gooWide">`：`feGaussianBlur stdDeviation=12` + alpha 矩阵 `18a-8`（阈值 0.4444）。
 *
 * ## 形态
 * 一条胶囊，内部是**两块同色液体**：
 *   · 未开始：文字块「开始听课」在左，圆形图标块（麦克风）在右
 *   · 已开始：圆滑到最左、图标**变身**成呼吸灯，文字块（「停止听课」）让到右边
 * **两个静止态都是 28vp 的完全分开。** 葫芦只属于过程，绝不在静止态出现。
 *
 * ============================================================
 * ## 腰部几何：为什么改成"整条轮廓采样"，而不是"两块之间补一道桥"
 *
 * 前面四版都在"把两块各自画好、再往中间补一个连接形状"这条路上打转，全部失败：
 *   v1 `ctx.filter` 模糊 + getImageData 逐像素阈值化 → 真机极卡（GPU→CPU 回读）
 *   v2 逐帧 `@State` 驱动 ArkUI 布局属性 → 每帧重布局 + 文字重排 → 掉帧
 *   v3 参数照抄，v4 自编腰公式 `h=(4R/3)(gap/24)^1.2` → "一坨胖桥"，用户："抽搐的线屏"
 *
 * **根因是构造方式，不是参数**。真 metaball 的腰部不是"窄缝里的一道桥"：
 * 把 σ=12 的参考滤镜量出来（`design/goo_calib.py`），缝中点处上边界的下陷量是
 *   缝 −24 → 0.3vp（gooey 把 V 形缺口几乎填平）
 *   缝  0  → 8.0vp（两个圆刚接触就已经有浅谷）
 *   缝 14  → 25.2vp → 腰厚 9.3，**宽 ±36vp 的平缓山谷**
 * 它是**一整条被啃掉的宽谷**。旧几何把整条下陷挤在 ±14vp 里 → 必然长成尖刺。
 *
 * 所以本版改成：**把并集的整条轮廓按"清晰边界 ∧ 山谷"采样成多边形**：
 *
 *     yTop(x) = 圆∪长条 的清晰上边界(x)  ∧  fill(缝) · VALLEY(|x − 缝中点|)
 *
 * 一条 `∧`（软 min，见 BLEND）同时表达两件事，不需要任何窗口判断：
 *   · 缝为负（两块重叠）→ 山谷很浅 → `∧` 取山谷 → 把 V 形凹角**填平**（补角）
 *   · 缝为正（两块分离）→ 山谷很深 → `∧` 取山谷 → 把连接处**捏细**（拉丝）
 *   · 远离缝中点 → 清晰边界更靠上 → `∧` 自动切回清晰边界
 * 而且它是**单调收敛**的：缝 ≥ 14.9 时 fill 触到 R，上边界够到中线 → 自然断裂。
 *
 * ⚠️ 但山谷**只能在缝附近说话**（见 TAPER_IN）。铺满整条 ±36vp 山谷是 2026-10-02
 *    那个「圆胶囊周围突然变方」的根因：缝为负时 fill 很小，山谷那条趋近 0 的长尾
 *    会把圆球自己的圆弧肩部一起削平。所以从 TAPER_IN 起把它平滑并回清晰边界。
 *
 * ## 两张表都是量出来的，不是推的
 * · `FILL`   —— 缝 → 缝中点下陷量（= (H−腰厚)/2）。`design/goo_calib.py` 量的。
 * · `VALLEY` —— 归一化山谷形状。`design/liquid_shape.py` 抽的（跨缝宽平均）。
 * **要改腰，只能重跑这两个脚本拿新表；不要再写任何自编公式。**
 *
 * ## 时序：葫芦曾经几乎没有可见时间
 * 缝 = 88·pL − 60 − (boxW−60)·(1−pOrb)。boxW=746 时第二项权重是 **686** ——
 * 只要圆还在动，缝就完全由**圆的位置**主导，左端的位移被淹没。
 * 原时序（圆 580ms、左端 280ms 起、三段曲线按"断裂点 18.2"分配）下：
 * 缝从 0 走到 14.4 只花 **45ms**（≈3 帧），葫芦来不及被看见；而占 60% 时长的
 * 第三段（缝 14.3→28）已经**断裂之后**了 —— 时间全花在"两块分开漂"上。
 *
 * 本版：**圆先到位（400ms），左端才开始退（400→920）**，于是缝只由 pL 决定；
 * 三段曲线按真实断裂点 14.9 重分 → 缝 0→14.9 拿到 45% 时长。
 * 结果：葫芦可见 **≈260ms（16 帧 @60fps）**，总时长 920ms。
 *
 * ## 性能三条硬规矩（v1/v2 各栽一次）
 * 1. **逐帧变化的值绝不能是 `@State`** —— 一改就是一次 build；build 里含 width/position
 *    就是重新布局，`Text().width()` 变还会触发**文字重新测排**。进度值放普通字段，
 *    只重绘 Canvas；状态驱动部分交给原生 `animateTo` 且只用 `translate`（变换不重排）。
 * 2. **帧回调用 `displaySync`（vsync）**，不用 `setInterval(16)`：与 vsync 不对齐会抖动。
 * 3. **不碰 `getImageData`**：GPU→CPU 回读，每帧三趟全画布搬运 = 主线程跪。
 * 逐帧只有一次多边形 fill，采样点数组**复用**（不每帧 new）。
 *
 * ## 两条硬约束（原型阶段各踩过一次）
 * 1. **参与融合的两块必须同色**。不同色时「融合」只是半透明叠加 + 边缘柔化。
 * 2. **形状规则全程一致**。圆角/尺寸在过渡里变来变去，中间帧会像被重新渲染。
 *
 * ## 坐标系：画布为什么比可视区大一圈
 * 宽度 = boxW + PAD*2，而 boxW 首次渲染时是 0 —— PAD 归零会让画布初始尺寸也是 0，
 * 渲染引擎可能直接跳过 0 尺寸组件，onReady 不触发 → 永远不画。
 * 留着 PAD，初始就有 40×100 的实体，onReady 必定触发，之后 onAreaChange 再喂真实宽度。
 */
import { curves } from '@kit.ArkUI';
import { displaySync } from '@kit.ArkGraphics2D';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FontSize, Weight } from '../common/DesignToken';

/** 组件可视高度 —— 也是圆的直径（两态共用同一个值，形状因此永远一致） */
const H: number = 60;
/** 画布四周外扩量。只为让初始画布非零尺寸（见文件头） */
const PAD: number = 20;
/** 两个静止态里圆与长条之间的缝 */
const GAP: number = 28;
/** 一个静止态里让给「圆 + 缝」的整段宽度。长条两端各自位移的量就是它 */
const SPAN: number = H + GAP;
/** 圆（也是长条两端圆盖）的半径 */
const R: number = H / 2;
const PI2: number = Math.PI * 2;
const ICON_RATE: ExpectedFrameRateRange = { expected: 60, min: 30, max: 120 };

/* ============================================================
   实测表 A：缝 → 缝中点下陷量（vp）
   `design/goo_calib.py`：真跑高斯模糊(σ=12) + alpha 阈值 0.444，
   再在缝中点逐列数像素。σ 必须与参考滤镜的 gooWide 一致 ——
   曾误用 σ=18 的表，腰凭空粗 6~10vp、断裂点从 14.6 拖到 18.2。
   ============================================================ */
/** 表起点缝宽。比它更重叠时山谷已经平到看不见（< 0.3vp），直接当 0 */
const FILL_G0: number = -24;
/** 表相邻两点的缝宽间隔 */
const FILL_STEP: number = 2;
/** 缝 → 下陷量。缝 −24,−22,...,14 共 20 项 */
const FILL: number[] = [
  0.3, 0.7, 1.0, 1.3, 1.8, 2.3, 3.0, 3.7, 4.3, 5.0,
  6.0, 6.8, 8.0, 9.5, 11.0, 12.8, 14.8, 17.2, 20.3, 25.2
];
/** FILL 末项对应的缝宽 */
const FILL_G_LAST: number = 14;
/** 断裂点：下陷触到 R，上边界够到中线，连接消失 */
const NECK_GAP_MAX: number = 14.9;

/* ============================================================
   实测表 B：归一化山谷形状 VALLEY(Δ)
   Δ = 距缝中点的距离（vp），1.0 = 最深处。
   `design/liquid_shape.py` 从真值 profile 抽出来、跨缝宽平均。
   ⚠️ 注意**它延伸到 36vp** —— 这就是"宽谷"，旧几何只有 ±14vp。
   ============================================================ */
const VALLEY: number[] = [
  1.000, 0.983, 0.930, 0.855, 0.772, 0.678, 0.577, 0.487, 0.400, 0.320,
  0.249, 0.188, 0.133, 0.090, 0.055, 0.031, 0.012, 0.002, 0.000
];
const VALLEY_STEP: number = 2;
const VALLEY_MAX: number = (VALLEY.length - 1) * VALLEY_STEP;   // 36

/* ============================================================
   时间轴
   ============================================================ */

/**
 * 调试用时间缩放。**正常必须是 1。**
 * 真机 `snapshot_display` 每帧要 ~230ms，而一趟动画只有 920ms —— 连拍只能抓到
 * 三四个中间帧，没法逐帧验收形状。临时改成 8 把整趟拉到 7.4s，看清每一段再改回来。
 */
const TS: number = 1;

/**
 * 帧率探针。**每 60 帧打一次平均帧间隔到 hilog**，开销可忽略。
 * 用途：`hdc shell hilog -x | grep LiquidToggle` → 期望 avg ≈ 16.7ms。
 * 用户反复报过"非常卡、帧率很低"，而截图只能证明形状对、证明不了帧率，
 * 所以留一个能直接读数的出口（不需要时把 DBG_FPS 置 false 即可）。
 */
const DBG_FPS: boolean = true;
const DBG_FPS_N: number = 20;
const LOG_TAG: string = 'LiquidToggle';


/**
 * 圆的位移时长。**必须在下述 DELAY_SLOW 之前走完** —— 否则缝由圆的位置主导（见文件头）。
 *
 * ⚠️ 2026-10-07 从 400 拉到 900（用户拍板总时长 1.42s）：
 * 用户原话「你这个动画的本质就是让它快速移动，是不是？我说的是让它融合」。
 * 728vp / 400ms ⇒ 峰值 3410 vp/s，**融合过程被位移速度盖掉**，只看得到一道蓝光划过去。
 * 拉到 900ms 后峰值 1520 vp/s（慢 2.2 倍），"两团交融成一整块"的过程才看得见。
 */
const DUR_ORB: number = 900 * TS;

/**
 * 先动的那一端 —— 去程是长条**右端**（向右扩张把圆吞掉），回程镜像。
 *
 * ⚠️ 这段的时长与曲线是 2026-10-02 第三次重调的原因（用户：「中间还有一段突然变大」）。
 *
 * ## 问题
 * `gap`（两块边缘的距离）在动画最开头会被**两个反向运动的部件叠加**推着走：
 *   gap = 28 − 88·pR − (boxW−60)·pOrb
 * 圆要在 400ms 内横跨 728vp（峰值 3410 vp/s），而旧参数 pR 走 320ms 的 FastOutSlowIn
 * —— 它的**起步斜率为 0**，前期几乎不动。于是 gap 全靠圆推，峰值 **5569 vp/s**，
 * 缝中点在 33ms（**2 帧**）内从「有颈区」穿到「深度重叠」，颈（凹槽）**暴增 36.4vp**。
 * 真机上就是：凹槽闪 1~2 帧，形状突然变粗。
 *
 * ## 修法（用户拍板的方案 B：长条先吞圆，凹槽不出现）
 * pR 改用**起步极快**的三次 Hermite（起点斜率 4），在圆还没来得及动之前就把 gap
 * 推到 −24 以下（= 无颈区）。有颈区因此缩到 ~10ms，**落在两帧之间的空隙里，
 * 不会被渲染出来**。
 *   320ms/FastOutSlowIn → 33.3ms（2 帧，+36.4vp/帧）  ← 旧
 *   70ms/Hermite m0=4   → ~10ms（0~0.6 帧，0vp/帧）    ← 新
 * 视觉上变成「啪地贴上」，正是想要的。
 */
const DUR_FAST: number = 70 * TS;
const DELAY_FAST: number = 0;
/** 快端 Hermite 的起点斜率。4 = 一开始就全力冲，10ms 内基本到位 */
const FAST_M0: number = 4.0;

/** 后动的那一端 —— 去程是**左端**：最后才让位，这一步就是「拉开」并露出腰 */
const DUR_SLOW: number = 520 * TS;
/**
 * 慢端延迟。**必须 ≥ DUR_ORB**（圆先到位，它一停慢端才开始，缝才只由 pL 决定）。
 * 2026-10-07 随 DUR_ORB 400→900 同步改为 900，总时长 = 900 + 520 = **1420ms**。
 */
const DELAY_SLOW: number = 900 * TS;

/**
 * 慢端位移曲线 —— **三次 Hermite 分段插值**（不是三次贝塞尔）。
 *
 * ## 为什么不能每段各用一条 easing
 * 旧版把慢端拆成三段、每段各跑一次 `CURVE_STD`（FastOutSlowIn）。但 **FastOutSlowIn
 * 两端导数都等于 0**，拼起来就成了「走 → 停 → 走 → 停 → 走」：
 *
 *   | 段 | x 区间 | 时长 | 割线速度 dpL/dx | 折合 gap 速度 | 段首 | 段末 |
 *   |---|---|---|---|---|---|---|---|
 *   | ① | 0 → 0.35 | 182ms | 1.949 | 171 vp/s | **0** | **0** |
 *   | ② | 0.35 → 0.80 | 234ms | 0.367 | 32 vp/s | **0** | **0** |
 *   | ③ | 0.80 → 1 | 104ms | 0.765 | 67 vp/s | **0** | **0** |
 *
 * 段②（拉丝段）的平均速度只有段①的 **1/5**，却在两端急停 —— 视觉上就是
 * 「抽搐」：每次停顿后猛地加速。回程时腰本来在变粗，停顿后猛冲 = 「细腰突然变大」。
 *
 * ## 本版
 * 三段都换成**三次 Hermite**，节点导数显式给定，于是全程 **C¹ 连续**：
 *   · 段①末 = 段②首 = 0.45   （不归零）
 *   · 段②末 = 段③首 = 0.15   （不归零，且**刻意压低**）
 * 两端 m=0 是对的（点击起步 / 收尾停稳）。
 *
 * 节点 (x, pL)：(0,0) → (0.35,0.682) → (0.80,0.847) → (1,1)
 * 分界点按**真实断裂点 14.9** 反解：gap = 88·pL − 60，缝 0 ↔ pL 0.682，缝 14.9 ↔ pL 0.847。
 *
 * ## m2 = 0.15 是调出来的，不是拍的
 * `m2` 决定断裂前的快慢。实测（对 pL 曲线数值微分 + `neckFill` 反算腰厚）：
 *   m2=0.496 → 断裂耗时 10.5ms（**0.6 帧**）→ 细腰"唰"地消失，看不清
 *   m2=0.150 → 断裂耗时 25.5ms（**1.5 帧**）
 *   m2=0.100 → 断裂耗时 30.0ms（1.8 帧，收益已很小）
 * 取 0.15：断裂从容，且段③以 0.15 起步 → 两块弹开的那 13.1vp 不会"突然变大"。
 */
const SLOW_X1: number = 0.35;
const SLOW_Y1: number = 0.682;
const SLOW_M1: number = 0.45;
const SLOW_X2: number = 0.80;
const SLOW_Y2: number = 0.847;
const SLOW_M2: number = 0.15;
const SLOW_M0: number = 0.0;
const SLOW_M3: number = 0.0;


/** 一趟动画总时长 */
const TOTAL_MS: number = DELAY_SLOW + DUR_SLOW;

/**
 * 图标显隐窗口 —— 圆在长条**内部**穿过的这一段必须把图标藏起来：
 * 图标是白的、文字也是白的，白图标从白字上滑过会糊成一团。
 *
 * ⚠️ 淡出必须**从点击那一刻就开始**（0 → 110），不能留到 120~300。
 * 真机实测（2026-10-02 连拍）：窗口取 120~300 时，圆在 el≈200 已经钻进长条
 * 且长条已铺满整幅，此时图标还有 30% 不透明度 —— 一枚**幽灵麦克风**压在
 * 「停止听课」文字上，很脏。圆在 el≈45 就与长条重叠了，所以淡出要更快。
 * ⚠️ 淡入窗口必须**跟着 DUR_ORB 走**：圆 900ms 才到位，早于它淡入就会出现
 * 「幽灵呼吸灯」。2026-10-07 起改为 DUR_ORB → DUR_ORB+140。
 */
const VIS_OUT_START: number = 0;
const VIS_OUT_END: number = 110 * TS;
const VIS_IN_START: number = DUR_ORB;
const VIS_IN_END: number = DUR_ORB + 140 * TS;


/**
 * ⚠️ 这里曾经放过「白字晕染」（shadow 扩散 + 淡出 + 微放大），**已按用户要求撤掉** ——
 * 2026-10-07：「文字移动就行了，你加高光干什么」。
 * 文字层只保留 `translate` 平移：不加光晕、不淡出、不缩放。
 * 液体本身的融合感全部由 Canvas 那侧的几何与时序负责（见 DUR_ORB）。
 */

/** 呼吸灯一轮（往返）时长 */
const BREATHE_MS: number = 1600;


/**
 * 文字块的横向偏移：未开始 -44 / 已开始 +44。
 * 推导：长条中心 = (左端+右端)/2，两态两端各平移 SPAN，故中心位移恒为 ±SPAN/2 ——
 * **与容器宽度无关**，所以这是个常数，旋转屏幕也不用重算。
 */
const LABEL_SHIFT: number = SPAN / 2;

/** 轮廓采样：缝中点附近要密（那里是尖腰），远处可以粗（直线 / 大半径弧） */
const SAMPLE_NEAR: number = 24;
const SAMPLE_MID: number = 60;
const STEP_NEAR: number = 0.8;
const STEP_MID: number = 1.6;
const STEP_FAR: number = 3.2;
/** 两端圆盖的角度采样步长（度）。按 x 采样会在端点上切出竖直硬棱（见 draw） */
const CAP_DEG: number = 2;
/** 采样数组容量。boxW ≤ 1200 时够用（两个圆盖各 46 点 + 中段 ~300 点） */
const SAMPLE_CAP: number = 1600;

/**
 * `min(清晰并集, 山谷)` 的**软**化带宽。
 *
 * 硬 `min` 在两条曲线相交处会留下一个折点：山谷那侧斜率浅、圆盖弧那侧斜率陡，
 * 斜率的跳变在真机放大图里是一条可见的"肩线"（真 gooey 那里是平滑过渡）。
 * 用一个二次圆角把折点磨掉：`c = min + (差)² / (4·BLEND)`，
 * 最大抬升量只有 BLEND/4 ≈ 1.2vp —— 肉眼不可见，但折痕没了。
 */
const BLEND: number = 5;

/**
 * 山谷的作用窗口。**山谷只能在缝附近说话，远处必须把控制权交还给清晰并集。**
 *
 * ⚠️ 这是 2026-10-02 修掉「圆胶囊周围突然变方」的那一刀。
 * 旧版把山谷铺满 `VALLEY` 的全部 ±36vp。缝为**负**（两块重叠）时 `fill` 很小，
 * `fill·VALLEY(Δ)` 整条尾巴都趋近 0，而 `min` 取小值 —— 于是那条"接近 0 的尾巴"
 * 把**圆球自己的圆弧肩部**也削成了一条平线，圆看起来就方了。
 *
 * 用 `_overlap_check.py` 对真 metaball 逐点量（长条∪圆，σ=12，阈值 0.444）：
 *   缝 −22、Δ=+31：真值 3.5vp，旧模型 0.0vp（差 −3.5）
 *   缝 −22、Δ=+35：真值 5.8vp，旧模型 0.0vp（差 −5.8）
 * 加窗口后同两点分别是 2.5 / 4.6（差 −1.0 / −1.2）。
 * 全缝宽扫描：缝附近最大误差 5.83 → 1.36vp；正缝（0~14.5）与静止态完全不变。
 *
 * 取 12/28 的依据：窗口在 8/20 ~ 14/32 区间内结果逐点相同（误差 ≤1.36vp），
 * 16/36 开始变差（1.68）。取中值，对几何变动最不敏感。
 */
const TAPER_IN: number = 12;
const TAPER_OUT: number = 28;

/** = Motion.curveStandard（FastOutSlowIn）。用同一条曲线，别引入第二种节奏 */
const CURVE_STD = curves.cubicBezierCurve(0.4, 0.0, 0.2, 1.0);

@Component
export struct LiquidToggle {
  /** 是否正在听课（外部状态，本组件只负责画和回调） */
  @Prop @Watch('onListeningChanged') listening: boolean = false;
  @Prop labelIdle: string = '开始听课';
  @Prop labelActive: string = '停止听课';
  /** 点击回调。动画进行中不会触发（见 build 里的 onClick） */
  onToggle: () => void = () => {};

  /**
   * 液体底色与「液体之上」的图标/文字色，由父组件喂进来。
   * ⚠️ 不在这里订阅 `Theme.onChange`：`Theme.listeners` 只 push 不删，
   *   子组件订阅会让每次页面重建都多留一个指向已销毁实例的回调。
   *   改由父组件的 `@State` 驱动（深浅色一变值就变，`@Watch` 触发重绘）。
   */
  @Prop @Watch('onSkinChanged') liquid: string = '#0A59F7';
  @Prop ink: string = '#FFFFFF';

  /**
   * 文字块横向偏移。**唯一**逐帧变化的 ArkUI 状态 —— 但它由原生属性动画插值
   * （`animateTo`），不走逐帧 JS；`translate` 是变换、不触发重新布局。
   */
  @State private labelShift: number = -LABEL_SHIFT;
  /** 实测宽度（onAreaChange 喂进来）。宽度未知时不画，否则坐标全是错的 */
  @State private boxW: number = 0;

  private ctx: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private ready: boolean = false;
  /** vsync 帧回调 —— 替代 setInterval，逐帧对齐刷新 */
  private ds: displaySync.DisplaySync | null = null;
  private ticking: boolean = false;

  /* ---- 以下全部是**普通字段**：逐帧改它们不会让 ArkUI 重建 ---- */
  private animating: boolean = false;
  private t0: number = 0;
  private el: number = TOTAL_MS;
  private pOrb: number = 0;
  private pL: number = 0;
  private pR: number = 0;
  private fromOrb: number = 0;
  private toOrb: number = 0;
  private fromL: number = 0;
  private toL: number = 0;
  private fromR: number = 0;
  private toR: number = 0;
  /** 本次是去程（true）还是回程 —— 决定哪一端先动 */
  private goingOn: boolean = false;
  private breatheT0: number = 0;
  private breathe: number = 0.35;
  /** 帧率探针的累加器（普通字段，不参与 build） */
  private fpsN: number = 0;
  private fpsT0: number = 0;

  /** 轮廓采样缓存（复用，不每帧 new —— 见性能规矩 3） */
  private xs: number[] = [];
  private dps: number[] = [];
  private nSamples: number = 0;
  /** junction() 的出参容器（同样是复用，避免每帧 new 一个小数组） */
  private jcOut: number[] = [0, 0];

  aboutToAppear(): void {
    const v: number = this.listening ? 1 : 0;
    this.pOrb = v;
    this.pL = v;
    this.pR = v;
    this.fromOrb = v;
    this.toOrb = v;
    this.fromL = v;
    this.toL = v;
    this.fromR = v;
    this.toR = v;
    this.labelShift = this.listening ? LABEL_SHIFT : -LABEL_SHIFT;
    if (this.listening) {
      this.breatheT0 = Date.now();
      this.startFrames();
    }
  }

  aboutToDisappear(): void {
    this.stopFrames();
    if (this.ds !== null) {
      this.ds.off('frame');
      this.ds = null;
    }
  }

  /** 液体色变了（主题色 / 深浅色切换）→ Canvas 是命令式的，build 重跑不会自动重画 */
  private onSkinChanged(): void {
    this.draw();
  }

  private onListeningChanged(): void {
    // 起点取**当前进度**，中途反向也能从当前位置接着走（代价为零）
    this.fromOrb = this.pOrb;
    this.toOrb = this.listening ? 1 : 0;
    this.fromL = this.pL;
    this.toL = this.listening ? 1 : 0;
    this.fromR = this.pR;
    this.toR = this.listening ? 1 : 0;
    // 去程：右端先动（向右扩张吞掉圆）。回程镜像：左端先动。
    this.goingOn = this.listening;

    this.t0 = Date.now();
    this.el = 0;
    this.animating = true;
    if (this.listening) {
      this.breatheT0 = this.t0;
    }

    // 文字块位置交给**原生属性动画**插值 —— 不占逐帧 JS。
    // 文字只有这一处变化：纯平移。不加光晕 / 不淡出 / 不缩放
    // （2026-10-07 用户：「文字移动就行了，你加高光干什么」）。
    animateTo({ duration: TOTAL_MS, curve: CURVE_STD }, () => {
      this.labelShift = this.listening ? LABEL_SHIFT : -LABEL_SHIFT;
    });

    this.startFrames();
  }

  /* ============================================================
     帧循环
     ============================================================ */

  private startFrames(): void {
    if (this.ds === null) {
      this.ds = displaySync.create();
      this.ds.setExpectedFrameRateRange(ICON_RATE);
      this.ds.on('frame', () => {
        this.onFrame();
      });
    }
    if (!this.ticking) {
      this.ticking = true;
      this.ds.start();
    }
  }

  private stopFrames(): void {
    if (this.ds !== null && this.ticking) {
      this.ticking = false;
      this.ds.stop();
    }
  }

  private onFrame(): void {
    const now: number = Date.now();

    if (this.animating) {
      this.el = now - this.t0;
      const eOrb: number = this.progress(this.el, DUR_ORB, 0);
      const eFast: number = this.fastEase(this.el);
      // 慢端走三段 Hermite —— 时间全花在"缝 0→14.9"这段（葫芦唯一可见的区间）
      const eSlow: number = this.slowEase((this.el - DELAY_SLOW) / DUR_SLOW);
      // 去程右端走"快"轴、左端走"慢"轴；回程对调 —— 镜像的同一套节奏
      const eL: number = this.goingOn ? eSlow : eFast;
      const eR: number = this.goingOn ? eFast : eSlow;
      this.pOrb = this.fromOrb + (this.toOrb - this.fromOrb) * eOrb;
      this.pL = this.fromL + (this.toL - this.fromL) * eL;
      this.pR = this.fromR + (this.toR - this.fromR) * eR;
      if (this.el >= TOTAL_MS) {
        this.animating = false;
        this.el = TOTAL_MS;
        this.pOrb = this.toOrb;
        this.pL = this.toL;
        this.pR = this.toR;
      }
    }

    // 呼吸灯：余弦往返，等价于 animateTo(EaseInOut, iterations:-1, Alternate)
    if (this.listening) {
      const ph: number = ((now - this.breatheT0) % BREATHE_MS) / BREATHE_MS;
      this.breathe = 0.35 + 0.65 * (0.5 - 0.5 * Math.cos(PI2 * ph));
    } else {
      this.breathe = 0.35;
    }

    this.draw();

    // 帧率探针：只在有东西在动的时候统计（静止时已 stopFrames）
    if (DBG_FPS && (this.animating || this.listening)) {
      if (this.fpsN === 0) {
        this.fpsT0 = now;
      }
      this.fpsN++;
      if (this.fpsN >= DBG_FPS_N) {
        const avg: number = (now - this.fpsT0) / DBG_FPS_N;
        hilog.info(0x0000, LOG_TAG, 'avg frame %{public}d ms -> %{public}d fps',
          Math.round(avg * 10) / 10, Math.round(1000 / avg));
        this.fpsN = 0;
      }
    }

    // 既不在过渡、也没在听课 —— 没有东西要动，立刻停帧，别空转
    if (!this.animating && !this.listening) {
      this.stopFrames();
    }
  }

  private progress(el: number, dur: number, delay: number): number {
    const x: number = (el - delay) / dur;
    if (x <= 0) {
      return 0;
    }
    if (x >= 1) {
      return 1;
    }
    return CURVE_STD.interpolate(x);
  }

  /**
   * 快端位移：**起步极快**的三次 Hermite（起点斜率 FAST_M0，末端斜率 0）。
   * 为什么不用 easing —— 见 DUR_FAST 那段注释：easing 起步斜率为 0，
   * 会让「圆高速穿过」时的凹槽在真机上闪 1~2 帧。
   */
  private fastEase(el: number): number {
    if (el <= 0) {
      return 0;
    }
    if (el >= DUR_FAST) {
      return 1;
    }
    return this.hermite(0, 0, FAST_M0, 1, 1, 0, el / DUR_FAST);
  }

  /**
   * 慢端位移曲线：**三次 Hermite 分段插值**（为什么不是三次贝塞尔见 SLOW_X1 的注释）。
   * 给定两端的位置与斜率，逐段求值；相邻段在节点处共用同一个斜率 ⇒ C¹ 连续。
   */
  private slowEase(x: number): number {
    if (x <= 0) {
      return 0;
    }
    if (x >= 1) {
      return 1;
    }
    if (x < SLOW_X1) {
      return this.hermite(0, 0, SLOW_M0, SLOW_X1, SLOW_Y1, SLOW_M1, x);
    }
    if (x < SLOW_X2) {
      return this.hermite(SLOW_X1, SLOW_Y1, SLOW_M1, SLOW_X2, SLOW_Y2, SLOW_M2, x);
    }
    return this.hermite(SLOW_X2, SLOW_Y2, SLOW_M2, 1, 1, SLOW_M3, x);
  }

  /**
   * 三次 Hermite 基函数。`m0/m1` 是**对 x 的导数**（dpL/dx），内部会按段宽换算成对 u 的。
   */
  private hermite(x0: number, y0: number, m0: number,
                  x1: number, y1: number, m1: number, x: number): number {
    const w: number = x1 - x0;
    const u: number = (x - x0) / w;
    const u2: number = u * u;
    const u3: number = u2 * u;
    const a0: number = 2 * u3 - 3 * u2 + 1;
    const a1: number = u3 - 2 * u2 + u;
    const a2: number = -2 * u3 + 3 * u2;
    const a3: number = u3 - u2;
    return a0 * y0 + a1 * m0 * w + a2 * y1 + a3 * m1 * w;
  }

  /* ============================================================
     腰部几何
     ============================================================ */

  /**
   * 缝 → 缝中点下陷量（vp）。**山谷的深度**。
   * 缝 ≤ FILL_G0（深度重叠）或 ≥ NECK_GAP_MAX（已断裂）→ 0（= 不画山谷）。
   */
  private neckFill(gap: number): number {
    if (gap <= FILL_G0 || gap >= NECK_GAP_MAX) {
      return 0;
    }
    if (gap >= FILL_G_LAST) {
      // 表尾（缝 14 → 25.2）到断裂点（14.9 → R）线性收尾，让断裂干净利落
      const t: number = (gap - FILL_G_LAST) / (NECK_GAP_MAX - FILL_G_LAST);
      return FILL[FILL.length - 1] + (R - FILL[FILL.length - 1]) * t;
    }
    const f: number = (gap - FILL_G0) / FILL_STEP;
    const i: number = Math.floor(f);
    return FILL[i] + (FILL[i + 1] - FILL[i]) * (f - i);
  }

  /** 归一化山谷形状（线性插值）。|Δ| ≥ VALLEY_MAX → 0 */
  private valleyAt(delta: number): number {
    const d: number = Math.abs(delta);
    if (d >= VALLEY_MAX) {
      return 0;
    }
    const f: number = d / VALLEY_STEP;
    const i: number = Math.floor(f);
    return VALLEY[i] + (VALLEY[i + 1] - VALLEY[i]) * (f - i);
  }

  /**
   * 缝中点位置与缝宽。圆在长条右侧取"右缝"，否则取"左缝"。
   * 缝中点 = 两块**圆心**的中点（等半径时与"圆盖顶点中点"重合）。
   * @param out 结果容器 [缝中点 x, 缝宽]
   */
  private junction(pillL: number, pillR: number, orbX: number, out: number[]): void {
    const cxPill: number = (pillL + pillR) / 2;
    const cxOrb: number = orbX + R;
    if (cxOrb >= cxPill) {
      out[0] = (pillR + orbX) / 2;
      out[1] = orbX - pillR;
    } else {
      out[0] = (pillL + orbX + H) / 2;
      out[1] = pillL - (orbX + H);
    }
  }

  /**
   * 上边界相对"顶线"的下陷量（vp）。= `min(清晰并集, 山谷)`（见文件头）。
   * 返回值恒在 [0, R]：R = 中线（那里两块都不存在 / 已断裂）。
   */
  private depAt(x: number, pillL: number, pillR: number, orbX: number,
               jc: number, fill: number): number {
    // ---- 清晰并集：长条 ----
    let c: number = R;
    if (x >= pillL && x <= pillR) {
      if (x < pillL + R) {
        const d: number = x - (pillL + R);
        c = R - Math.sqrt(Math.max(R * R - d * d, 0));
      } else if (x > pillR - R) {
        const d: number = x - (pillR - R);
        c = R - Math.sqrt(Math.max(R * R - d * d, 0));
      } else {
        c = 0;
      }
    }
    // ---- 清晰并集：圆 ----
    const dx: number = x - (orbX + R);
    if (Math.abs(dx) <= R) {
      const v: number = R - Math.sqrt(Math.max(R * R - dx * dx, 0));
      if (v < c) {
        c = v;
      }
    }
    // ---- 山谷：缝为负时填平凹角，缝为正时捏细连接 ----
    // 用**软化**的 min（见 BLEND）：硬 min 会在两条曲线的交点留下一道凸角折痕。
    if (fill > 0.01) {
      const ad: number = Math.abs(x - jc);
      if (ad < VALLEY_MAX) {
        const v: number = fill * this.valleyAt(ad);
        let t: number = v;
        // 超出 TAPER_IN 之后把控制权平滑交还给清晰并集（见 TAPER_IN 的注释）：
        // 不这样做，小 fill 时山谷那条趋近 0 的长尾会把圆球自己的圆弧肩部削平。
        if (ad > TAPER_IN) {
          const w: number = ad >= TAPER_OUT ? 0 : 1 - (ad - TAPER_IN) / (TAPER_OUT - TAPER_IN);
          t = c + (v - c) * w;
        }
        if (t < c) {
          c = t;
        } else if (t - c < BLEND) {
          const d: number = t - c;
          c = c + d * d / (4 * BLEND);
        }
      }
    }
    return c;
  }

  /* ============================================================
     绘制
     ============================================================ */

  /** 圆角矩形（圆是 w=h=2r 的特例）。自拼路径，不用 roundRect —— 后者旧版本未必有 */
  private capsule(ctx: CanvasRenderingContext2D, x: number, y: number,
                  w: number, h: number, r: number): void {
    const rad: number = Math.min(r, w / 2, h / 2);
    ctx.beginPath();
    ctx.moveTo(x + rad, y);
    ctx.lineTo(x + w - rad, y);
    ctx.arc(x + w - rad, y + rad, rad, -Math.PI / 2, Math.PI / 2);
    ctx.lineTo(x + rad, y + h);
    ctx.arc(x + rad, y + rad, rad, Math.PI / 2, Math.PI * 1.5);
    ctx.closePath();
  }

  /**
   * 麦克风。按 24×24 设计空间画，再整体缩放到 26vp 高 ——
   * 与圆心共用坐标，所以**不可能**出现位置/尺寸对不上的情况。
   * @param pop 缩放系数（跟随 pOrb 收缩，与呼吸灯做「变身」交叉）
   */
  private mic(ctx: CanvasRenderingContext2D, cx: number, cy: number,
              pop: number, alpha: number): void {
    const s: number = (26 / 24) * pop;
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.translate(cx, cy);
    ctx.scale(s, s);
    ctx.translate(-12, -12);   // 把 24×24 设计稿的原点对到 (cx, cy)
    ctx.fillStyle = this.ink;
    // 话筒身：圆角矩形（SVG: rect x=9 y=2.6 w=6 h=11.2 rx=3）
    this.capsule(ctx, 9, 2.6, 6, 11.2, 3);
    ctx.fill();
    ctx.strokeStyle = this.ink;
    ctx.lineWidth = 2;
    ctx.lineCap = 'round';
    // 支架弧：半径 6.8，从 0 扫到 π（y 轴向下，故经过最低点）
    ctx.beginPath();
    ctx.arc(12, 11.2, 6.8, 0, Math.PI, false);
    ctx.stroke();
    // 立柱
    ctx.beginPath();
    ctx.moveTo(12, 18);
    ctx.lineTo(12, 21.2);
    ctx.stroke();
    ctx.restore();
  }

  /** 呼吸灯：外圈光晕随呼吸涨落，内圈灯芯恒定 */
  private light(ctx: CanvasRenderingContext2D, cx: number, cy: number,
                pop: number, alpha: number): void {
    ctx.save();
    ctx.fillStyle = this.ink;
    ctx.globalAlpha = alpha * 0.42 * this.breathe;
    ctx.beginPath();
    ctx.arc(cx, cy, 9 * pop * (0.72 + 0.5 * this.breathe), 0, PI2, false);
    ctx.fill();
    ctx.globalAlpha = alpha;
    ctx.beginPath();
    ctx.arc(cx, cy, 4.5 * pop, 0, PI2, false);
    ctx.fill();
    ctx.restore();
  }

  private draw(): void {
    if (!this.ready || this.boxW <= 0) {
      return;
    }
    const ctx: CanvasRenderingContext2D = this.ctx;
    ctx.clearRect(0, 0, this.boxW + PAD * 2, H + PAD * 2);

    // ---- 两块各自的位置。两端各自独立位移 —— 这就是「先吞、再吐」的来源 ----
    const pillL: number = PAD + this.pL * SPAN;
    const pillR: number = PAD + this.boxW - SPAN + this.pR * SPAN;
    const orbX: number = PAD + (1 - this.pOrb) * (this.boxW - H);
    const orbCx: number = orbX + R;
    const orbCy: number = PAD + R;

    const jcGap: number[] = this.jcOut;
    this.junction(pillL, pillR, orbX, jcGap);
    const jc: number = jcGap[0];
    const fill: number = this.neckFill(jcGap[1]);

    // ---- 一条闭轮廓：上边界左→右、下边界右→左，一次 fill ----
    // ⚠️ 两端圆盖必须**按角度**采样。端点是垂直切线（dep 关于 x 的斜率无穷大），
    //    按 x 步长采样会在端点上切出一道竖直硬棱 —— 真机上就是圆圈左边那条直线。
    //    中段（含面对缝的那个圆盖）坡度平缓，按 x 采样；缝中点附近再加密。
    if (this.xs.length < SAMPLE_CAP) {
      const xs: number[] = [];
      const dps: number[] = [];
      for (let i = 0; i < SAMPLE_CAP; i++) {
        xs.push(0);
        dps.push(0);
      }
      this.xs = xs;
      this.dps = dps;
    }
    // 轮廓左右极点所在的圆盖中心（圆盖半径都是 R）
    const cL: number = pillL <= orbX ? pillL + R : orbX + R;
    const cR: number = pillR >= orbX + H ? pillR - R : orbX + R;
    let n: number = 0;
    for (let a = 0; a <= 90; a += CAP_DEG) {
      this.xs[n] = cL - R * Math.cos(a * Math.PI / 180);
      n++;
    }
    let x: number = cL + STEP_FAR;
    while (x < cR - STEP_FAR && n < SAMPLE_CAP - 100) {
      const ad: number = Math.abs(x - jc);
      this.xs[n] = x;
      n++;
      x += ad < SAMPLE_NEAR ? STEP_NEAR : (ad < SAMPLE_MID ? STEP_MID : STEP_FAR);
    }
    for (let a = 90; a >= 0; a -= CAP_DEG) {
      this.xs[n] = cR + R * Math.cos(a * Math.PI / 180);
      n++;
    }
    this.nSamples = n;
    for (let i = 0; i < n; i++) {
      this.dps[i] = this.depAt(this.xs[i], pillL, pillR, orbX, jc, fill);
    }

    ctx.fillStyle = this.liquid;
    ctx.beginPath();
    ctx.moveTo(this.xs[0], PAD + this.dps[0]);
    for (let i = 1; i < n; i++) {
      ctx.lineTo(this.xs[i], PAD + this.dps[i]);
    }
    for (let i = n - 1; i >= 0; i--) {
      ctx.lineTo(this.xs[i], PAD + H - this.dps[i]);
    }
    ctx.closePath();
    ctx.fill();

    // ---- 图标：和圆共用同一个圆心 ----
    const vis: number = this.iconVis(this.el);
    if (vis > 0.01) {
      const aMic: number = (1 - this.pOrb) * vis;
      const aLight: number = this.pOrb * vis;
      if (aMic > 0.01) {
        this.mic(ctx, orbCx, orbCy, 1 - 0.42 * this.pOrb, aMic);
      }
      if (aLight > 0.01) {
        this.light(ctx, orbCx, orbCy, 0.6 + 0.4 * this.pOrb, aLight);
      }
    }
  }

  /** 图标可见度：过渡中段（圆在长条内部穿过）归零，两端各 110/140ms 渐变 */
  private iconVis(el: number): number {
    if (el <= VIS_OUT_START) {
      return 1;
    }
    if (el < VIS_OUT_END) {
      return 1 - (el - VIS_OUT_START) / (VIS_OUT_END - VIS_OUT_START);
    }
    if (el < VIS_IN_START) {
      return 0;
    }
    if (el < VIS_IN_END) {
      return (el - VIS_IN_START) / (VIS_IN_END - VIS_IN_START);
    }
    return 1;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ---- 液体层 + 图标层：全部由 Canvas 画 ----
      Canvas(this.ctx)
        .width(this.boxW + PAD * 2)
        .height(H + PAD * 2)
        .position({ x: -PAD, y: -PAD })
        .onReady(() => {
          this.ready = true;
          this.draw();
        })

      // ---- 文字层：整幅宽度居中，只改 translate ----
      // translate 是变换，不触发文字重新测排；宽度/位置都不随帧变，
      // 所以过渡期间 ArkUI 这边一帧都不重建（v2 每帧改 width 才是掉帧主因）。
      // 只平移，**不加 shadow / opacity / scale**（用户 2026-10-07 明确要求）。
      Stack() {
        Text(this.listening ? this.labelActive : this.labelIdle)
          .fontSize(FontSize.subtitleM)
          .fontWeight(Weight.medium)
          .fontColor(this.ink)
      }
      .width('100%')
      .height(H)
      .translate({ x: this.labelShift })
    }
    .width('100%')
    .height(H)
    .onAreaChange((_o: Area, n: Area) => {
      const w: number = Number(n.width);
      if (Math.abs(w - this.boxW) > 0.5) {
        this.boxW = w;
        this.draw();
      }
    })
    .onClick(() => {
      // 动画进行中忽略点击：一趟 920ms，中途反向会让「错峰」的两条时间轴打架。
      // 宁可不响应，也不要一个坏掉的中间态。
      if (this.animating) {
        return;
      }
      this.onToggle();
    })
  }
}
