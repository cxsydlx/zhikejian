/**
 * 设计规范层 —— HarmonyOS 官方设计语言的可执行映射。
 *
 * ## 这个文件存在的意义
 * 改造前全工程的圆角有 15 种、字号有 14 种，全是散落在各页的硬编码字面量。
 * 那导致两个问题：① 层级关系靠手感，同样的"卡片标题"在不同页能差 2vp；
 * ② 想统一调整得全工程翻一遍。
 *
 * 这里把**官方规范里的数值**固化成常量，页面只允许引用 token，不再写字面量。
 *
 * ## 数据来源（均为官方文档实测值，非估计）
 * - 字体阶梯 https://developer.huawei.com/consumer/cn/doc/design-guides/typography-0000002622688363
 * - 间隔参数 https://developer.huawei.com/consumer/cn/doc/design-guides/interval-parameter-0000002562577161
 * - 系统资源（圆角/字号）https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V3/ts-appendix-system-resources-0000001193321003-V3
 * - 列表规范 https://developer.huawei.com/consumer/cn/doc/design-guides-V1/list-0000001110467124
 * - 动效规范（时长/曲线四大基本属性）
 *
 * ⚠️ **本文件只放"与主题色无关"的度量**。颜色一律走 `Theme`（支持用户自定义六色系）。
 */

import { display } from '@kit.ArkUI';
import window from '@ohos.window';
import hilog from '@ohos.hilog';

/** 宽屏断点（vp）：≥ 此宽度按平板/折叠展开处理 —— 官方手机与平板的断点即 600 */
const BREAKPOINT_TABLET = 600;

/** 屏幕形态：官方对不同形态给的边距不同，运行时探测 */
export enum DeviceForm {
  PHONE = 0,
  /** 折叠屏展开 / 平板 —— 边距比手机大一档 */
  TABLET = 1,
}

/**
 * ============================================================================
 * 1. 字体阶梯（Typography）
 * ============================================================================
 * 官方把文本分五类：展示 / 标题 / 副标题 / 正文 / 说明。
 * 字号单位用 **fp**（字体像素）而不是 vp —— 这样用户调系统大字体时会跟着缩放，
 * 符合无障碍要求（官方 UX 明确要求"支持系统大字体"）。
 *
 * 本工程实际用得到的档位（去掉 Display 超大字号，课程表场景用不上）：
 *   Title_S 20 Bold    → 页面主标题
 *   Subtitle_L 18 Medium → 卡片/弹窗标题
 *   Subtitle_M 16 Medium → 分组标题、列表主文本
 *   Subtitle_S 14 Medium → 次级标题、按钮文本
 *   Body_L 16 Medium   → 强调正文
 *   Body_M 14 Regular  → 普通正文
 *   Body_S 12 Regular  → 辅助说明
 *   Caption_L 12 Medium → 角标/时间戳
 *   Caption_M 10 Medium → 最小说明文本
 */
export class FontSize {
  /** 只有数据型大数字才用（如周次大字） */
  static readonly displayS: number = 38;
  static readonly titleL: number = 30;
  static readonly titleM: number = 24;
  /** 页面主标题 */
  static readonly titleS: number = 20;
  /** 卡片 / 弹窗标题 */
  static readonly subtitleL: number = 18;
  /** 分组标题、列表主文本 */
  static readonly subtitleM: number = 16;
  /** 次级标题、按钮文本 */
  static readonly subtitleS: number = 14;
  /** 强调正文 */
  static readonly bodyL: number = 16;
  /** 普通正文 */
  static readonly bodyM: number = 14;
  /** 辅助说明 */
  static readonly bodyS: number = 12;
  /** 角标 / 时间戳 */
  static readonly captionL: number = 12;
  /** 最小说明文本（不要再小） */
  static readonly captionM: number = 10;

  /** 课程格子内课程名（课表高密度场景专用，介于 bodyM 与 bodyS 之间） */
  static readonly cellTitle: number = 13;
  /** 课程格子内地点/教师 */
  static readonly cellMeta: number = 11;
}

/**
 * 字重。
 * 官方规则：**标题用 Bold/Medium，正文用 Regular**；不使用 Light（除非展示性大字号）。
 * 全工程只有这三个字重，不允许出现别的 —— 层级靠字号拉开，不靠字重堆。
 */
