import preferences from '@ohos.data.preferences';
import { common, ConfigurationConstant } from '@kit.AbilityKit';

/** 一条「地区 → 字体颜色」规则：课程的地点/校区命中 match 时，格子文字用该颜色 */
export class ThemeRule {
  match: string = '';
  color: string = '';
}

/** 一个预制色系：主题色 + 强调色 + 课表 10 色板（每项 = [浅底, 深字, 强调条]） */
export class ColorFamily {
  key: string = '';
  label: string = '';
  theme: string = '';
  accent: string = '';
  /** 容器 / 卡片 / 底栏的浅底色（跟随色系，也可在配色页单独指定） */
  soft: string = '';
  palette: string[][] = [];

  constructor(key: string, label: string, theme: string, accent: string, soft: string, palette: string[][]) {
    this.key = key;
    this.label = label;
    this.theme = theme;
    this.accent = accent;
    this.soft = soft;
    this.palette = palette;
  }
}

/** 全局配色配置（各模块互相独立，可单独覆盖） */
export class ThemeConfig {
  family: string = 'gong';          // UI 主题色系（顶栏 / 按钮）
  blockFamily: string = 'gong';     // 课表配色系（课程块色板）
  theme: string = '#C0492F';        // UI 主题色（可单独指定，覆盖色系默认值）
  accent: string = '#2E2F25';       // 提醒 / 强调色（当前节次、正在上的课、徽标）
  soft: string = '#F7E9E3';         // 容器 / 卡片 / 底栏的浅底色
  textPrimary: string = '#1C1917';  // 主字色
  textSecondary: string = '#78716C';// 次字色
  /**
   * 课表网格背景色。空串 = 跟随色系（用 `softColor()`），非空 = 用户显式指定。
   * 【2026-09-28】从「设置 → 更多外观 → 背景色」搬到配色页（用户要求）。
   */
  scheduleBg: string = '';
  rules: ThemeRule[] = [];          // 地区字色规则
}

const K_THEME = 'themeJson';

/**
 * 统一调色系统。
 *
 * 【2026-09-28 重构】色系由原「橙/蓝/绿/红/紫/青」（Material 通用色）**换成四套国画配色**。
 * 来源：用户提供的 4 张《中国传统色》参考卡，逐张取色核实（见 each 条目注释）。
 *
 * 设计原则（用户明确要求：「切换的配色不是要是同一个色系，而是要合理搭配」）：
 *   同一套色系里，**主题色与强调色不做同色相**，而是一冷一暖 / 一明一暗相互衬——
 *   这正是国画「赭石压青绿」的对比逻辑。四组分别是：
 *     ① 故宫·橙绯红  —— 朱红主色 + 石榴墨绿强调（暖主冷辅，最经典的红墙绿瓦）
 *     ② 园博园·淡藤萝紫 —— 藕紫主色 + 青灰蓝强调（极淡主色需深冷色压住，否则发飘）
 *     ③ 盘龙纹·棉絮灰 —— 灰米主色 + 老茶棕强调（同属大地色但明度拉开，温润而不闷）
 *     ④ 北海公园·柴染棕 —— 柴棕主色 + 飞泉青强调（暖棕主色配冷青，参考图里的原配色）
 *
 * 每套含：主题色 + 强调色 + 容器浅底色 + 课表 10 色板（每项 [浅底, 深字, 强调条]）。
 */
export class Theme {

