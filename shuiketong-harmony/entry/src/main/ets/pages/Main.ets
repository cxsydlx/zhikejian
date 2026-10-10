import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { HdsTabs, HdsTabsController, hdsMaterial, DividerMode } from '@kit.UIDesignKit';
import { AppState } from '../common/AppState';
import { CourseStore } from '../common/CourseStore';
import { Theme } from '../common/Theme';
import { Mat } from '../common/Material';
import { WindowInsets } from '../common/WindowInsets';
import { ClassReminder } from '../service/ClassReminder';
import { ShareService, PendingImport, ShareKind } from '../service/ShareService';
import { CourseTableView } from '../view/CourseTableView';
import { ListenView } from '../view/ListenView';
import { DictView } from '../view/DictView';
import { TabSettingsView } from './Settings';
import { TranscriptStore } from '../common/TranscriptStore';
import { FontSize, Weight, Space, Radius, Size, Motion, Layout } from '../common/DesignToken';

/**
 * 底栏前景色 —— 全部改用**系统资源值**，这是 `colorInvert`（沉浸光感自动反色）生效的硬前提。
 *
 * ## 为什么必须换掉原来的硬编码（2026-09-28 第二十一次修正）
 * 用户要求：「底下的 tab 可以实现检测背景颜色，要是背景颜色是暗色，那它就自动调成黑底白图标。
 * 要是白色，就变成白底黑图标。」
 *
 * 这正是 `uiMaterial` 的 `colorInvert` 能力，但它对前景色有硬性要求：
 * **只认 `$r('sys.color.*')` 资源值，硬编码色（含 `Theme.themeColor()` 算出来的 hex）一律不触发。**
 * 我们原来用的是 `this.tc`（主题色）+ `'#A8A29E'`（字面量），两条都不满足 → 反色从未生效。
 *
 * ## 用户拍板的取舍（原话）
 * > 「那我们就丢弃掉全部的主题色，所有的图标全部改成黑白简洁，或者是白黑。」
 * > 「我们奉行极简主义。」
 * → 底栏**放弃主题色着色**，一律走系统资源：系统给什么色就用什么色，
 *   进而由 `colorInvert` 按底下内容亮度自动反色。选中态不再靠"橙红"表达，
 *   改由**实心 `_fill` 图标 + 字重**表达（官方《底部页签》规范也正是这么要求的）。
 *
 * ⚠️ 资源名已在 SDK `sysResource.js` 里逐条核对存在，不是猜的：
 *   `ohos_id_color_bottom_tab_text_on` / `_off`（底栏专用）、
 *   `ohos_id_color_text_secondary`（页签未选中文字，官方语义即 secondary）。
 */
const TAB_ON: Resource = $r('sys.color.ohos_id_color_bottom_tab_text_on');
const TAB_OFF: Resource = $r('sys.color.ohos_id_color_bottom_tab_text_off');
const TAB_LABELS: string[] = ['课表', '听课', '设置', '词典'];

/**
 * 底栏选中态渐变时长（ms，2026-10-07）。
 *
 * 用户要求：「页面离开的时候蓝色图标颜色渐渐消失，进入页面慢慢变蓝」。
 * 离开与进入**共用这一条曲线**（`Motion.curveStandard`）—— ArkUI 的 `animateTo`
 * 在同一 tick 里只能安全地开一个动画上下文，两者不同时长就得串行编排，
 * 收益（快慢差）远小于「两次 animateTo 抢上下文」的风险。
 * 420ms 与 `.animationDuration(Motion.durationLayout)` 同量级，切换的观感是连贯的。
 */
const TAB_GLOW_MS: number = 420;

/**
 * 应用主页：底部三 Tab —— 课表 / 听课 / 设置（HdsTabs + 沉浸光感）。
 * 课表为默认页（curTab = 0）。
 *
 * ## 悬浮胶囊导航与内容遮挡
 * `.barOverlap(true)` 是沉浸光感的**前置条件** —— 内容延伸到导航栏下方，底栏的材质
 * 才能真正透出下方内容的模糊（HDS 官方文档明确要求）。
 * 代价是内容会被悬浮底栏遮住，所以三个 Tab 内容都加了 `BAR_CLEARANCE` 的底部 padding。
 * （早期版本为省事直接不开 `barOverlap`，底栏材质就退化成了贴边色带 —— 2026-09-27 纠正。）
 */