export class Weight {
  /** 标题、需要强调的数字 */
  static readonly bold: FontWeight = FontWeight.Bold;
  /** 副标题、按钮、分组标题、标签 */
  static readonly medium: FontWeight = FontWeight.Medium;
  /** 正文 */
  static readonly regular: FontWeight = FontWeight.Regular;
}

/**
 * 行高倍数。
 * 中文正文行高官方建议 1.4~1.5；标题可紧一些。
 */
export class LineHeight {
  static readonly title: number = 1.3;
  static readonly body: number = 1.5;
  static readonly caption: number = 1.4;
}

/**
 * ============================================================================
 * 2. 间距（Spacing）
 * ============================================================================
 * 官方"泛手机"间隔规范：
 *   屏幕边缘 margin ·············· 16vp（平板 32vp）
 *   卡片之间 ···················· 12vp
 *   控件间有边界（上下/左右）····· 16vp
 *   控件间无边界（上下/左右）····· 8vp
 *   主次文本 ···················· 上下 2vp / 左右 8vp
 *
 * 另附官方系统 Padding Token 全量表，取值集中于 2 的倍数。
 * 本工程统一按 **4 的倍数**网格，常用档位下面都列了。
 */
export class Space {
  /** 0 —— 明确表示"不要间距"，比写 0 可读 */
  static readonly none: number = 0;
  /** 2vp —— 主次文本上下间隔（官方专值） */
  static readonly textGap: number = 2;
  /** 4vp —— 官方 xs，元素内最紧凑 */
  static readonly xs: number = 4;
  /** 6vp */
  static readonly xsPlus: number = 6;
  /** 8vp —— 控件间无边界间隔、主次文本左右间隔 */
  static readonly s: number = 8;
  /** 12vp —— 卡片之间间隔 */
  static readonly m: number = 12;
  /** 16vp —— 控件间有边界间隔、手机屏幕边距、卡片内边距 */
  static readonly l: number = 16;
  /** 20vp */
  static readonly xl: number = 20;
  /** 24vp —— 模块之间留白 */
  static readonly xxl: number = 24;
  /** 32vp —— 平板屏幕边距 */
  static readonly xxxl: number = 32;
  /** 40vp */
  static readonly huge: number = 40;
}

/**
 * ============================================================================
 * 3. 圆角（Corner Radius）
 * ============================================================================
 * 官方系统资源原值：
 *   id_corner_radius_default_xs = 4vp
 *   id_corner_radius_default_s  = 8vp
 *   id_corner_radius_default_m  = 12vp
 *   id_corner_radius_default_l  = 16vp
 *   id_corner_radius_default_xl = 24vp
 *   另：id_corner_radius_icon = 8vp / id_corner_radius_menu = 20vp
 *
 * 用途划分（本工程约定）：
 *   xs  4  → 极小标签、色块
 *   s   8  → 按钮、标签、图标背板
 *   m  12  → 列表卡片、课表格子
 *   l  16  → 大卡片、浮层
 *   xl 24  → 弹窗、底部抽屉
 *   full  → 胶囊（高度的一半，用 999 表示"取满"）
 */
export class Radius {
  static readonly xs: number = 4;
  /** 按钮 / 标签 / 图标背板 */
  static readonly s: number = 8;
  /** 列表卡片 / 课表格子 */
  static readonly m: number = 12;
  /** 大卡片 / 浮层 */
  static readonly l: number = 16;
  /** 弹窗 / 底部抽屉 */
  static readonly xl: number = 24;
  /** 胶囊 —— 传一个足够大的值即可取满 */
  static readonly full: number = 999;
}

/**
 * ============================================================================
 * 4. 尺寸（Sizing）
 * ============================================================================
 * 列表项高度官方值：
 *   单行无左元素 48vp / 单行有左元素（<40vp）56vp / 左元素 40vp 时 72vp
 *   双行无左元素 64vp / 双行有左元素 72vp / 三行 96vp
 *
 * 图标尺寸官方值：小图标 16 / 系统图标 24 / 头像 40 / 应用图标 64
 */
export class Size {
  /** 列表项：单行无左元素 */
  static readonly listSingle: number = 48;
  /** 列表项：单行有左元素 */
  static readonly listSingleWithIcon: number = 56;
  /** 列表项：双行 */
  static readonly listDouble: number = 64;
  /** 列表项：双行有左元素 */
  static readonly listDoubleWithIcon: number = 72;
  /** 列表项：三行 */
  static readonly listTriple: number = 96;