  static readonly FAMILIES: ColorFamily[] = [
    // ① 故宫 · 贵气天成（ref1）
    // 主题 橙绯红 #C0492F / 强调 石榴绿 #2E2F25 / 辅 洗柿橙 #E68D59 / 辅 伽罗褐 #866040
    new ColorFamily('gong', '故宫·橙绯红', '#C0492F', '#2E2F25', '#F7E9E3', [
      ['#E8B7A6', '#7A2312', '#C0492F'],   // 主红
      ['#C9CBBF', '#2E2F25', '#5E6353'],   // 石榴绿
      ['#F2D3BB', '#8A5225', '#E68D59'],   // 洗柿橙
      ['#DCC7B0', '#5E4224', '#866040'],   // 伽罗褐
      ['#E3C9BD', '#6E3A2A', '#A85C46'],   // 陶土
      ['#CBB9A8', '#584430', '#7E6448'],   // 沉香
      ['#EFD9C0', '#7E5A22', '#D9A45E'],   // 蜜合
      ['#D6C2B4', '#5A3A2E', '#8E5F4C'],   // 檀褐
      ['#E0BDB2', '#75281C', '#B44A34'],   // 朱殷
      ['#CFCFC0', '#3A3B2E', '#6E7060'],   // 苍绿
    ]),

    // ② 园博园 · 淡藤萝紫（ref2）
    // 主题 淡藤萝紫 #E8DDD8 / 强调 青灰蓝 #1D4C50 / 辅 赤白橡 #D3A488 / 辅 芦穗灰 #B0AEA0
    // ⚠️ 本体主色极淡，故强调色必须用深冷色压住，否则整页"发飘、看不清重点"。
    new ColorFamily('tengluo', '园博园·淡藤萝紫', '#B99A8E', '#1D4C50', '#F4EDEA', [
      ['#EADBD4', '#8A6558', '#C48E7C'],   // 淡藤萝紫压深后可读
      ['#B8CBCB', '#1D4C50', '#3E7A7E'],   // 青灰蓝
      ['#EDD9C8', '#94603C', '#D3A488'],   // 赤白橡
      ['#D2D0C6', '#5C5A50', '#918E82'],   // 芦穗灰
      ['#DDE1DC', '#41443F', '#7C847C'],   // 云峰白
      ['#C8D3CE', '#2A4A46', '#58847C'],   // 竹月
      ['#E6D6C8', '#7E5A38', '#B98F66'],   // 米灰
      ['#C4CFCB', '#28474A', '#547C80'],   // 黛蓝
      ['#E2D2CE', '#7C524C', '#B07E76'],   // 藕荷
      ['#CFD8D2', '#334B44', '#648276'],   // 蟹壳青
    ]),

    // ③ 盘龙纹 · 棉絮灰（ref3）
    // 主题 棉絮灰 #C4BDB0 / 强调 老茶棕 #635045 / 辅 淡红鸢 #AF5F54 / 辅 苍灰绿 #3B4E3D
    // 同属大地色系，但主题浅、强调深，靠**明度**拉开层次（不是靠色相）。
    new ColorFamily('panlong', '盘龙纹·棉絮灰', '#8A8375', '#635045', '#F2EFE9', [
      ['#DCD6CA', '#5A5348', '#8A8375'],   // 棉絮灰
      ['#CFC0B2', '#4E3E2E', '#7E6450'],   // 老茶棕
      ['#E6C6C0', '#7E332B', '#AF5F54'],   // 淡红鸢
      ['#C2CEC3', '#2C3E30', '#4E6852'],   // 苍灰绿
      ['#D5CEC2', '#524A3E', '#837A68'],   // 瓦灰
      ['#C9BDB0', '#4A3C2E', '#786454'],   // 荞麦
      ['#E0D3C2', '#6E5638', '#A88A62'],   // 驼色
      ['#C6C0B4', '#44403A', '#6E6A60'],   // 雁灰
      ['#DCC9C2', '#6A4038', '#9E6E62'],   // 豆沙
      ['#BFC4B8', '#384034', '#5E6A56'],   // 苔绿
    ]),

    // ④ 北海公园 · 柴染棕（ref4）
    // 主题 柴染棕 #8A6A4A / 强调 青灰蓝 #1D4C50 / 辅 薄香橙 #D1AA78 / 辅 飞泉青 #3F605B
    // 参考图本身就是"暖棕主色 + 冷青副色"，直接落地为 主题暖 / 强调冷。
    new ColorFamily('chai', '北海·柴染棕', '#8A6A4A', '#1D4C50', '#F6EFE6', [
      ['#DEC7A8', '#6A4A28', '#A67C4E'],   // 柴染棕
      ['#BCCFCE', '#1D4C50', '#3E7679'],   // 青灰蓝
      ['#ECD3B0', '#8A6224', '#D1AA78'],   // 薄香橙
      ['#C0CFCB', '#28494A', '#3F605B'],   // 飞泉青
      ['#D9C3A4', '#5E4324', '#96754C'],   // 黄栌
      ['#C6CDBD', '#3A4430', '#65725A'],   // 松花
      ['#E5CBA6', '#7E5620', '#C69A62'],   // 秋香
      ['#C9C1AC', '#4A4634', '#7C7660'],   // 香灰
      ['#DCC0A6', '#6C4526', '#A8764C'],   // 酱色
      ['#BDCCC4', '#2C4640', '#527A6E'],   // 碧色
    ]),
  ];

  static cfg: ThemeConfig = new ThemeConfig();

  private static prefs: preferences.Preferences | null = null;
  private static listeners: Array<() => void> = [];

  static async init(ctx: common.UIAbilityContext): Promise<void> {
    if (Theme.prefs != null) {
      return;
    }
    Theme.prefs = await preferences.getPreferences(ctx, 'skt_prefs');
    await Theme.load();
  }

  static onChange(cb: () => void): void {
    Theme.listeners.push(cb);
  }

