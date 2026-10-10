import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ColorFamily, Theme, ThemeRule } from '../common/Theme';
import { Mat } from '../common/Material';
import { WindowInsets } from '../common/WindowInsets';
import { FontSize, Weight, Space, Radius, Size, Motion, Layout } from '../common/DesignToken';


/** 选色面板里的常用色板（取自四套国画配色 + 中性色，覆盖全部色相） */
const SWATCHES: string[] = [
  // 故宫 · 橙绯红系
  '#C0492F', '#E68D59', '#866040', '#2E2F25',
  // 园博园 · 淡藤萝紫系
  '#B99A8E', '#D3A488', '#B0AEA0', '#1D4C50',
  // 盘龙纹 · 棉絮灰系
  '#8A8375', '#635045', '#AF5F54', '#3B4E3D',
  // 北海 · 柴染棕系
  '#8A6A4A', '#D1AA78', '#3F605B', '#C4BDB0',
  // 中性 / 文字色
  '#1C1917', '#78716C', '#B8B2AA', '#FFFFFF',
];

/**
 * 配色设置页。
 *
 * 三层可调：
 * ① 预制色系（丹橘/群青/竹青/朱砂/黛紫/松石）—— 一键把 主题色 + 强调色 + 课表色板 整套换掉；
 * ② 每个模块单独指定（主题色 / 提醒强调色 / 课表配色系 / 主字色 / 次字色），支持十六进制输入与色板选色；
 * ③ 「地区 → 字色」规则：课表里地点或校区命中关键字时，那块课的文字用指定颜色。
 */
@Entry
@Component
struct ThemeSettings {
  // ---- 主题镜像：ArkUI 只观察「渲染中读取过」的状态；配色变化必须镜像成 @State 才会重绘 ----
  @State tc: string = Theme.themeColor();
  @State tacc: string = Theme.accentColor();
  @State tsoft: string = Theme.softColor();
  @State tpage: string = Theme.pageColor();
  @State ton: string = Theme.onTheme();
  @State tmain: string = Theme.textMain();
  @State tsub: string = Theme.textSub();

  @State family: string = 'gong';
  @State blockFamily: string = 'gong';
  @State theme: string = '#C0492F';
  @State accent: string = '#2E2F25';
  @State textPrimary: string = '#1C1917';
  @State textSecondary: string = '#78716C';
  @State scheduleBg: string = '';
  @State rules: ThemeRule[] = [];
  @State rev: number = 0;

  // 选色面板
  @State showPanel: boolean = false;
  @State pickTarget: string = '';     // theme | accent | textPrimary | textSecondary | rule
  @State pickIdx: number = -1;
  @State pickHex: string = '';
  @State pickMatch: string = '';

  private syncTheme(): void {
    this.tc = Theme.themeColor();
    this.tacc = Theme.accentColor();
    this.tsoft = Theme.softColor();
    this.tpage = Theme.pageColor();
    this.ton = Theme.onTheme();
    this.tmain = Theme.textMain();
    this.tsub = Theme.textSub();
  }

  aboutToAppear(): void {
    Layout.init();
    // 沉浸光感：EntryAbility 已 init，这里再调一次（幂等）以覆盖「router 直接进本页」
    Mat.init();
    // 系统栏避让：全屏沉浸下自绘顶栏要补状态栏高度（异步回填，兜底值撑首帧）
    WindowInsets.sync();
    Theme.onChange(() => {
      this.syncTheme();
    });
    this.syncTheme();

    const ctx = getContext(this) as common.UIAbilityContext;
    Theme.init(ctx);   // 本页要写配置，必须先确保已加载
    this.pull();
  }

  private pull(): void {
    const c = Theme.cfg;
    this.family = c.family;
    this.blockFamily = c.blockFamily;
    this.theme = c.theme;
    this.accent = c.accent;
    this.textPrimary = c.textPrimary;
    this.textSecondary = c.textSecondary;
    this.scheduleBg = c.scheduleBg;
    this.rules = c.rules.slice();
    this.rev += 1;
  }

  private labelOf(target: string): string {
    switch (target) {
      case 'theme': return 'UI 主题色';
      case 'accent': return '提醒 / 强调色';
      case 'textPrimary': return '主字色';
      case 'textSecondary': return '次字色';
      case 'scheduleBg': return '课表背景色';
      default: return '地区字色';
    }
  }