  /** 小图标（列表左侧小圆点等） */
  static readonly iconXs: number = 16;
  /** 系统图标（最常用） */
  static readonly iconS: number = 24;
  /** 中图标（带背板的功能图标） */
  static readonly iconM: number = 32;
  /** 头像 / 大元素 */
  static readonly iconL: number = 40;
  /** 应用图标 */
  static readonly iconXl: number = 64;

  /**
   * 最小可点击热区。
   * ⚠️ 官方无障碍要求：触控目标**不小于 48×48vp**。
   * 视觉上可以更小（如 16vp 的小图标），但**外层容器必须撑到 48vp**，
   * 否则手指点不准 —— 这是硬性无障碍指标，不是审美选择。
   */
  static readonly touchTarget: number = 48;

  /** 分割线粗细（官方 1px 用 0.5~1vp，高密度屏用 vp 会偏粗，故取小值） */
  static readonly divider: number = 0.5;

  /**
   * 空状态插图边长。
   *
   * 插图源文件是 512×512 透明底 PNG，这里渲染成 160vp —— 大约占屏宽的 45%，
   * 既有存在感又不喧宾夺主（空状态的主角是那句提示文案 + 行动按钮）。
   * ⚠️ 必须配 `objectFit(ImageFit.Contain)`，否则会被拉伸变形
   *（素材已在上游裁成正方形并留了 18% 边距，这里不需要再 padding）。
   */
  static readonly emptyIll: number = 160;

  /**
   * 状态卡小插图边长（听课页状态卡左侧的麦克风）。
   *
   * 比 `emptyIll` 小得多：这张卡里还有状态文案和主操作按钮，
   * 插图只做「一眼认出这是什么页面」的视觉锚点，尺寸压在 44vp
   *（略小于 `touchTarget`，因为它不可点击，不需要满足 48vp 热区）。
   */
  static readonly statusIll: number = 44;

  /** 顶栏内容区高度（不含状态栏避让） */
  static readonly bar: number = 56;
  /**
   * 底栏高度 —— 官方《底部页签》规范：**悬浮式默认 56vp**（平铺式 48vp）。
   *
   * 本工程用**悬浮胶囊**形态（`barOverlap` + `barFloatingStyle`），故取 56vp。
   * ⚠️ 2026-09-28 从 50 改到 56：原先 50 是为了迁就手绘小图标（15vp）压出来的，
   * 图标换 HarmonyOS Symbol（24vp）后必须回到规范值，否则 24vp 图标 + 12vp 文字塞进 50vp 会挤。
   * ⚠️ 改动此值必须同步 `BAR_CLEARANCE`（各 Tab 内容底部避让），否则内容会被胶囊盖住。
   */
  static readonly tabBar: number = 56;
  /**
   * 悬浮底栏距屏幕底部的间距。
   *
   * ⚠️ 2026-09-28 从 32 改回 **28** —— 对齐官方博客示例值
   * （《让底部导航栏的光晕跟着手指跑》里 `barBottomMargin: 28`）。
   * 我方先前自定的 32 已作废。
   */
  static readonly floatMargin: number = 28;
  /**
   * 悬浮底栏在内容区下方占用的总高度（各 Tab 内容底部避让值）。
   *
   * = `tabBar`(56) + `floatMargin`(28) + 缓冲(16) = **100**。
   * 缓冲 16vp 的意义：胶囊上沿带阴影扩散，纯按几何相加会让最后一行紧贴阴影边。
   *
   * ⚠️ 2026-09-28 从字面量 88 提炼成常量：原先 88 = 50+12+16。
   * 底栏 50→56、floatMargin 12→28 之后必须同步。
   * `tabBar` / `floatMargin` 任一改动，本值必须重算。
   */
  static readonly barClearance: number = 100;
  /**
   * 悬浮底栏最小避让高度（= `tabBar`(56) + `floatMargin`(28) + 缓冲(8) = **92**）。
   *
   * ## 与 `barClearance` 的区别（2026-09-28 新增，方案B）
   * 沉浸光感是**全屏取色的毛玻璃** —— 它透出的是「胶囊正下方那一块屏幕内容」。
   * 若底栏下方永远垫着一段纯空白（旧 `barClearance` 做法），材质透出来就是页面底色，
   * 视觉上等同"不透"。真机探针页（高饱和色带）验证：色带铺到胶囊下方时，
   * 胶囊内采样 `(8,175,165)` 明显带青绿 → 材质一直是正常工作的。
   *
   * 因此滚动类内容改用本值：只留**几何上必须**的余量，让内容尽量延伸到胶囊后方，
   * 滚到底时最末一行能进入胶囊区域 → 材质透出真实内容颜色。
   *
   * 缓冲由 16 收到 8：既然要让内容"敢"贴到胶囊边，就不要再额外加一圈阴影余量。
   */
  static readonly barClearanceMin: number = 92;
}