  /**
   * 通知「系统配置变了（深浅色切换）」，让订阅者刷新。
   *
   * 【2026-09-30 新增】由 `EntryAbility.onConfigurationUpdate` 调用。
   * 为什么不复用 `notify()`：那个是 private，且语义是"配色配置被改了"，
   * 这里是"**环境**变了" —— 两者对订阅者的含义不同，所以保留独立入口
   * （目前处理方式相同：都让页面重绘 + `Mat.rebuild()`）。
   */
  static notifyConfigChanged(): void {
    Theme.notify();
  }

  private static notify(): void {
    for (const cb of Theme.listeners) {
      cb();
    }
  }

  private static async load(): Promise<void> {
    const p = Theme.prefs;
    if (p == null) {
      return;
    }
    try {
      const raw = (await p.get(K_THEME, '')) as string;
      if (raw.length === 0) {
        return;
      }
      const o = JSON.parse(raw) as Record<string, Object>;
      const c = new ThemeConfig();
      c.family = Theme.migrateFamily(Theme.strOr(o, 'family', 'gong'));
      c.blockFamily = Theme.migrateFamily(Theme.strOr(o, 'blockFamily', 'gong'));
      c.theme = Theme.strOr(o, 'theme', Theme.familyOf(c.family).theme);
      c.accent = Theme.strOr(o, 'accent', Theme.familyOf(c.family).accent);
      c.soft = Theme.strOr(o, 'soft', Theme.familyOf(c.family).soft);
      c.textPrimary = Theme.strOr(o, 'textPrimary', '#1C1917');
      c.textSecondary = Theme.strOr(o, 'textSecondary', '#78716C');
      c.scheduleBg = Theme.strOr(o, 'scheduleBg', '');
      const ra = o['rules'];
      if (ra != null) {
        const arr = ra as Array<Record<string, Object>>;
        const list: ThemeRule[] = [];
        for (const r of arr) {
          const rr = new ThemeRule();
          rr.match = Theme.strOr(r, 'match', '');
          rr.color = Theme.strOr(r, 'color', '');
          if (rr.match.length > 0 && rr.color.length > 0) {
            list.push(rr);
          }
        }
        c.rules = list;
      }
      Theme.cfg = c;
    } catch (e) {
      // 配置损坏：用默认值
    }
  }

  private static strOr(o: Record<string, Object>, k: string, dft: string): string {
    const v = o[k];
    return typeof v === 'string' && (v as string).length > 0 ? v as string : dft;
  }

  /**
   * 色系 key 迁移：把已废弃的旧色系名映射到新四套国画配色里最接近的一套。
   * 旧值：orange / blue / green / red / purple / teal（Material 通用色）。
   * 若不迁移，`familyOf()` 会回退到 FAMILIES[0]，但**已落盘的 theme/accent/soft 仍是旧橙值**，
   * 于是出现「家族名是国画、颜色还是番茄橙」的串色。故这里连颜色一起重置。
   */
  private static migrateFamily(key: string): string {
    switch (key) {
      case 'orange': return 'gong';       // 橙 → 故宫·橙绯红
      case 'red': return 'gong';
      case 'blue': return 'chai';         // 蓝 → 北海·柴染棕（冷强调色同为青灰蓝）
      case 'teal': return 'chai';
      case 'green': return 'panlong';     // 绿 → 盘龙纹·棉絮灰（含苍灰绿）
      case 'purple': return 'tengluo';    // 紫 → 园博园·淡藤萝紫
      default: return key;                // 已是新 key 或未知，原样返回
    }
  }

  /** 该 key 是否为当前有效色系（用于判断是否需要重置落盘颜色） */
  static isKnownFamily(key: string): boolean {
    for (const f of Theme.FAMILIES) {
      if (f.key === key) {
        return true;
      }
    }
    return false;
  }

  static async save(): Promise<void> {
    const p = Theme.prefs;
    if (p == null) {
      return;
    }
    const c = Theme.cfg;
    const rules: Array<Record<string, Object>> = [];
    for (const r of c.rules) {
      rules.push({ 'match': r.match, 'color': r.color });
    }
    const o: Record<string, Object> = {
      'family': c.family,
      'blockFamily': c.blockFamily,
      'theme': c.theme,
      'accent': c.accent,
      'soft': c.soft,
      'textPrimary': c.textPrimary,
      'textSecondary': c.textSecondary,
      'scheduleBg': c.scheduleBg,
      'rules': rules,
    };
    await p.put(K_THEME, JSON.stringify(o));
    await p.flush();
    Theme.notify();
  }

  // ---------- 查询 ----------

  static familyOf(key: string): ColorFamily {
    for (const f of Theme.FAMILIES) {
      if (f.key === key) {
        return f;
      }
    }
    return Theme.FAMILIES[0];
  }

  static themeColor(): string {
    return Theme.cfg.theme;
  }

  static accentColor(): string {
    return Theme.cfg.accent;
  }