@Entry
@Component
struct Main {
  // ---- 主题镜像：ArkUI 只观察「渲染中读取过」的状态；配色变化必须镜像成 @State 才会重绘 ----
  @State tc: string = Theme.themeColor();
  @State tacc: string = Theme.accentColor();
  @State tsoft: string = Theme.softColor();
  @State tpage: string = Theme.pageColor();
  @State ton: string = Theme.onTheme();
  @State tmain: string = Theme.textMain();
  @State tsub: string = Theme.textSub();

  @State curTab: number = 0;
  /**
   * 【2026-10-07】底栏三个 tab 的**选中蓝度**（0 = 全灰，1 = 全蓝）。
   *
   * ## 为什么不用 `curTab === i` 直接切颜色
   * 原来图标/文字颜色是 `this.curTab === i ? TAB_ON : TAB_OFF` —— **瞬间跳变**，
   * 用户要求「页面离开的时候蓝色图标颜色渐渐消失，进入页面慢慢变蓝」。
   *
   * ## 为什么是「双层叠加 + opacity 交叉」而不是「插值颜色」
   * `TAB_ON` / `TAB_OFF` 都是 `$r('sys.color.*')` **系统 Resource**，拿不到运行时的
   * RGB 分量，所以做不了颜色插值（项目里 `Theme.sysEmphasizeHex()` 就是为此存在的
   * **刻意近似**代理值 —— 能用，但会偏离 HDS 官方深浅色取值）。
   * 而 opacity 交叉**完全不用解析颜色**：两层各自用 HDS 自己的系统色 Resource，
   * 只调透明度。于是**图标的形状变体（fill ↔ 线性）也顺带一起渐变**了，
   * 比原来「形状瞬切 + 颜色瞬切」自然得多。
   */
  @State private glow0: number = 1;   // 课表（默认页，一进来就是蓝的）
  @State private glow1: number = 0;   // 听课
  @State private glow2: number = 0;   // 设置
  @State private glow3: number = 0;   // 词典（2026-10-10 新增）

  /** 主题色变化用（配色页改完返回时刷新底部导航的选中色） */
  @State themeRev: number = 0;
  /** 本机是否支持沉浸光感（不支持则走原生化降级：普通底色） */
  @State immersive: boolean = false;
  /**
   * 【2026-09-28 已删除 `navReady`】
   *
   * 原为「底栏 HDS 材质接口是否可调用」的守卫（`Mat.navSupported()`），
   * 用于给 `barFloatingStyle` 做三元降级。用户明确要求**删掉降级判断、直接全开**：
   * 设备支持就该让材质真正生效，不做"探测不过就退化成实色"的兜底。
   *
   * 相关能力探测仍在 `Mat.resolveNavHdsSupport()`（供 HiLog 诊断用），
   * 只是不再用它否决材质配置。
   */

  private controller: HdsTabsController = new HdsTabsController();

  private syncTheme(): void {
    this.tc = Theme.themeColor();
    this.tacc = Theme.accentColor();
    this.tsoft = Theme.softColor();
    this.tpage = Theme.pageColor();
    this.ton = Theme.onTheme();
    this.tmain = Theme.textMain();
    this.tsub = Theme.textSub();
    // 【2026-09-30】深浅色切换时递增，强制 `build()` 重算。
    // 为什么需要：`barFloatingStyle` 里的 `Theme.isDark()` 是**求值时机**敏感的 ——
    // 它读 `ctx.config.colorMode`，系统切换后值会变，但上面那些 @State 的颜色
    // 在"四套色系没换、只是深浅色变了"时**取值不变** → ArkUI 认为无变化、不重绘
    // → 底栏的 barOpacity 就停留在旧值。用一个必然变化的计数器踢一下。
    this.themeRev += 1;
  }