/**
 * ============================================================================
 * 5. 动效（Motion）
 * ============================================================================
 * 官方动效三属性：时长 / 曲线 / 帧率。曲线分贝塞尔（标准/减速/加速）与弹性两类。
 *
 * 时长经验法则（官方）：
 *   触摸反馈 100~200ms（取 150）
 *   列表增删 250~400ms（取 300）
 *   面板展开 300~450ms（取 400）
 *   布局切换 350~500ms（取 450）
 *   页面转场 300~500ms（取 350）
 *
 * 曲线官方对应：
 *   FastOutSlowIn = cubic-bezier(0.4, 0, 0.2, 1) —— **大多数 UI 交互的默认选择**
 *   EaseIn  = (0.4, 0, 1, 1) 离开屏幕
 *   EaseOut = (0, 0, 0.2, 1) 进入屏幕
 *   Spring  —— 需要弹性时用
 */
export class Motion {
  /** 150ms —— 按钮按下/抬起、开关切换 */
  static readonly durationTouch: number = 150;
  /** 300ms —— 单个列表项插入/移除 */
  static readonly durationList: number = 300;
  /** 350ms —— 页面转场 */
  static readonly durationPage: number = 350;
  /** 400ms —— 面板/底部抽屉展开 */
  static readonly durationPanel: number = 400;
  /** 450ms —— 视图切换、布局模式变更 */
  static readonly durationLayout: number = 450;

  /**
   * 标准曲线 —— 大多数交互的默认。
   * 用 ArkUI 内置枚举而非手写字符串，性能更好且与系统一致。
   */
  static readonly curveStandard: Curve = Curve.FastOutSlowIn;
  /** 进场（元素出现在屏幕上） */
  static readonly curveEnter: Curve = Curve.EaseOut;
  /** 出场（元素离开屏幕） */
  static readonly curveExit: Curve = Curve.EaseIn;
  /** 页面转场 —— 更柔和的对称缓动 */
  static readonly curvePage: Curve = Curve.EaseInOut;
  /**
   * 弹性曲线。
   * ⚠️ ArkUI 的 `Curve` 枚举**没有 `Spring` 成员**（实测该枚举只有 9 个：Linear / Ease /
   * EaseIn / EaseOut / EaseInOut / FastOutSlowIn / LinearOutSlowIn / FastOutLinearIn /
   * ExtremeDeceleration）。弹性曲线的正路是 `@ohos.curves` 的 `springCurve()` / `springMotion()`，
   * 它们返回 `ICurve` 而非 `Curve`，用法不同（要传给 `animateTo({ curve: curves.springCurve(...) })`）。
   * **需要弹性时用那边，不要试图在这里加一个 Curve 成员。**
   */

  // ==========================================================================
  // 统一转场（2026-09-28 新增）
  // ==========================================================================
  // 用户反馈「各种界面的呈现都太生硬」。根因：全项目此前**一处动画都没有**
  // （grep animateTo / transition / pageTransition 零命中）。
  //
  // 这里给两种转场各定一个标准：
  //   · `pageTransition()` —— 路由页（Entry 页）进出，用**官方 SLIDE_SWITCH** 或自定义
  //     的「淡入 + 轻微上移」；后者比系统默认更含蓄，适合设置类页面。
  //   · `transition()` —— 页内元素出现/消失（卡片、面板、列表项）。
  //
  // ⚠️ 只改时长，不改曲线语义：进场用 EaseOut（快进慢停），出场用 EaseIn（慢起快走），
  //    这是官方动效规范里的标准搭配，反过来会显得"拖沓"。