  /** 容器 / 卡片 / 底栏浅底色（未单独指定时跟随色系） */
  static softColor(): string {
    return Theme.cfg.soft.length > 0 ? Theme.cfg.soft : Theme.familyOf(Theme.cfg.family).soft;
  }

  /** 页面底色：容器底再淡一档，保持中性不刺眼 */
  static pageColor(): string {
    return Theme.mix(Theme.softColor(), '#FFFFFF', 0.55);
  }

  /**
   * 课表网格背景色。用户显式指定过就用它，否则跟随色系的容器底色。
   * 由配色页的「课表背景色」控制（2026-09-28 从设置页搬来）。
   */
  static scheduleBgColor(): string {
    return Theme.cfg.scheduleBg.length > 0 ? Theme.cfg.scheduleBg : Theme.softColor();
  }

  /** 主题色上的对比色：浅色主题配深字，深色主题配白字（避免选浅黄时白字看不见） */
  static onTheme(): string {
    const hex = Theme.cfg.theme;
    if (hex.length < 7) {
      return '#FFFFFF';
    }
    const r = parseInt(hex.substring(1, 3), 16);
    const g = parseInt(hex.substring(3, 5), 16);
    const b = parseInt(hex.substring(5, 7), 16);
    const lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
    return lum > 0.68 ? '#1C1917' : '#FFFFFF';
  }

  /** 强调色上的对比色（提醒条底色用强调色时，文字取它） */
  static onAccent(): string {
    const hex = Theme.cfg.accent;
    if (hex.length < 7) {
      return '#FFFFFF';
    }
    const r = parseInt(hex.substring(1, 3), 16);
    const g = parseInt(hex.substring(3, 5), 16);
    const b = parseInt(hex.substring(5, 7), 16);
    const lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
    return lum > 0.68 ? '#1C1917' : '#FFFFFF';
  }

  private static hex2(v: number): string {
    const n = Math.round(v < 0 ? 0 : (v > 255 ? 255 : v));
    const s = n.toString(16).toUpperCase();
    return s.length < 2 ? '0' + s : s;
  }

  /** 按比例混合两色（r=0 全 a，r=1 全 b） */
  static mix(a: string, b: string, r: number): string {
    if (a.length < 7 || b.length < 7) {
      return a;
    }
    const ar = parseInt(a.substring(1, 3), 16);
    const ag = parseInt(a.substring(3, 5), 16);
    const ab = parseInt(a.substring(5, 7), 16);
    const br = parseInt(b.substring(1, 3), 16);
    const bg = parseInt(b.substring(3, 5), 16);
    const bb = parseInt(b.substring(5, 7), 16);
    return '#' + Theme.hex2(ar + (br - ar) * r) + Theme.hex2(ag + (bg - ag) * r) + Theme.hex2(ab + (bb - ab) * r);
  }

  static textMain(): string {
    return Theme.cfg.textPrimary;
  }

  static textSub(): string {
    return Theme.cfg.textSecondary;
  }

  /**
   * 组件衬底色：主色与底色按比例混出的一层浅底（卡片内嵌块 / 未选中项 / 输入框）。
   * 各设置页此前散落 `mix(tsoft, '#FFFFFF', 0.5)` 这类字面调用，
   * 收敛到这里，换色系时不必逐处改。
   */
  static innerColor(r: number = 0.5): string {
    return Theme.mix(Theme.softColor(), '#FFFFFF', r);
  }

  /**
   * 主容器底色（大卡片 / 面板）：**白**，但**半透明**。
   *
   * ## 为什么必须收敛到这里（2026-09-28 血案）
   * 原本大卡写的是 `Color.White` —— 那是**完全不透明**的实白，
   * 垫在 `Mat.card()`（白毛玻璃）下面等于实心白块，材质永远透不出来。
   * 有人（我）为了修"材质被盖死"把它改成了 `alphaOf(tpage, 0.10)` ——
   * 结果**矫枉过正**：`tpage` 本身接近白色，再乘 0.10 → 等于没有底色，
   * 卡片的"主容器"整个消失，只剩下内层副容器（`innerColor`）还有颜色。
   *
   * ## 正确做法：保留"白"这个色相，只把 alpha 降到中间值
   * 「色相」与「不透明度」是两个独立维度 —— 不能为了透而牺牲色相。
   * 白 = 主容器；soft 色调 = 副容器（`innerBase()`）。两层都半透明，材质都能透。
   *
   * @param a 不透明度，默认 0.45（够白、但材质透得出来）
   */
  static cardBase(a: number = 0.45): string {
    return Theme.alphaOf('#FFFFFF', a);
  }