  private openPanel(target: string, idx: number): void {
    this.pickTarget = target;
    this.pickIdx = idx;
    if (target === 'theme') {
      this.pickHex = this.theme;
    } else if (target === 'accent') {
      this.pickHex = this.accent;
    } else if (target === 'textPrimary') {
      this.pickHex = this.textPrimary;
    } else if (target === 'textSecondary') {
      this.pickHex = this.textSecondary;
    } else if (target === 'scheduleBg') {
      // 空（跟随色系）时给一个合理的起始值，别让输入框是空的
      this.pickHex = this.scheduleBg.length > 0 ? this.scheduleBg : Theme.softColor();
    } else if (idx >= 0 && idx < this.rules.length) {
      this.pickHex = this.rules[idx].color;
      this.pickMatch = this.rules[idx].match;
    } else {
      this.pickHex = this.theme;
      this.pickMatch = '';
    }
    this.showPanel = true;
  }

  private validHex(): boolean {
    return /^#[0-9a-fA-F]{6}$/.test(this.pickHex);
  }

  private applyPick(): void {
    const hex = this.pickHex.toUpperCase();
    const c = Theme.cfg;
    if (this.pickTarget === 'theme') {
      c.theme = hex;
    } else if (this.pickTarget === 'accent') {
      c.accent = hex;
    } else if (this.pickTarget === 'textPrimary') {
      c.textPrimary = hex;
    } else if (this.pickTarget === 'textSecondary') {
      c.textSecondary = hex;
    } else if (this.pickTarget === 'scheduleBg') {
      c.scheduleBg = hex;
    } else {
      const match = this.pickMatch.trim();
      if (match.length === 0) {
        AlertDialog.show({
          title: '请填写关键字',
          message: '例如「基教」或「北校区」，课表里地点/校区包含它时就用这个颜色。',
          confirm: { value: '好', action: () => {} },
        });
        return;
      }
      const r = new ThemeRule();
      r.match = match;
      r.color = hex;
      const list = this.rules.slice();
      if (this.pickIdx >= 0 && this.pickIdx < list.length) {
        list[this.pickIdx] = r;
      } else {
        list.push(r);
      }
      c.rules = list;
    }
    Theme.save().then(() => {
      this.showPanel = false;
      this.pull();
    });
  }

  private removeRule(idx: number): void {
    const list = Theme.cfg.rules.slice();
    list.splice(idx, 1);
    Theme.cfg.rules = list;
    Theme.save().then(() => {
      this.pull();
    });
  }

  // ---------- UI ----------