  /**
   * 路由页入场：从右侧轻滑 + 淡入（a page 的 appear 侧）。
   * 用 `asymmetric` 把进出分开 —— 进和出用同一个位移方向会像"弹回去"，很别扭。
   */
  static pageEnter(): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY
        .combine(TransitionEffect.translate({ x: '12%', y: 0 }))
        .animation({ duration: Motion.durationPage, curve: Motion.curveEnter }),
      TransitionEffect.OPACITY
        .combine(TransitionEffect.translate({ x: '-6%', y: 0 }))
        .animation({ duration: Motion.durationPage, curve: Motion.curveExit })
    );
  }

  /** 元素出现：淡入 + 下方 12vp 上移（卡片 / 列表项 / 面板内容） */
  static fadeUpIn(): TransitionEffect {
    return TransitionEffect.OPACITY
      .combine(TransitionEffect.translate({ y: 12 }))
      .animation({ duration: Motion.durationList, curve: Motion.curveEnter });
  }

  /** 弹性/遮罩层出现：纯淡入（浮层不要位移，会跟背后内容打架） */
  static fadeIn(): TransitionEffect {
    return TransitionEffect.OPACITY
      .animation({ duration: Motion.durationPanel, curve: Motion.curveEnter });
  }
}

/**
 * ============================================================================
 * 6. 透明度与阴影（Elevation）
 * ============================================================================
 * 官方建议：**阴影要柔和、低透明度**；信息密集页面不要大面积投影（会显脏）。
 * 层级优先用"背景色深浅 + 材质"表达，阴影只在真正浮起的元素上用。
 */
export class Elevation {
  /** 页面底色上的普通卡片：几乎不用阴影，靠背景色区分 */
  static readonly none: number = 0;
  /** 轻微浮起（列表卡片） */
  static readonly low: number = 2;
  /** 明显浮起（悬浮底栏、顶栏） */
  static readonly mid: number = 8;
  /** 强浮起（弹窗、抽屉） */
  static readonly high: number = 16;
}

/** 层级遮罩透明度（弹窗背后压暗） */
export class Scrim {
  /** 弹窗背板 —— 官方建议不要过重，0.32 足够建立层级 */
  static readonly modal: number = 0.32;
  /** 抽屉背板 */
  static readonly drawer: number = 0.24;
}

/**
 * 屏幕形态探测与响应式边距。
 *
 * 官方给手机的屏幕边距是 16vp、平板是 32vp —— 本工程主要跑在 MatePad 平板上，
 * 用手机边距会显得内容"贴着屏幕边"，很局促。
 */
export class Layout {
  private static form: DeviceForm = DeviceForm.PHONE;
  private static inited: boolean = false;
  /** 窗口尺寸监听是否已挂（全局只挂一次） */
  private static observed: boolean = false;
  private static observers: Array<() => void> = [];

  /** 在页面 aboutToAppear 里调一次（幂等） */
  static init(): void {
    if (Layout.inited) {
      return;
    }
    Layout.inited = true;
    try {
      // 以屏幕宽度判定形态：>= 600vp 视为平板/折叠展开
      const d = display.getDefaultDisplaySync();
      Layout.applyWidth(d.width / d.densityPixels);
    } catch (e) {
      Layout.form = DeviceForm.PHONE;
    }
  }

  static deviceForm(): DeviceForm {
    Layout.init();
    return Layout.form;
  }

  static isTablet(): boolean {
    return Layout.deviceForm() === DeviceForm.TABLET;
  }

  /**
   * 屏幕左右边距 —— 手机 16vp / 平板 32vp（官方值）。
   * 所有页面的内容区左右 padding 一律用这个，不要写死。
   */
  static screenMargin(): number {
    return Layout.isTablet() ? Space.xxxl : Space.l;
  }