  /**
   * 副容器底色（卡片内的嵌套块：转写视口 / 答案框 / 输入框）：**中性**，半透明。
   *
   * 【2026-09-29 第三十次修正 · 去色系化】
   * 原实现是 `mix(softColor(), '#FFFFFF', r)` —— `softColor()` 是**跟随四套色系**的暖色
   * （故宫系 `#F7E9E3` 是浅粉），于是听课页 / 设置页里所有嵌套块都是**一片浅粉**，
   * 用户反馈「极简主义没覆盖到听课和语音识别页」。
   * → 改用**系统中性底**（`ohos_id_color_sub_background`，深色模式自动切换），
   *   保留半透明以保证 `Mat.tile()` 材质能透出下方内容。
   *
   * ⚠️ 与 `innerColor()` 的分工不变：
   *   · `innerColor()` —— 不挂材质的实色版（跟随色系，仅剩少数场景）
   *   · `innerBase()`  —— 挂 `Mat.tile()` 的可透版（**中性**，优先用这个）
   */
  static innerBase(a: number = 0.62): string {
    return Theme.alphaOf(Theme.sysInnerHex(), a);
  }

  /**
   * 系统中性底的十六进制代理值 —— 供需要"参与颜色运算"的场景使用
   * （`alphaOf()` / `mix()` 只吃字符串，吃不下 `Resource`）。
   *
   * ⚠️ 这是**刻意的近似**：拿不到系统资源在运行时的真实取值，
   *    所以按当前深浅色各给一个中性灰。深色模式下的**精确**取值由
   *    直接使用 `$r('sys.color.*')` 的调用点负责；本方法只服务那些
   *    必须先做 alpha 混合的少数场景，影响面已收敛到 `innerBase()` /
   *    `floatGlassBase()` 两处。
   *
   * 【2026-09-30 修正 · 深色模式】原实现恒返回浅灰 `#F1F3F5` ——
   * 深色主题下这两个"半透中性底"比页面底还亮，浮板反而更刺眼。现按
   * `isDark()` 分支：浅色给浅灰、深色给深灰。
   */
  private static sysInnerHex(): string {
    return Theme.isDark() ? '#2E3134' : '#F1F3F5';
  }