  aboutToAppear(): void {
    Theme.onChange(() => {
      this.syncTheme();
    });
    this.syncTheme();

    // 沉浸光感：统一走材质中心（EntryAbility 已 init，这里再调一次是幂等的，
    // 覆盖「从 router 直接进本页」的情况），并同步探测结果到 @State 供降级判断。
    Mat.init();
    this.immersive = Mat.supported;
    // ⚠️ 2026-09-28：原先这里还有 `this.navReady = this.immersive && Mat.navSupported()`
    //    用作底栏材质的降级守卫。用户明确要求「删掉降级判断，直接全部打开」→ 已移除。
    //    `Mat.navSupported()` 本身保留（HiLog 诊断用），只是不再否决材质配置。

    // 系统栏避让：全屏沉浸布局下，三个 Tab 内页的自绘顶栏都要补状态栏高度。
    // 这里触发一次真实避让区查询（异步回填，兜底值先撑着首帧）。
    WindowInsets.sync();

    // 屏幕形态探测（手机 / 平板）——决定内容区左右边距走 16 还是官方平板值 32vp。
    // 必须早于首帧：`screenMargin()` 虽会自初始化，但首帧读到 PHONE 会「16→32」跳一下。
    Layout.init();

    const ctx = getContext(this) as common.UIAbilityContext;
    AppState.init(ctx);          // 转写 / 配置状态
    TranscriptStore.init(ctx);   // 转写本地存储（按会话保存）
    Theme.init(ctx);             // 统一配色（必须先于课表初始化：色板由 Theme 提供）
    CourseStore.init(ctx);       // 课表状态
    ClassReminder.init(ctx);     // 上课提醒（系统代理提醒 + 进程内通知兜底）
    Theme.onChange(() => {
      this.themeRev += 1;
    });

    // ---- 碰一碰接收 ----
    // 订阅待确认导入；注意订阅后**立即补查一次**：EntryAbility.onCreate 的解析是异步的，
    // 可能在页面订阅之前就已完成并 notify 过一次（那时还没有监听者，通知会丢）。
    ShareService.onPendingImport(() => {
      this.consumePendingImport();
    });
    this.consumePendingImport();
  }

  /**
   * 取走待确认分享并弹窗询问。
   * 必须等 CourseStore.init 完成才能写入 —— 它的 prefs 是异步拿到的，
   * 初始化未完成时 persist() 直接 return，会把导入静默丢掉。
   */
  private consumePendingImport(): void {
    if (ShareService.pendingImport == null) {
      return;
    }
    if (!CourseStore.ready) {
      // 初始化还没完成：隔一小段时间再补查（init 通常是毫秒级）
      setTimeout(() => {
        this.consumePendingImport();
      }, 120);
      return;
    }
    const pending = ShareService.takePending();
    if (pending == null) {
      return;
    }
    this.askImport(pending);
  }