  /**
   * 内容区最大宽度（仅平板有意义）。
   *
   * ## 为什么要有这个
   * 平板全宽铺开会让阅读行过长（官方建议正文单行 40~70 字符），
   * 卡片被拉伸到 1400vp 后内部信息全挤在左半边，右侧大片空白。
   *
   * ## 取值演进（真机实测）
   * · 第一版 840 → 太小，卡片左右各空 280vp，比铺满更空
   * · 第二版 1120 → 卡片宽度合适了，但**卡片内部**仍是"文字靠左、控件靠右"、
   *   中间 800px 空白；分段条也被拉成半个屏那么宽的巨条
   * · 第三版 **880** → 对应约 60 个中文字符，正落在官方 40~70 的建议区间内；
   *   分段条、按钮这类控件宽度随之收敛到合理比例
   *
   * ⚠️ 只给"文本 / 表单型页面"用，不要套在课表上（课表是数据视图，必须铺满，
   * 详见 `colMaxWidth()` 的证伪记录）。
   *
   * ## ⛔ 手机端必须返回"无限制"，不能返回 0（2026-10-07 定位）
   *
   * 原来写的是 `isTablet() ? 880 : 0`，意图是"手机不封顶"。
   * 但**调用方是 `.constraintSize({ maxWidth: Layout.contentMaxWidth() })`**，
   * 而 ArkUI 里 `maxWidth: 0` 的语义**不是"不限制"，是"上限就是 0"** ——
   * 不是"忽略这个约束"，而是拿它当合法值参与计算。
   *
   * 后果：手机（`DeviceForm.PHONE`）上整棵内容 Column 被压成 0 宽，
   * 卡片只能靠子元素 intrinsic 撑出 ~196px（屏宽 1256px 的 15.6%），
   * 用户看到的就是**「听课」和「设置」两页主体塌成三个白色竖条**，
   * 而「课表」页正常 —— 正因为 `CourseTableView` 是全工程唯一没用这个常量的页面。
   *
   * ∴ 无限制时必须给一个**合法的极大值**，不能用 0 去表达"没有上限"。
   */
  static contentMaxWidth(): number {
    // 100000vp ≈ 100 米，远超任何真实屏宽，等价于"不限制"，但始终是合法正数。
    return Layout.isTablet() ? 880 : 100000;
  }

  /**
   * ⛔ **课表列宽上限 —— 已废弃，不要使用（2026-09-27 真机验证证伪）**
   *
   * 曾经的想法：平板 1400vp 按屏宽等分会得到 ~190vp 的巨列，想封顶到 112vp。
   * 真机实测结论：**封顶比巨列更难看**。
   *   · 封顶后总宽只有 842vp，右侧空出 25%（350vp）一片死白，看着像"课表没排满"
   *   · `Scroll` 的内容宽度由子元素（`gridW()`）决定，外层加 `.align(Center)` **不会居中**
   *     —— 想居中就得把网格宽度硬撑到 100%，那又等于不封顶，自相矛盾
   *
   * ∴ 课表属于**数据密集型视图**，必须一屏铺满，不做宽度收敛。
   * 保留此常量只为记录这次判断，代码里**没有任何地方引用它**。
   */
  static colMaxWidth(): number {
    return 112;
  }

  /**
   * ⛔ 课表网格总宽上限 —— 同为废弃参考值，理由见 `colMaxWidth()`。
   */
  static gridMaxWidth(): number {
    return 850;
  }

  /**
   * 挂窗口尺寸变化监听，驱动 `contentMaxWidth()` 重新取值。
   *
   * ## 为什么必须挂
   * `ArkUI` 的 `@State` 只观察**自己**:一个页面若用 `@State wide: boolean` 存
   * "是否宽屏"，就必须有人把新值写进去。旋转 / 折叠屏展开 / 分屏拖拽都不会
   * 自动触发页面重算 `contentMaxWidth()` —— 不挂这个，平板横竖切完内容宽度会卡在旧值。
   *
   * 监听里只改 `Layout` 自己的字段再回调订阅者；页面拿到回调后把断点
   * 同步进自己的 `@State`（`wholeSpace()` 之类），重绘才是真的发生。
   */
  static observe(onBreakpoint: () => void): void {
    Layout.init();
    Layout.observers.push(onBreakpoint);
    if (Layout.observed) {
      return;
    }
    Layout.observed = true;
    try {
      // 用应用窗口（而非默认显示区）：分屏时能拿到真实的可用宽度
      window.getLastWindow(getContext())
        .then((w: window.Window) => {
          w.on('windowSizeChange', (size: window.Size) => {
            Layout.applyWidth(px2vp(size.width));
          });
        })
        .catch((e: Error) => {
          hilog.warn(0x0000, 'skt', 'Layout.observe failed: %{public}s', e.message);
        });
    } catch (e) {
      const err = e as Error;
      hilog.warn(0x0000, 'skt', 'Layout.observe failed: %{public}s', err.message);
    }
  }

  /** 宽度（vp）→ 形态。屏幕语义只此一处，别在各页重写判断 */
  private static applyWidth(widthVp: number): void {
    const next: DeviceForm = widthVp >= BREAKPOINT_TABLET ? DeviceForm.TABLET : DeviceForm.PHONE;
    if (next === Layout.form) {
      return;
    }
    Layout.form = next;
    for (const cb of Layout.observers) {
      cb();
    }
  }
}