  /**
   * 当前是否处于深色模式。
   *
   * 取值来源：`AbilityContext.config.colorMode`（系统在主题切换时会更新它）。
   * 拿不到 context 时保守返回 false（当作浅色，与之前行为一致）。
   *
   * ⚠️ 这是**给"必须先做颜色运算"的少数场景**兜底用的。
   * 绝大多数颜色直接写 `$r('sys.color.*')`，由系统按主题自动选值，**不需要**经过这里。
   */
  static isDark(): boolean {
    const ctx = Theme.appCtx;
    if (ctx == null) {
      return false;
    }
    try {
      return ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (e) {
      return false;
    }
  }

  /** 由 `Theme.init()` 注入的 AbilityContext（唯一用途是查色彩模式） */
  private static appCtx: common.UIAbilityContext | undefined = undefined;

  /** 记录 AbilityContext；在 `Theme.load()` 或 EntryAbility 里调一次即可 */
  static attachContext(ctx: common.UIAbilityContext): void {
    Theme.appCtx = ctx;
  }

  /**
   * 顶栏 / 底栏**悬浮胶囊**的降级底色（中性半透明）。
   *
   * 【2026-09-29 新增】原来三页各自写 `alphaOf(mix(softColor, #FFF, 0.25), 0.45)` ——
   * 色相跟着四套色系走（故宫系就是淡粉），与"极简主义 / 中性骨架"冲突。
   * 收敛到这里：色相中性、alpha 给足透明度让 `Mat.bar()` 材质能透出下方内容。
   *
   * ⚠️ 课表页**不用**这个 —— 课表页整体保留色系（用户明确要求）。
   */
  static floatGlassBase(): string {
    return Theme.alphaOf(Theme.sysInnerHex(), 0.45);
  }

  /** 选中态衬底：主色调浅（比 innerColor 更"有颜色"，用于单选行背景） */
  static tintColor(r: number = 0.88): string {
    return Theme.mix(Theme.themeColor(), '#FFFFFF', r);
  }

  /**
   * `#RRGGBB` → `#AARRGGBB`，把任意色值降成半透明（a 取 0~1）。
   *
   * 与 `Mat.alpha()` 的区别：那个只接受 `#RRGGBB` 且用于材质着色，
   * 这个专供 `backgroundColor` 的**降级底**用 —— 液态玻璃等场景需要
   * "材质不生效时也别糊住内容"的低不透明底色。
   * 解析不出来时原样返回（交给系统忽略，不抛）。
   */
  static alphaOf(hex: string, a: number): string {
    if (hex.length < 7) {
      return hex;
    }
    let n = Math.round(a * 255);
    if (n < 0) {
      n = 0;
    }
    if (n > 255) {
      n = 255;
    }
    return '#' + Theme.hex2(n) + hex.substring(1);
  }

  /**
   * 玻璃边缘高光色 —— 液态玻璃板的上缘那条"受光面"。
   *
   * 为什么不用纯白：纯白在浅色课表上会显得像一条"缝"，而不是玻璃的反光。
   * 这里按**亮色模式**取近白微暖（与国画色系的暖调一致），
   * 让它读起来是"玻璃受光"而不是"边框"。
   */
  static glassHighlight(): string {
    return Theme.mix('#FFFFFF', Theme.softColor(), 0.18);
  }

  /**
   * 未激活控件的衬底（按钮 / 分段选项 / chip 的「没选中」态）。
   *
   * 用户要求：这些控件「没显示 / 没被选中」时加一点**暗橙底色**，且随配色一起变。
   * 做法不是写死橙色，而是拿**主色往深里压**：
   *   先取主色与强调色 3:7 混出偏深的基色，再与页面底色 30:70 调淡，
   *   得到一个"看得出是主题色、但明显比激活态沉"的中性偏色底。
   * 好处：换成青灰蓝/棉絮灰等任何色系时，这层底色自动跟着走，不会串色。
   *
   * 对比：激活态走 `themeColor()`（饱和高明度），未激活走这里的「暗一档」，
   * 两者深浅差异即构成"激活/未激活"的视觉层级，不再依赖灰色灰底。
   */
  static idleColor(): string {
    const base = Theme.mix(Theme.themeColor(), Theme.accentColor(), 0.7);
    return Theme.mix(base, Theme.pageColor(), 0.7);
  }

  /** 未激活控件上的文字色：暗底上要比 `textSub()` 再实一点，保证可读 */
  static idleInk(): string {
    return Theme.mix(Theme.textMain(), Theme.idleColor(), 0.35);
  }

  /** 主题底色（页面底色之上的那一层，用于顶层栏 / 分区容器） */
  static pageInk(): string {
    return Theme.softColor();
  }

  // ==========================================================================
  // 【2026-09-28 第二十四次修正 · 中性骨架（系统资源色）】
  //
  // ## 用户要求（原话）
  // > 「分隔线是浅灰色，但是它的背景是深灰色，然后它的卡片是纯白色。
  // >   如果你切换成了深色模式的话，那你就能看到它的卡片是浅黑色，但是它的背景变成了深黑色。」
  // > 「这个主题色只是跟课表不同课程的格子里面的颜色是一样的，并不影响其他的颜色。」
  // > 「除了课表页面，剩下的全部改。」
  // > （配色页）「改成色板预览」
  //
  // ## 架构决策：中性骨架 + 内容色板，两套体系解耦
  // 改造前全站是**一套主题色系**管到底（页面底 / 卡片底 / 文字 / 课表块全跟着 soft/theme 走），
  // 于是产生两个问题：
  //   ① 换色系时整页变橙/变紫，但用户其实只想要课表变；
  //   ② 深色模式无从下手 —— 主题色是**算出来的 hex**，系统给不出它的深色版本。
  //
  // 现在拆成两层：
  //   · **中性骨架**（本区块，返回 `Resource`）—— 页面底 / 卡片 / 分隔线 / 文字。
  //     走系统资源，`_dark` 变体由系统自动选 → 深色模式**零成本支持**。
  //   · **内容色板**（`paletteRaw()` / `themeColor()`）—— 只用于课表课程块 + 选中态/强调元素。
  //     仍走四套国画色系。
  //
  // ## ⚠️ 为什么单独开一组方法而不是改 `pageColor()` / `textMain()`
  // 那批方法返回 **`string`**，而 `mix()` / `alphaOf()` 只接受字符串——
  // 一旦把它们的返回类型改成 `Resource`，所有做颜色运算的调用点会**编译崩**。
  // 所以新方法是**增量的**：需要"能做颜色运算"的地方继续用旧字符串方法，
  // 需要"跟随系统深浅色"的地方改用这组新方法。
  //
  // ## 资源名核对（SDK `sysResource.js`，非猜测）
  //   `ohos_id_color_sub_background`        页面底（次级背景）
  //   `ohos_id_color_card_bg`               卡片底
  //   `ohos_id_color_list_separator`        列表分隔线
  //   `ohos_id_color_subheading_separator`  二级标题分隔线
  //   `ohos_id_color_text_primary`          主文字
  //   `ohos_id_color_text_secondary`        次文字
  //   `ohos_id_color_text_tertiary`         三级文字
  //   `ohos_id_color_emphasize`             强调（选中态）
  // ==========================================================================

  /** 页面底色（中性）。浅色模式下浅灰、深色模式下深黑 —— 由系统决定 */
  static sysPage(): Resource {
    return $r('sys.color.ohos_id_color_sub_background');
  }

  /** 卡片 / 分组容器底（中性）。浅色纯白、深色浅黑 */
  static sysCard(): Resource {
    return $r('sys.color.ohos_id_color_card_bg');
  }

  /** 列表项之间的分隔线（中性灰） */
  static sysSeparator(): Resource {
    return $r('sys.color.ohos_id_color_list_separator');
  }

  /** 分组标题下方的分隔线（比列表分隔线更明显一档） */
  static sysHeadingSeparator(): Resource {
    return $r('sys.color.ohos_id_color_subheading_separator');
  }

  /** 主文字色（中性，随深浅色反转） */
  static sysTextMain(): Resource {
    return $r('sys.color.ohos_id_color_text_primary');
  }

  /** 次文字色（中性，随深浅色反转） */
  static sysTextSub(): Resource {
    return $r('sys.color.ohos_id_color_text_secondary');
  }

  /** 三级文字色（更弱的辅助信息） */
  static sysTextWeak(): Resource {
    return $r('sys.color.ohos_id_color_text_tertiary');
  }

  /**
   * **底栏专用**背景色（系统语义：底部页签栏的底）。
   *
   * 【2026-09-30 新增 · 修「深色模式下底栏没跟随」】
   *
   * ## 为什么不能用 `sysPage()` / `sysCard()` 顶替
   * 系统专门给底栏开了一组资源（`ohos_id_color_bottom_tab_bg` + `_dark` 变体），
   * 它的取值是**按栏体场景调过的**（不是页面底那种大面积中性色）。
   * 底栏该用底栏的资源，这才符合"系统给什么用什么"的整体路线。
   *
   * ## 用于哪里
   * `HdsTabs.barFloatingStyle.lightColor` —— 悬浮胶囊栏体的光效/底色。
   * 不传时 HDS 走自己的默认值 `#33FFFFFF`（浅色），**实测深色下不跟随**，
   * 于是出现「图标已反色成白、栏体还是白的」这种白底白图标。
   */
  static sysBottomTabBg(): Resource {
    return $r('sys.color.ohos_id_color_bottom_tab_bg');
  }

  /**
   * 底栏**毛玻璃版**背景色（`..._bg_blur`）。
   * 语义与 `sysBottomTabBg()` 相同，但按"材质是磨砂玻璃"这个前提调过不透明度，
   * 挂在栏体上时能透出下方内容 —— 沉浸光感场景应当优先用这个。
   */
  static sysBottomTabBgBlur(): Resource {
    return $r('sys.color.ohos_id_color_bottom_tab_bg_blur');
  }

  /** 强调色（系统语义：选中态 / 高亮），**不跟我们的四套色系走** */
  static sysEmphasize(): Resource {
    return $r('sys.color.ohos_id_color_emphasize');
  }

  /**
   * 系统强调色**实底之上**的文字色。
   *
   * 【2026-09-28 第二十九次修正 · 从系统反色资源改回确定白】
   *
   * ## 原来的错（用户真机反馈：「字体颜色没改，导致现在看的是灰色的，看不到里面的内容」）
   * 我原先返回 `$r('sys.color.ohos_id_color_emphasize_contrary')`，
   * 想当然地以为"强调色上的反色"就是白。**实测不是** ——
   * 系统给这个资源在浅色主题下算出的是一组偏暗的值（它是按"浅蓝强调底"配的），
   * 贴在我们这种饱和蓝实底上 → 灰扑扑、几乎读不出字。
   *
   * ## 为什么改回硬编码白
   * 底色是我们**主动指定**的 `sysEmphasize()` —— 它在浅色/深色下都是**中深蓝**，
   * 白字在两种模式下对比度都足够。既然底色可控，文字色就不该交给会漂移的系统资源。
   * （华为应用市场、系统按钮的蓝底白字也是这个取值。）
   *
   * ⚠️ 与 `onTheme()` 的分工：
   *   · 底色 `sysEmphasize()`（系统蓝）→ 用 `onEmphasize()`（白）
   *   · 底色 `this.tc`（我们的主题色，可能是浅黄）→ 用 `onTheme()`（按亮度算深浅）
   */
  static onEmphasize(): string {
    return '#FFFFFF';
  }

  /**
   * 系统强调色的**十六进制代理值**。
   *
   * 【2026-10-02 新增】只服务那些**只吃字符串、吃不下 `Resource`** 的绘制 API ——
   * 目前唯一调用点是 `LiquidToggle` 的液体层（`CanvasRenderingContext2D.fillStyle`）。
   *
   * ⚠️ 与 `sysInnerHex()` 同一性质的**刻意近似**：拿不到系统资源在运行时的真实取值，
   *    所以按当前深浅色各给一个系统强调蓝。**绝大多数调用点应当直接用 `sysEmphasize()`**，
   *    不要图省事换到这里 —— 它的取值不跟系统主题包更新，只是近似。
   */
  static sysEmphasizeHex(): string {
    return Theme.isDark() ? '#317AF7' : '#0A59F7';
  }

  /**
   * 系统**中性填充色**（未选中控件的底） —— 语义等同"普通按钮未按下时的底色"。
   *
   * 【2026-09-28 新增】原 `idleColor()` 是拿主题色 + 强调色混出来的**暖褐**，
   * 跟着四套色系走 → 在浅色系下是一块脏黄，和华为应用市场那种干净的中性灰差很远
   * （用户截图反馈）。系统这个资源深色模式有 `_dark` 变体，自动切换。
   *
   * ⚠️ 与 `idleColor()` 的分工：
   *   · `sysFill()`      —— **选择器 / 分段控件**的未选中底（中性、不跟色系）
   *   · `idleColor()`    —— 保留给仍要跟随色系的场景（不要再往新控件上铺）
   */
  static sysFill(): Resource {
    return $r('sys.color.ohos_id_color_button_normal');
  }

  /**
   * 中性填充底（`sysFill()`）之上的文字色。
   *
   * 【2026-09-28 第二十九次修正】`ohos_id_color_text_secondary` 在本机实测偏灰，
   * 配浅灰底层次太弱。改用系统**主文字色** —— 浅灰底上是深字、深色模式下自动转浅字，
   * 对比度足够（华为应用市场未选中项的取值也是主文字色）。
   */
  static sysFillInk(): Resource {
    return $r('sys.color.ohos_id_color_text_primary');
  }

  // ---- 语义色（跨页面统一；不要在各页各写一份十六进制） ----

  /** 危险操作（删除 / 清空） */
  static danger(): string {
    return '#C0392B';
  }

  /** 成功 / 已就绪 */
  static success(): string {
    return '#16A34A';
  }

  /** 警告 / 需注意 */
  static warn(): string {
    return '#FF6A00';
  }

  /** 未选中控件的中性灰（单选框圆点、chip 底、次级文字） */
  static neutral(): string {
    return '#D9D9D9';
  }

  /** 分隔线 / 箭头等极淡前景 */
  static hairline(): string {
    return Theme.mix(Theme.textSub(), '#FFFFFF', 0.55);
  }

  /**
   * 主色（theme）的超浅着色底。
   *
   * 用途：**中性容器底**——卡片里再套一层浅底块，但这层不该"抢戏"。
   * 之前各页散落 `Theme.mix(this.soft, '#FFFFFF', 0.5)`，等于 `innerColor(0.5)`：
   * soft 本身就带色相，再混白 50% 仍然偏黄（丹橘下有肉眼可见的暖调）。
   *
   * 这里改成**主题色混白 92%**，色相与主色一致但极淡，
   * 换色系时整页基调整体跟着走，不会出现"主题是蓝、底块还是暖黄"的割裂。
   */
  static subtleColor(): string {
    return Theme.mix(Theme.themeColor(), '#FFFFFF', 0.92);
  }

  /**
   * 极小面积点缀（如日期格子里的"今天"底）。
   * 比 subtleColor 再深一档，仍属"背景级"而非"控件级"。
   */
  static tintSoft(): string {
    return Theme.mix(Theme.themeColor(), '#FFFFFF', 0.84);
  }

  /** 课表 10 色板（按 blockFamily） */
  static paletteRaw(): string[][] {
    return Theme.familyOf(Theme.cfg.blockFamily).palette;
  }

  /** 一键换整配色系：UI 主题 + 强调色 + 课表色板一起换 */
  static async applyFamily(key: string): Promise<void> {
    const f = Theme.familyOf(key);
    Theme.cfg.family = f.key;
    Theme.cfg.blockFamily = f.key;
    Theme.cfg.theme = f.theme;
    Theme.cfg.accent = f.accent;
    Theme.cfg.soft = f.soft;
    await Theme.save();
  }

  /** 只换课表配色系（不影响 UI 主题色） */
  static async applyBlockFamily(key: string): Promise<void> {
    Theme.cfg.blockFamily = Theme.familyOf(key).key;
    await Theme.save();
  }

  /**
   * 内容字色：命中**课程名 / 地点 / 校区**任一关键字即返回该颜色，否则 ''。
   * （原来只匹配地点，现按需求扩到课程名 —— 例如「英语 → 蓝色」「基教 → 红色」都能配）
   */
  static regionColor(name: string, location: string, campus: string): string {
    for (const r of Theme.cfg.rules) {
      if (r.match.length === 0) {
        continue;
      }
      if (name.indexOf(r.match) >= 0 || location.indexOf(r.match) >= 0 || campus.indexOf(r.match) >= 0) {
        return r.color;
      }
    }
    return '';
  }
}