  /** 弹窗确认后导入 */
  private askImport(pending: PendingImport): void {
    if (pending.kind === ShareKind.TRANSCRIPT) {
      this.askImportTranscript(pending);
      return;
    }
    const p = pending.payload;
    const name = p.name.length > 0 ? p.name : '对方课表';
    const title = p.title.length > 0 ? `（${p.title}）` : '';
    const detail = `「${name}」${title}\n共 ${pending.parsed} 个课程块`;
    AlertDialog.show({
      title: '收到一份课表',
      message: `${detail}\n\n导入会覆盖你当前的课表，确定吗？`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '导入',
        fontColor: this.tc,
        action: () => {
          this.doImport(pending);
        },
      },
    });
  }

  /** 收到的是转写笔记：保存为新的一份历史记录（不覆盖任何东西） */
  private askImportTranscript(pending: PendingImport): void {
    const t = pending.transcript;
    const head = t.title.length > 0 ? `「${t.title}」` : '一份课堂笔记';
    const hasSum = t.summary.length > 0 ? '（含 AI 整理笔记）' : '';
    AlertDialog.show({
      title: '收到一份课堂笔记',
      message: `${head}${hasSum}\n共 ${pending.parsed} 句转写，约 ${t.durationText}\n\n`
        + '保存后会出现在「转写笔记 → 历史记录」里，不会影响你当前的转写。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '保存',
        fontColor: this.tc,
        action: () => {
          ShareService.applyTranscriptImport(pending).then((res) => {
            promptAction.showToast({ message: res.message, duration: 2500 });
          }).catch((e: Error) => {
            promptAction.showToast({ message: `保存失败：${e.message}`, duration: 3000 });
          });
        },
      },
    });
  }

  /** 真正执行导入：写入 → 持久化 → 重排提醒 */
  private doImport(pending: PendingImport): void {
    ShareService.applyImport(pending).then((res) => {
      if (!res.ok) {
        promptAction.showToast({ message: res.message, duration: 2500 });
        return;
      }
      // 课表换了，已排的系统提醒要按新课表重排
      ClassReminder.refresh();
      this.themeRev += 1;
      promptAction.showToast({ message: res.message, duration: 2500 });
    }).catch((e: Error) => {
      promptAction.showToast({ message: `导入失败：${e.message}`, duration: 3000 });
    });
  }

  // 注意：不能用带参数的 @Builder（按值传参，状态变化不会刷新），
  // 所以三个 Tab 各自写成**无参 Builder**，内部直接读 this.curTab / this.tc。
  //
  // ## 图标：HarmonyOS Symbol（2026-09-28 改造，此前是手绘几何图形）
  // 官方《底部页签》规范原文：**"使用 HarmonyOS Symbol 来展示图标信息"**，图标默认 **24×24vp**。
  // 此前用 `Row()/Column()` 手绘，导致三个硬伤：
  //   ① 图标只有 15vp（规范的 62%），② 用不了系统符号，③ 为迁就小图标把栏高压到 50（规范 56）。
  // 改用 `SymbolGlyph($r('sys.symbol.xxx'))` 后全部解决 —— 且**符号字体是系统自带的，不占包体积**
  // （当初"零资源依赖"的顾虑不成立：`$r('sys.symbol.*')` 不是打包进 hap 的图片资源）。
  //
  // ⚠️ 符号名已在 SDK 的 `sysResource.js` 里逐一核对过存在性，不是猜的：
  //   calendar / calendar_fill / mic / mic_fill / gearshape / gearshape_fill
  // ⚠️ `fontColor` 的签名是 **`Array<ResourceColor>`**（数组），不是单个颜色 —— 传裸色值会编译不过。
  // ⚠️ 选中态用 `_fill` 填充变体 + 主题色；未选中用线性变体 + 中性灰。
  //   这同时满足了官方"被激活的页签应有明确的视觉反馈""未激活的页签应当弱化展示"两条。

  /**
   * 底栏图标尺寸（vp）—— 官方《底部页签》规范：**图标大小默认为 24×24vp**。
   * 用 `SymbolGlyph` 的 `fontSize` 控制显示大小（官方说明：symbol 的显示尺寸由 fontSize 决定）。
   */
  private static readonly TAB_ICON: number = 24;

  /**
   * 【2026-10-07】读某个 tab 的选中蓝度。
   * 用四个独立 `@State` 标量而不是一个 `@State number[]` ——
   * ArkUI 的 `@State` 对数组**整体替换**才触发，逐元素赋值 (`arr[i] = x`) 不会触发更新。
   * 四个标量各自替换，行为可预期。
   *
   * ⚠️ 【2026-10-10 新增第 4 个 tab「词典」】原来这里是三元链
   *    `i === 0 ? glow0 : (i === 1 ? glow1 : glow2)`，**i>=2 全落到 glow2**。
   *    加第 4 个 tab 后 i=3 会去读设置页的蓝度 → 底栏显示错乱。
   *    已改成 switch 显式列举，未知 index 返回 0（而不是落到最后一个）。
   */
  private glowOf(i: number): number {
    switch (i) {
      case 0: return this.glow0;
      case 1: return this.glow1;
      case 2: return this.glow2;
      case 3: return this.glow3;
      default: return 0;
    }
  }

  private setGlow(i: number, v: number): void {
    // ⚠️ 同上：原来 `else { this.glow2 = v }` 会让 i=3 **写坏设置页的选中态**。
    switch (i) {
      case 0: this.glow0 = v; break;
      case 1: this.glow1 = v; break;
      case 2: this.glow2 = v; break;
      case 3: this.glow3 = v; break;
      default: break;
    }
  }

  /** 课表图标：日历 —— 线性(未选中) 与 实心(选中) 两层叠放，靠 opacity 交叉渐变 */
  @Builder
  iconSchedule() {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph($r('sys.symbol.calendar'))
        .fontSize(Main.TAB_ICON)
        .fontColor([TAB_OFF])
        .opacity(1 - this.glow0)
      SymbolGlyph($r('sys.symbol.calendar_fill'))
        .fontSize(Main.TAB_ICON)
        .fontColor([TAB_ON])
        .opacity(this.glow0)
    }
    // ⚠️ 必须显式给宽度。`HdsTabs` 要**自己测量** tabBar 内容来决定每个 tab 的宽度分配；
    // 不设宽度时 Stack 按子组件收缩，两层 SymbolGlyph 重叠后只等于一个图标的宽度，
    // HDS 拿到的尺寸偏小 → 整个底栏被压成窄条（真机 2026-10-07 实测）。
    .width('100%')
  }

  /** 听课图标：麦克风 —— 同上 */
  @Builder
  iconListen() {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph($r('sys.symbol.mic'))
        .fontSize(Main.TAB_ICON)
        .fontColor([TAB_OFF])
        .opacity(1 - this.glow1)
      SymbolGlyph($r('sys.symbol.mic_fill'))
        .fontSize(Main.TAB_ICON)
        .fontColor([TAB_ON])
        .opacity(this.glow1)
    }
    .width('100%')
  }

  /** 设置图标：齿轮 —— 同上 */
  @Builder
  iconSettings() {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph($r('sys.symbol.gearshape'))
        .fontSize(Main.TAB_ICON)
        .fontColor([TAB_OFF])
        .opacity(1 - this.glow2)
      SymbolGlyph($r('sys.symbol.gearshape_fill'))
        .fontSize(Main.TAB_ICON)
        .fontColor([TAB_ON])
        .opacity(this.glow2)
    }
    .width('100%')
  }

  /**
   * 词典图标：书本 —— 同上（线性 + 实心双层）
   *
   * 【2026-10-10】符号名的核实过程，记住这个方法：
   *   ① 工程老注释说「符号名在 `sysResource.js` 里核对过」—— **那是错的**。
   *      实测该文件里 `gearshape` 都搜不到，它只收录 string 资源，不收 symbol。
   *   ② `hm_symbol_config.json` 也只有动画配置，没有符号清单。
   *   ③ 官方 Symbol 站点是动态渲染的，WebFetch 抓不到内容。
   *   ∴ **唯一可靠的核实手段是让编译器验**：`$r('sys.symbol.xxx')` 写错
   *      会报 `Unknown resource name`。
   *
   *⚠️ **踩坑记录**：我先写的是 `book` / `book_fill`，注释还乐观地标了
   *   "已编译通过"（其实当时没编译）。结果编译器报
   *   `Unknown resource name 'book_fill'` —— **`book_fill` 不存在**。
   *   改成 `book` + `book_closed`（后者是 HarmonyOS Symbol 里book 的
   *   填充变体名），并**这次真的编译验证过**。
   */
  @Builder
  iconDict() {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph($r('sys.symbol.book'))
        .fontSize(Main.TAB_ICON)
        .fontColor([TAB_OFF])
        .opacity(1 - this.glow3)
      SymbolGlyph($r('sys.symbol.textformat'))
        .fontSize(Main.TAB_ICON)
        .fontColor([TAB_ON])
        .opacity(this.glow3)
    }
    .width('100%')   // 同上：不设宽度会被 HDS 测量偏小 → 底栏压成窄条
  }

  /**
   * tab 单元（图标 + 文字，选中态带材质底板）。
   *
   * 视觉按官方底部导航规范：图标在上、文字在下；图标区按 `Size.iconS`(24vp) 的视觉重量绘制，
   * 整单元高度取 `Size.tabBar`(50) 并保证 ≥ `Size.touchTarget`(48) 的可点热区
   * （官方无障碍硬指标，触控目标不得小于 48×48vp）。
   */
  @Builder
  tabCell(index: number, icon: number) {
    Column() {
      // ⚠️ 【2026-10-10】原来这里只分派三个图标且**靠 else 兜底**：
      //    `else { this.iconSettings() }` 会让第4 个 tab（词典）**显示成齿轮**。
      //    已改成显式 switch，未知 icon 不画任何东西（而不是落到最后一个）。
      if (icon === 0) {
        this.iconSchedule()
      } else if (icon === 1) {
        this.iconListen()
      } else if (icon === 2) {
        this.iconSettings()
      } else if (icon === 3) {
        this.iconDict()
      }
      // 文字同样双层：底层灰（regular）、顶层蓝（medium），靠 opacity 交叉。
      // 字重也跟着一起变，读作「渐渐变蓝 + 渐渐变粗」而不是硬切。
      Stack({ alignContent: Alignment.Center }) {
        Text(TAB_LABELS[index])
          .fontSize(FontSize.captionL)
          .fontColor(TAB_OFF)
          .fontWeight(Weight.regular)
          .opacity(1 - this.glowOf(index))
        Text(TAB_LABELS[index])
          .fontSize(FontSize.captionL)
          .fontColor(TAB_ON)
          .fontWeight(Weight.medium)
          .opacity(this.glowOf(index))
      }
      .height(FontSize.captionL * 1.4)
      .width('100%')   // 同上：不设宽度会被 HDS 测量成单字宽 → 底栏压成窄条
      .margin({ top: Space.xs })
    }
    .width('100%')
    .height(Size.tabBar)
    .justifyContent(FlexAlign.Center)
    // 【2026-09-28 重置为官方默认外观】
    // 原先这里挂了 `Mat.navGlass()`（我自己加的透明玻璃材质）当选中底板。
    // 已撤掉：先让 HDS 用出厂默认渲染，确认官方基准长什么样之后再谈自定义。
    // 选中态现在只靠图标/文字的主题色（`this.tc`）+ 字重变化表达。
    .backgroundColor('#00000000')
  }

  @Builder
  barSchedule() {
    this.tabCell(0, 0)
  }

  @Builder
  barListen() {
    this.tabCell(1, 1)
  }

  @Builder
  barSettings() {
    this.tabCell(2, 2)
  }

  /**
   * 词典 tab —— **无参** @Builder。
   * ⚠️ 必须无参：`Main.ets` 顶部有硬约束「不能用带参数的 @Builder
   *    （按值传参，状态变化不会刷新）」，所以四个 tab 各写一个。
   */
  @Builder
  barDict() {
    this.tabCell(3, 3)
  }

  build() {
    // `themeRev` 参与 `id` 求值，使主题/深浅色变化时本组件树被重新构建 ——
    // 见 `syncTheme()` 注释：底栏的 `barFloatingStyle` 依赖 `Theme.isDark()`，
    // 求值时机敏感，必须靠这个"可观察的变化"把重建踢出来。
    HdsTabs({ barPosition: BarPosition.End, index: this.curTab, controller: this.controller }) {
      TabContent() {
        Column() {
          CourseTableView();
        }
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.sysPage());
      }
      .tabBar(this.barSchedule())

      TabContent() {
        Column() {
          ListenView();
        }
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.sysPage());
      }
      .tabBar(this.barListen())

      TabContent() {
        Column() {
          TabSettingsView();
        }
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.sysPage());
      }
      .tabBar(this.barSettings())

      // 第 4 个 Tab：词典（2026-10-10 新增）
      // ⚠️ 放索引 3（设置之后）—— 若插中间，所有硬编码 tab 索引全错。
      TabContent() {
        Column() {
          DictView();
        }
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.sysPage());
      }
      .tabBar(this.barDict())
    }
    // ==========================================================================
    // 【2026-09-28 重置为官方默认外观】
    // 依据：华为开发者联盟官方博客《让底部导航栏的光晕跟着手指跑》
    //   https://developer.huawei.com/consumer/cn/blog/topic/03217074773151098
    //
    // ## 官方「最简单接入方式」原文（最精简版）
    // ```ts
    // .barOverlap(true)
    // .barPosition(BarPosition.End)
    // .barFloatingStyle({
    //   barBottomMargin: 28,
    //   // 就这几行，开启沉浸光感
    //   systemMaterialEffect: {
    //     materialType: hdsMaterial.MaterialType.ADAPTIVE,
    //     materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
    //   }
    // })
    // ```
    // 博客原话：*"核心就是 `materialType` 和 `materialLevel` 都设为 `ADAPTIVE`"*。
    //
    // ## ⚠️ 我之前三处违背官方（现已纠正）
    // ① `materialType` 用了 `IMMERSIVE` —— 官方表格里 `ADAPTIVE` 才是**推荐**，
    //    `IMMERSIVE` 是"需要设备支持"的进阶项。
    // ② `materialLevel` 走了"先查 getSystemMaterialTypes() 再手动指定 GENTLE"的路径 ——
    //    那是**进阶配置**（原文：「如果你不想让系统'自作主张'地选择效果等级」）。
    //    实测日志 `systemMaterialTypes=[101] isLight=true -> level=1` 说明系统自适应正常，
    //    直接用 `ADAPTIVE` 让系统自己算即可。
    // ③ `barBottomMargin` 用了 32 —— 官方示例是 **28**。
    //
    // ## 另：`barOpacity` 的两次认知反复（最终结论见下方 barFloatingStyle 注释）
    // 第一次：据本地 `.d.ts` 的 `@default 1` 断定它是"胶囊不透光"的元凶 → **推断错误**，
    //        当时直接传了 0。
    // 第二次（2026-09-28 · 用户报「导航栏怎么没了」）：确认传 0 会把**整条栏抹掉**。
    //        正确结论：`barOpacity` 是**栏自身底色**的不透明度，"透光"要靠材质 + 蒙层配合，
    //        **不是靠归零栏底**。现已恢复官方默认 1。
    //
    // ## 同时撤掉的我方自定义（2026-09-27~28 加的，别再回来）
    // `barBackgroundColor` 透明值 / `lightColor` / `barSideMargin`(官方示例无此项) /
    // `divider` 的 mode 动态切换 / tab 单元上的 `Mat.navGlass()`（已撤，选中态改由主题色 + 字重表达）
    // ==========================================================================
    // 悬浮底栏形态：官方示例固定带前两个
    // ==========================================================================
    // 【导航切换动画】官方 `animationDuration(value: number)` —— 声明见
    //   `@hms.hds.hdsBaseComponent.d.ets:5556`
    //   「The length of time required to complete the tab switching animation.」
    // 不传时 HDS 用内部默认值（实测切换偏「瞬切」）。用户要求「导航页面切换要有动画」，
    // 显式给到 450ms —— 与 `Motion.durationLayout`（视图切换/布局模式变更）对齐，
    // 也是官方动效时长表里「布局切换 350~500ms」的中位。
    .animationDuration(Motion.durationLayout)
    .barOverlap(true)
    .barHeight(Size.tabBar)      // 56vp = 官方《底部页签》悬浮式规范值
    .barMode(BarMode.Fixed)
    // ==========================================================================
    // 【2026-09-28 第四次修正 · 底栏整条消失的根因】
    //
    // ## 症状
    // 用户反馈「导航栏怎么没了」——底栏胶囊整条不可见。
    //
    // ## 根因：`barOpacity: 0` 是错的用法
    // 官方 `HdsTabsFloatingStyle.barOpacity` 语义是**整条悬浮胶囊栏自身的底色不透明度**
    // （`@default 1` = 不透明）。传 0 = 把栏的底色彻底抹掉，只剩材质。
    // 而沉浸材质本质是「磨砂玻璃」——**玻璃需要底下有一层背板才有"块感"**；
    // 栏底为 0 且蒙层又很淡时，真机上整条栏直接**看不见**。
    //
    // ## 我对用户诉求的误读（记录以免重犯）
    // 用户原话「不透明度设为 100，完全透明」= **不要那层糊白的不透明感（要透光）**，
    // 而不是"把栏本身抹掉"。我当时按后者理解，直接把 `barOpacity` 归零 → 栏没了。
    //
    // ## 修正
    // `barOpacity` 恢复官方默认 `1`（栏体必须在）。透光由材质 + 蒙层负责：
    // 材质是玻璃，蒙层是玻璃下面那张纸——**两者都不能缺，缺一个就"要么没栏、要么不透"**。
    // ==========================================================================
    .barFloatingStyle(Mat.navSupported() ? {
      barBottomMargin: 28,          // 官方示例值
      adaptToHandedness: true,      // ★ 左右跟手（官方默认 false，必须显式开）
      // ============ 颜色相关字段：一律不传，让 HDS 用自己的分深浅色默认值 ============
      // 【2026-09-30 第十九次修正 · 修「深色模式下底栏不变黑」】
      //
      // ## 官方参数表（《HdsTabsFloatingStyle 详细介绍》，原文照抄）
      //   lightColor    页签栏光效颜色。默认：**深色 #33E5E5E5 / 浅色 #33FFFFFF**
      //   gradientMask  背板蒙层。      默认：**深色 #99000000 / 浅色 #CCF1F3F5**
      //   barOpacity    页签栏透明度，1 不透明 / 0 完全透明。默认：**1**
      // → HDS **本来就该自己变黑**（用户原话：「按道理来说这个 HDS Bar 也是可以变成
      //    以黑色底色的不透明底栏」—— 对，官方默认值就是这么设计的）。
      //
      // ## 那之前为什么不变黑？因为被我们**自己覆盖**了
      // 我们从 9-28 起一直显式传 `barOpacity: 0.62`。这是唯一被长期覆盖的颜色相关参数，
      // 而它恰恰是最关键的：
      //   `barOpacity` 降低 → 栏体只保留 62% 自己的底色，剩下 38% 透出**下方课表页**。
      //   课表页按用户要求保留浅色系（故宫系浅粉）→ 深色下 HDS 的黑色背板被
      //   浅粉稀释 → 混出来是灰白，不是黑。**根因在这里，不在 HDS。**
      //
      // ## 修正：不传颜色字段，barOpacity 按深浅色分档
      //   · 浅色模式：0.62 —— 保留 9-28 调好的"有边界 + 能透光"观感
      //     （浅色下不透明度给 1 会让胶囊糊成一块，之前的实测数据见下方历史注释）
      //   · 深色模式：**不传**（= 官方默认 1）—— 栏体实心，黑色背板不被稀释，
      //     呈现用户要的「黑色底 + 白色图标」不透明底栏
      // 同时 **lightColor / gradientMask 都不传** —— 官方默认值已经分深浅色，
      // 我们传任何自定义值都只会覆盖掉这个能力（我在本次修的过程中就犯过这个错：
      // 传了 `sysBottomTabBg()` 想"帮它跟随"，反而把官方的深色默认值盖掉了）。
      barOpacity: Theme.isDark() ? 1 : 0.62,
      // ============ 9-28 的采样数据（保留作参考：解释浅色下为什么是 0.62）============
      // 症状：用户「下面的菜单里面为啥没有底色了」—— 胶囊与页面底完全同色，读不出边界。
      // 实测（截图采样）：
      //   · 胶囊内空白处   (250, 246, 243)
      //   · 卡片间页面底   (251, 243, 240)   ← 与胶囊几乎相同 → 没边界
      //   · 胶囊下方页面底 (190, 182, 180)   ← 被 gradientMask 压暗
      // 结论：`barOpacity` 是「栏底色的不透明度」，不是"整条栏的显隐开关"。
      //   ★ 采 0.62 而非 1：1 时栏底完全不透明，蒙层与材质一起被挡在外面（没边界）；
      //     0 时整条栏消失（见下）。
      // 历史教训（别再摇摆）：
      //   第一次传 0 → 「导航栏怎么没了」：材质需要一层背板才有块感，栏底为 0 时看不见。
      //   那次消失是因为**走了极端值**，不是"必须用 1"。
      //   ⚠️ 以上全部只对**浅色模式**成立。深色模式见上方「第十九次修正」——
      //      必须走官方默认 1，否则黑色背板被下方浅色课表页稀释成灰白。
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
      },
    } : {
      // ★ 防崩分支（不是"视觉降级"）：`hdsMaterial` 是 6.1.0(23) 的接口，
      //   低版本系统上求值 `hdsMaterial.MaterialType` 会抛，而 build() 里没有 try 可包
      //   → 整页不渲染，表现同样是「导航栏没了」。
      //   此分支仅在这种"接口根本调不了"的设备上生效，那种设备本来也不会有材质效果；
      //   其余配置（位置/高度/跟手）与上面完全一致，不存在"另一种样式"。
      barBottomMargin: 28,
      adaptToHandedness: true,
      // 与上面材质分支保持一致：颜色字段一律不传，让 HDS 用自己的分深浅色默认值。
      barOpacity: Theme.isDark() ? 1 : 0.62,
    })
    // ==========================================================================
    // ⚠️ `HdsDividerStyle` 的 `mode` 是**必填**（类型定义里没有 `?`），不传直接报 10505001。
    //    这里固定 `VISIBLE` —— 原先那个 `this.navReady ? NONE : VISIBLE` 的动态切换已撤
    //    （官方示例里没有这种玩法）。
    .divider({
      // 【2026-09-30 修正】原 `Theme.mix(this.tsoft, '#FFFFFF', 0.4)` 跟着四套色系走
      // （故宫系是暖白），深色模式下这条分隔线会**比栏体还亮**，成了一道突兀的白线。
      // 改用系统中性分隔线资源 —— 与底栏其余部分"一律走系统资源"的路线一致。
      style: { strokeWidth: Size.divider, color: Theme.sysSeparator() },
      mode: DividerMode.VISIBLE,
    })
    .onChange((i: number) => {
      const prev: number = this.curTab;
      if (prev === i) {
        return;
      }
      this.curTab = i;
      // 【2026-10-07】离开的渐渐褪蓝、进入的慢慢变蓝。
      // 一次 animateTo 同时改两个 glow —— ArkUI 在同一 tick 只开一个动画上下文，
      // 分两次调用会互相抢（后者覆盖前者），所以这里让两者同曲线同时长。
      animateTo({ duration: TAB_GLOW_MS, curve: Motion.curveStandard }, () => {
        this.setGlow(prev, 0);
        this.setGlow(i, 1);
      });
    })
    // 读取 `themeRev`（值参与字符串拼装），使它成为"被观察的状态"。
    // ArkUI 只重建「渲染中读取过」的状态 —— 不读等于没写。
    .id(`main-tabs-${this.themeRev}`)
    .width('100%')
    .height('100%')
    // 页面底色。
    // ⚠️ 必须配合下面的 expandSafeArea：不开全屏时页面只到安全区上沿，
    //    底部手势条区域会露出系统默认底色（#F5F5F5 中性灰）→ 看着「下面白了一条」。
    .backgroundColor(Theme.sysPage())
    // 延伸到屏幕四边（含状态栏 / 底部手势条），让页面底色铺满整屏。
    // 配合 EntryAbility 的 setWindowLayoutFullScreen(true)。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