  /**
   * 自绘顶栏（返回键 + 标题「配色」）。
   *
   * ⛔ 不用 `HdsNavigation`：真机实测其子树永不渲染（整页白屏），详见 `common/RouteBar.ets` 头部。
   * 本页标题是纯静态文字，但外层套着 `Stack`（承载 `colorPanel()` 浮层），
   * `build()` 里已有一层 `Column`，故顶栏写成页面内 `@Builder`（与 ImportSchedule 同规格）。
   *
   * 视觉规格与 `RouteBar` / `Settings.barContent()` 完全一致（主题色满铺 + `Size.bar` 高度 +
   * 状态栏避让 + 右上白底胶囊），Tab 内页 ⇄ 路由页跳转不会"跳一下"。
   */
  @Builder
  barContent() {
    Row() {
      // 返回键：48×48 触控热区（官方无障碍硬指标）
      Text('\u2039')
        .fontSize(FontSize.titleM)
        .fontColor(this.ton)
        .width(Size.touchTarget)
        .height(Size.touchTarget)
        .textAlign(TextAlign.Center)
        .borderRadius(Radius.full)
        .onClick(() => {
          router.back();
        })

      // 标题
      Column() {
        Text('配色')
          .fontSize(FontSize.titleS)
          .fontWeight(Weight.bold)
          .fontColor(this.ton)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .padding({ left: Space.s })
    }
    .width('100%')
    // height 补状态栏高度：全屏沉浸下页面延伸到状态栏下方（见 WindowInsets.ets）
    .height(Size.bar + WindowInsets.statusBarVp())
    // 左右边距与内容区对齐（screenMargin），顶栏本身仍是满铺色条
    .padding({
      left: Layout.screenMargin(),
      right: Layout.screenMargin(),
      top: WindowInsets.statusBarVp(),
    })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.tc)
    .systemMaterial(Mat.bar())
  }

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(FontSize.bodyS)
      .fontWeight(Weight.medium)
      .fontColor(Theme.sysTextSub())
      .width('100%')
      .padding({ left: Space.xs, top: Space.l, bottom: Space.s })
  }

  /**
   * 色系卡片 —— **色板预览**形态（2026-09-28 第二十五次修正）。
   *
   * ## 为什么从「胶囊 chip」改成「色板预览卡」
   * 用户要求：「（配色页）改成色板预览」。
   *
   * 原形态是一个小圆点 + 色系名，选中的整颗染成主题色。这在**改造前**是合理的
   * —— 那时切色系会让**整页**变橙/变紫，圆点颜色就是"整页会变成什么样"的预告。
   *
   * 但本次改造后**主题色只影响课表 + 强调元素**了（页面底/卡片/文字全走系统中性色阶），
   * 于是"切了色系整页没反应"，用户会以为功能坏了。色板预览正是为了解决这个：
   * **把该色系的 10 个课程块颜色直接铺出来**，一眼看到"选它课表长什么样"。
   *
   * ## 形态
   * ```
   * ┌──────────────────────────────────────┐
   * │ ▮▮▮▮▮▮▮▮▮▮   故宫·橙绯红          ✓ │   ← 10 个课程色块 + 名称
   * └──────────────────────────────────────┘
   * ```
   * · 左：该色系 `palette` 的 10 个**强调色**（每项第 3 个色值 = 课程块色带的颜色）小方块
   * · 中：色系名
   * · 右：选中打勾（主题色）
   * · 选中态：卡片描边主题色 + 极浅主题色底
   *
   * ## 用户原话（本次方案拍板）
   * > 「四套主题色系以后只影响课表 + 强调元素」
   * > 「（配色页）改成色板预览（推荐）」
   */
  @Builder
  familyChips() {
    Column() {
      ForEach(Theme.FAMILIES, (f: ColorFamily) => {
        Row() {
          // ---- 左：10 个课程色块缩略 ----
          Row() {
            ForEach(f.palette, (c: string[], ci: number) => {
              Column()
                .width(Size.iconXs)
                .height(Size.iconXs)
                .borderRadius(Radius.xs)
                // 每项 = [浅底, 深字, 强调条]，取强调条（第 3 个）——
                // 它是课程块色带的颜色，最能代表"这块课长什么样"。
                .backgroundColor(c[2])
                .margin({ right: ci === f.palette.length - 1 ? Space.none : 3 })
            }, (c: string[], ci: number) => `pf-${f.key}-${ci}`)
          }
          .layoutWeight(1)

          // ---- 中：色系名 ----
          Text(f.label)
            .fontSize(FontSize.subtitleS)
            .fontWeight(Weight.medium)
            .fontColor(Theme.sysTextMain())
            .margin({ left: Space.m })

          // ---- 右：选中打勾 ----
          if (f.key === this.blockFamily) {
            Text('✓')
              .fontSize(FontSize.subtitleM)
              .fontWeight(Weight.bold)
              .fontColor(this.tc)
              .margin({ left: Space.xs })
          }
        }
        .width('100%')
        .padding({ left: Space.m, right: Space.m, top: Space.m, bottom: Space.m })
        .borderRadius(Radius.m)
        // 选中：极浅主题色底（不是满铺 —— 满铺会把色板本身的颜色压掉）；未选中：透明
        .backgroundColor(f.key === this.blockFamily ? Theme.tintColor(0.92) : '#00000000')
        .border({
          width: 1,
          // 选中：主题色描边；未选中：系统分隔线色
          color: f.key === this.blockFamily ? this.tc : Theme.sysSeparator(),
        })
        .margin({ bottom: Space.s })
        .onClick(() => {
          Theme.applyBlockFamily(f.key).then(() => {
            this.pull();
          });
        })
      }, (f: ColorFamily) => `fam-${f.key}-${this.blockFamily}-${this.rev}`)
    }
    .width('100%')
  }

  /**
   * ⛔ **已删除：`blockFamilyChips()`（2026-09-28 第二十五次修正）**
   *
   * 它原本是"课表配色系"的独立选择器（小圆点 + 名称的胶囊）。
   * 现在 `familyChips()` 已升级为**色板预览卡**、并接管了"选课表配色"这一职责，
   * 两者功能完全重叠 → 删掉这个，只留色板预览（信息量更大、更直观）。
   *
   * 保留这条注释是为了说明**为什么 build() 里不再有它**，
   * 免得下次有人看到"课表配色选择器不见了"又新加一个出来。
   */

  /** 一行颜色项：名称 + 当前色值（点开选色面板） */
  @Builder
  colorRow(label: string, value: string, target: string) {
    Row() {
      Text(label)
        .fontSize(FontSize.subtitleM)
        .fontColor(Theme.sysTextMain())
        .layoutWeight(1)
      Column()
        .width(Size.iconS)
        .height(Size.iconS)
        .borderRadius(Radius.s)
        .backgroundColor(value)
        .border({ width: 1, color: '#00000022' })
      Text(value)
        .fontSize(FontSize.bodyS)
        .fontColor(Theme.sysTextSub())
        .margin({ left: Space.s })
      Text('›')
        .fontSize(FontSize.subtitleL)
        .fontColor(Theme.hairline())
        .margin({ left: Space.xs })
    }
    .width('100%')
    .constraintSize({ minHeight: Size.touchTarget })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.openPanel(target, -1);
    })
  }

  /**
   * 课表背景色区（2026-09-28 从设置页搬来）。
   *
   * 语义：`Theme.scheduleBg` 为空 = **跟随色系**（用当前色系的容器底色），
   * 非空 = 用户显式指定的固定色。设一个显式值后换色系不会跟着动，所以
   * 首项固定给「跟随色系」这个可撤销的选项，避免用户"选进去出不来"。
   */
  @Builder
  scheduleBgBlock() {
    Column() {
      Row() {
        Text('背景色')
          .fontSize(FontSize.subtitleM)
          .fontColor(Theme.sysTextMain())
          .layoutWeight(1)
        Text(this.scheduleBg.length === 0 ? '跟随色系' : this.scheduleBg)
          .fontSize(FontSize.bodyS)
          .fontColor(Theme.sysTextSub())
      }
      .width('100%')
      .constraintSize({ minHeight: Size.touchTarget })
      .alignItems(VerticalAlign.Center)

      // 候选色：首项「跟随色系」用斜线占位表示"无固定值"
      Flex({ wrap: FlexWrap.Wrap }) {
        // ① 跟随色系
        Column() {
          Text('跟')
            .fontSize(FontSize.bodyS)
            .fontWeight(Weight.medium)
            .fontColor(this.scheduleBg.length === 0 ? this.ton : Theme.sysTextSub())
        }
        .width(Size.iconL)
        .height(Size.iconL)
        .borderRadius(Radius.s)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.scheduleBg.length === 0 ? this.tc : Theme.idleColor())
        .border({ width: 1, color: '#00000022' })
        .margin({ right: Space.s, bottom: Space.s })
        .onClick(() => {
          Theme.cfg.scheduleBg = '';
          Theme.save().then(() => {
            this.pull();
          });
        })

        // ② 沿色系派生的几档 + 中性白
        ForEach(this.bgSwatches(), (c: string) => {
          Column()
            .width(Size.iconL)
            .height(Size.iconL)
            .borderRadius(Radius.s)
            .backgroundColor(c)
            .border(this.scheduleBg.toUpperCase() === c.toUpperCase()
              ? { width: 3, color: this.tc }
              : { width: 1, color: '#00000022' })
            .margin({ right: Space.s, bottom: Space.s })
            .onClick(() => {
              Theme.cfg.scheduleBg = c;
              Theme.save().then(() => {
                this.pull();
              });
            })
        }, (c: string) => `sbg-${c}-${this.scheduleBg}`)

        // ③ 自定义取色
        Text('自定义…')
          .fontSize(FontSize.bodyS)
          .fontWeight(Weight.medium)
          .fontColor(Theme.sysEmphasize())
          .textAlign(TextAlign.Center)
          .height(Size.iconL)
          .padding({ left: Space.m, right: Space.m })
          .borderRadius(Radius.s)
          .backgroundColor(Theme.sysFill())
          .margin({ right: Space.s, bottom: Space.s })
          .onClick(() => {
            this.openPanel('scheduleBg', -1);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: Space.l, right: Space.l, top: Space.m, bottom: Space.s })
    .borderRadius(Radius.l)
    .backgroundColor(Theme.sysCard())
  }

  /**
   * 课表背景候选色：由当前色系派生，保证「换色系时这几个候选也跟着变」，
   * 而不是写死一堆中性灰。
   */
  private bgSwatches(): string[] {
    const soft = Theme.softColor();
    return [
      Theme.mix(soft, '#FFFFFF', 0.55),   // = pageColor()，最淡
      soft,                                // 容器底色
      Theme.mix(soft, '#000000', 0.06),   // 稍深
      '#FFFFFF',                           // 纯白
    ];
  }

  /** 选色面板：十六进制输入 + 常用色板 */
  @Builder
  colorPanel() {
    Column() {
      Column() {
        Text(this.labelOf(this.pickTarget))
          .fontSize(FontSize.subtitleL)
          .fontWeight(Weight.bold)
          .fontColor(Theme.sysTextMain())
          .width('100%')

        if (this.pickTarget === 'rule') {
          TextInput({ text: this.pickMatch, placeholder: '关键字，如「基教」「北校区」' })
            .fontSize(FontSize.subtitleM)
            .height(Size.touchTarget)
            .width('100%')
            .margin({ top: Space.m })
            .backgroundColor(Theme.sysCard())
            .borderRadius(Radius.m)
            .onChange((v: string) => {
              this.pickMatch = v;
            })
        }

        Row() {
          Column()
            .width(Size.iconL)
            .height(Size.iconL)
            .borderRadius(Radius.s)
            .backgroundColor(this.validHex() ? this.pickHex : Theme.neutral())
            .border({ width: 1, color: '#00000022' })
          TextInput({ text: this.pickHex, placeholder: '#RRGGBB' })
            .fontSize(FontSize.subtitleM)
            .height(Size.touchTarget)
            .layoutWeight(1)
            .margin({ left: Space.m })
            .backgroundColor(Theme.sysCard())
            .borderRadius(Radius.m)
            .onChange((v: string) => {
              this.pickHex = v;
            })
        }
        .width('100%')
        .margin({ top: Space.m })
        .alignItems(VerticalAlign.Center)

        Text('常用色板')
          .fontSize(FontSize.bodyS)
          .fontWeight(Weight.medium)
          .fontColor(Theme.sysTextSub())
          .width('100%')
          .margin({ top: Space.l, bottom: Space.s })

        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(SWATCHES, (c: string) => {
            Column()
              .width(Size.touchTarget)
              .height(Size.touchTarget)
              .borderRadius(Radius.s)
              .backgroundColor(c)
              .border(c.toUpperCase() === this.pickHex.toUpperCase()
                ? { width: 3, color: this.tmain }
                : { width: 1, color: '#0000001A' })
              .margin({ right: Space.s, bottom: Space.s })
              .onClick(() => {
                this.pickHex = c;
              })
          }, (c: string) => `sw-${c}-${this.pickHex}`)
        }
        .width('100%')

        Row() {
          Text('取消')
            .fontSize(FontSize.subtitleS)
            .fontWeight(Weight.medium)
            .fontColor(Theme.sysTextSub())
            .textAlign(TextAlign.Center)
            .padding({ left: Space.xxl, right: Space.xxl })
            .constraintSize({ minHeight: Size.touchTarget })
            .borderRadius(Radius.full)
            .backgroundColor(Theme.sysFill())
            .onClick(() => {
              this.showPanel = false;
            })
          Text('确定')
            .fontSize(FontSize.subtitleS)
            .fontWeight(Weight.medium)
            .fontColor(Theme.onEmphasize())
            .textAlign(TextAlign.Center)
            .padding({ left: Space.xxl, right: Space.xxl, top: Space.xs, bottom: Space.xs })
            .margin({ left: Space.m })
            .borderRadius(Radius.full)
            .backgroundColor(this.validHex() ? this.tc : Theme.neutral())
            .systemMaterial(Mat.button())
            .onClick(() => {
              if (this.validHex()) {
                this.applyPick();
              }
            })
        }
        .width('100%')
        .margin({ top: Space.l })
        .justifyContent(FlexAlign.Center)
      }
      .width('90%')
      .padding(Space.xl)
      .borderRadius(Radius.xl)
      .backgroundColor(Theme.sysCard())
      .systemMaterial(Mat.sheet())
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#00000055')
    .transition(Motion.fadeIn())
  }

  build() {
    // Stack 必须保留：colorPanel() 是靠它盖在内容之上的浮层
    Stack() {
      Column() {
        this.barContent()

        Scroll() {
          Column() {
            // ① 课表配色 —— 色板预览（2026-09-28 第二十五次修正 · 合并原 ①④ 两块）
            //
            // 【为什么合并】改造后**只有课表会跟着色系变**（页面底/卡片/文字全走系统中性色阶），
            // 所以原来的「预制色系（一键套用：主题色+强调色+课表色板）」这个说法已经不成立 ——
            // 它不再能"一键套用"出整页风格。现在统一成「课表配色」，语义准确：
            // **这里选什么，只决定课程块长什么样。**
            this.sectionTitle('课表配色（只影响课程块颜色）')
            Column() {
              this.familyChips()
            }
            .width('100%')
            .padding({ left: Space.l, right: Space.l, top: Space.m, bottom: Space.s })
            .borderRadius(Radius.l)
            .backgroundColor(Theme.sysCard())

            // ② 各模块独立配置
            // ⚠️ 「主字色 / 次字色」两项已移除（2026-09-28 第二十五次修正）——
            //    本次改造把全站文字色交给了系统资源（`sysTextMain` / `sysTextSub`），
            //    它们会跟随深/浅色模式自动反转。再留着手动色值入口，
            //    要么改了不生效（误导用户），要么得为它开一条绕过系统色的通路（自相矛盾）。
            //    留下「UI 主题色 / 强调色」—— 这两项影响的是**强调元素**（选中态 / 开关 / 按钮底），
            //    仍在四套色系的职责范围内。
            this.sectionTitle('分别指定（各模块独立）')
            Column() {
              this.colorRow('UI 主题色（选中态 / 开关 / 强调）', this.theme, 'theme')
              this.colorRow('提醒 / 强调色（当前节次、正在上的课）', this.accent, 'accent')
            }
            .width('100%')
            .padding({ left: Space.l, right: Space.l })
            .borderRadius(Radius.l)
            .backgroundColor(Theme.sysCard())

            // ③ 课表背景色（2026-09-28 从设置页搬来）
            this.sectionTitle('课表背景色（留空即跟随色系）')
            this.scheduleBgBlock()

            // ⑤ 地区字色
            this.sectionTitle('地区字色（地点 / 校区命中关键字时）')
            Column() {
              if (this.rules.length === 0) {
                Text('还没有规则。例如添加「基教 → 蓝色」，课表里地点含「基教」的课就用蓝色文字。')
                  .fontSize(FontSize.bodyM)
                  .fontColor(Theme.sysTextSub())
                  .width('100%')
                  .padding({ top: Space.m, bottom: Space.m })
              }
              ForEach(this.rules, (r: ThemeRule, idx: number) => {
                Row() {
                  Text(r.match)
                    .fontSize(FontSize.subtitleM)
                    .fontColor(Theme.sysTextMain())
                    .layoutWeight(1)
                  Column()
                    .width(Size.iconS)
                    .height(Size.iconS)
                    .borderRadius(Radius.s)
                    .backgroundColor(r.color)
                    .border({ width: 1, color: '#00000022' })
                  Text('删除')
                    .fontSize(FontSize.subtitleS)
                    .fontWeight(Weight.medium)
                    .fontColor('#C0392B')
                    .textAlign(TextAlign.Center)
                    .padding({ left: Space.m, right: Space.m })
                    .constraintSize({ minHeight: Size.touchTarget })
                    .onClick(() => {
                      this.removeRule(idx);
                    })
                }
                .width('100%')
                .constraintSize({ minHeight: Size.touchTarget })
                .alignItems(VerticalAlign.Center)
                .onClick(() => {
                  this.openPanel('rule', idx);
                })
              }, (r: ThemeRule) => `rule-${r.match}-${r.color}-${this.rev}`)

              Row() {
                Text('＋ 添加地区字色规则')
                  .fontSize(FontSize.subtitleS)
                  .fontWeight(Weight.medium)
                  .fontColor(Theme.cfg.theme)
                  .textAlign(TextAlign.Center)
                  .padding({ top: Space.m, bottom: Space.l })
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .onClick(() => {
                this.openPanel('rule', -1);
              })
            }
            .width('100%')
            .padding({ left: Space.l, right: Space.l })
            .borderRadius(Radius.l)
            .backgroundColor(Theme.sysCard())

            Text('改动即时保存；课表页返回后即刻生效。')
              .fontSize(FontSize.bodyS)
              .fontColor(Theme.sysTextSub())
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: Space.xl, bottom: Space.xxl })
          }
          .width('100%')
          .padding({ left: Layout.screenMargin(), right: Layout.screenMargin() })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.sysPage())

      if (this.showPanel) {
        this.colorPanel()
      }
    }.transition(Motion.pageEnter())
    .width('100%')
    .height('100%')
  }
}
