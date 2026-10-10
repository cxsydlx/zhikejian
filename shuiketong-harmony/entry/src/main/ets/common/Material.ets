import { uiMaterial } from '@kit.ArkUI';
import { hdsMaterial } from '@kit.UIDesignKit';
import hilog from '@ohos.hilog';
import { Theme } from './Theme';
import { Radius } from './DesignToken';

/**
 * 沉浸光感（ImmersiveMaterial）材质中心。
 *
 * ## 为什么要有这个文件
 * 材质配置集中在这里。按华为的生效范围，页面内的 Button、Toggle、Select 和弹窗
 * 可使用沉浸光感；普通内容容器只有位于 Navigation 标题栏或底部 TabBar 时才会生效。
 * 内容卡片继续保留实色背景，不能把其 `.systemMaterial` 调用当作已生效的视觉能力。
 *
 * ## 用法（关键：保留 backgroundColor 当降级底）
 * ```
 * Column() { ... }
 *   .borderRadius(Radius.l)          // 圆角走 DesignToken，不要写字面量
 *   .backgroundColor(this.tsoft)      // 降级用：材质不生效时显示它
 *   .systemMaterial(Mat.card())       // 支持材质时由材质接管（官方语义：材质优先于背景色）
 * ```
 * **不要删掉 `.backgroundColor(...)`** —— 不支持材质或组件位置不在生效范围时，
 * 背景色仍要保证内容可读。
 *
 * ## 五档材质的层级语义（按"离用户多近"划分，不是按颜色）
 * | 访问器 | 视觉厚度 | 可交互 | 光效 | 反色 | 典型用途 |
 * |---|---|---|---|---|---|
 * | `card()`  | REGULAR | ✗ | ✗ | ✓ | 大卡片、内容分组容器 |
 * | `tile()`  | THIN    | ✓ | ✓ | ✓ | 卡片内嵌套块、列表项、胶囊按钮 |
 * | `bar()`   | THIN    | ✓ | ✓ | ✓ | 顶栏、悬浮操作条（主题色着色） |
 * | `sheet()` | THICK   | ✗ | ✗ | ✗ | 弹窗、半模态（要压住底下内容） |
 * | `button()`| REGULAR | ✓ | ✓ | ✗ | 主操作按钮（主题色着色） |
 *
 * ## 降级
 * `init()` 先探测 `uiMaterial.isImmersiveMaterialSupported()`；
 * 不支持 → 所有访问器返回 `undefined`，界面与改造前**完全一致**，零回归。
 *
 * ## 主题联动
 * 顶栏 / 主按钮的材质带主题色着色，换色系后要 `rebuild()`。已在 `init()` 里订阅 `Theme.onChange`。
 */
export class Mat {

  /** 本机是否支持沉浸光感材质（探测结果，只探一次） */
  static supported: boolean = false;

  /**
   * HDS 底栏材质能力是否可用（`hdsMaterial` 接口本身可调用）。
   *
   * ## 为什么不能只看 `Mat.supported`
   * `Mat.supported` 探的是 **`uiMaterial`（ArkUI 侧沉浸材质）**，
   * 而底栏走的是 **`hdsMaterial`（HDS 侧 bottom-tab 材质）** —— 两套接口、两套能力。
   * 设备可能 uiMaterial 全绿而 hdsMaterial 抛异常（`hdsMaterial` 是 6.1.0(23) 的接口）。
   * 若此时 `Main.ets` 仍把 `systemMaterialEffect` 塞进 `barFloatingStyle`，
   * 那一整段在 build() 里**没有 try 可包**，直接崩页。
   *
   * ## 为什么只判"能不能调"、不再判"选哪个档"
   * 2026-09-28 按官方博客《让底部导航栏的光晕跟着手指跑》重置为最简配置：
   * `materialType` / `materialLevel` **都传 `ADAPTIVE`**，由系统自适应选档 ——
   * 这是官方推荐值，不需要我方再查 `getSystemMaterialTypes()` 手动指定。
   *
   * > 官方进阶用法（"不想让系统自作主张地选择效果等级"时）才是先查再指定，
   * > 见 `resolveNavHdsSupport()` 里保留的注释与下方历史区块。
   */
  private static navHdsOk: boolean = false;

  /** HDS 底栏材质是否可用（false → Main 不要传 `systemMaterialEffect`，走纯留边降级） */
  static navSupported(): boolean {
    return Mat.navHdsOk;
  }

  /**
   * 探测 `hdsMaterial` 接口是否可调用（**只判可用性，不选档位**）。
   *
   * 用 `getSystemMaterialTypes()` 作探针：能正常返回就意味着 6.1.0(23) 的接口在本机可用。
   * 抛异常（低版本系统）→ `navHdsOk = false` → Main 走纯留边降级，不崩页。
   */
  static resolveNavHdsSupport(): void {
    try {
      const types = hdsMaterial.getSystemMaterialTypes();
      Mat.navHdsOk = true;
      // 诊断日志：装机后 HiLog 搜 NavMaterial 可直接确认设备能力上报
      hilog.info(0x0000, 'skt',
        'NavMaterial: systemMaterialTypes=%{public}s -> HDS material available (ADAPTIVE mode)',
        JSON.stringify(types));
    } catch (e) {
      Mat.navHdsOk = false;
      hilog.warn(0x0000, 'skt',
        'NavMaterial: getSystemMaterialTypes threw -> no HDS material: %{public}s',
        (e as Error).message);
    }
  }

  /**
   * 【已废弃，2026-09-28】原「运行时查询档位」实现。
   *
   * 当时以为官方要求"未采用系统自适应能力时必须先查 getSystemMaterialTypes() 再指定档位"，
   * 于是写了这个函数按亮/暗色手动选 GENTLE / EXQUISITE。
   *
   * ⚠️ 实际官方博客《让底部导航栏的光晕跟着手指跑》给的最简推荐配置是
   * `materialType: ADAPTIVE` + `materialLevel: ADAPTIVE` —— **交给系统自适应**。
   * "先查再指定"只是**进阶用法**（原文：「如果你不想让系统'自作主张'地选择效果等级」）。
   *
   * 现已改用官方默认（见 `resolveNavHdsSupport()`），本函数不再被调用，保留仅为备查。
   *
   * --- 以下是官方进阶用法的原始代码，需要"自己控制精细程度"时可参考 ---
   * ```ts
   * let types: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes()
   * if (types.indexOf(hdsMaterial.MaterialType.IMMERSIVE) < 0) {
   *   // 设备不支持 IMMERSIVE，用 SMOOTH 降低卡顿和发热风险
   *   this.customMaterialLevel = hdsMaterial.MaterialLevel.SMOOTH
   * }
   * // 然后 materialType 仍用 ADAPTIVE，materialLevel 用 this.customMaterialLevel
   * ```
   */

  /**
   * 材质对象。用 `undefined` 而不是 `Material.empty` 作初值：
   * 模块加载期不碰 native 接口，避免在 Ability 起来之前就调用系统能力。
   * `systemMaterial()` 的参数签名是 `SystemUiMaterial | undefined`，传 undefined 是合法的。
   */
  private static mCard: uiMaterial.Material | undefined = undefined;
  private static mTile: uiMaterial.Material | undefined = undefined;
  private static mBar: uiMaterial.Material | undefined = undefined;
  private static mSheet: uiMaterial.Material | undefined = undefined;
  private static mBtn: uiMaterial.Material | undefined = undefined;
  /** 液态玻璃（课表表头）：ULTRA_THIN + 极低着色 + colorInvert，**无阴影**（贴在内容上） */
  private static mLiquid: uiMaterial.Material | undefined = undefined;
  /** 悬浮玻璃（课表悬浮顶栏胶囊）：与 mLiquid 同参数但 **applyShadow: true**（浮在内容上） */
  private static mFloat: uiMaterial.Material | undefined = undefined;
  // 注：原 `mNav`（底栏胶囊材质）已于 2026-09-28 移除 —— 底栏材质归 HDS 管，不归 uiMaterial，见上方说明。

  private static inited: boolean = false;

  // ---------- 访问器 ----------

  /** 大卡片：白底毛玻璃，带材质自带阴影 */
  static card(): uiMaterial.Material | undefined {
    return Mat.mCard;
  }

  /** 卡片内的嵌套小块（转写框、答案框、未选中行）：更薄、无阴影 */
  static tile(): uiMaterial.Material | undefined {
    return Mat.mTile;
  }

  /** 顶栏 / 悬浮条：主题色着色 + 交互形变（滚动内容从下方透出模糊） */
  static bar(): uiMaterial.Material | undefined {
    return Mat.mBar;
  }

  /** 弹窗 / ActionSheet / 半模态：厚材质，遮住底下内容 */
  static sheet(): uiMaterial.Material | undefined {
    return Mat.mSheet;
  }

  /** 主操作按钮（启动 / 停止 / 保存）：主题色着色 + 按下的光感反馈 */
  static button(): uiMaterial.Material | undefined {
    return Mat.mBtn;
  }

  /**
   * 液态玻璃（课表表头等"贴在内容上方、要让内容透出来"的条）。
   *
   * ## 为什么要单独一档，不能复用 `bar()`
   * `bar()` 是 THIN + 主题色 **0.72** 着色 —— 着色太重，底下内容基本被盖住，
   * 适合"顶栏要立得住"的场景。表头行要的是**玻璃感**：内容能透出来、
   * 只有一点色彩倾向，所以必须 `ULTRA_THIN` + **极低**着色。
   *
   * ## 官方 API 的能力边界（查过 SDK，别指望没有的东西）
   * 用户要的"液态玻璃"含四个特征，`uiMaterial` 的覆盖情况：
   * | 特征 | 支持 | 实现 |
   * |---|---|---|
   * | 背景模糊 | ✅ | `ImmersiveMaterial` 本身就是模糊 |
   * | 轻微折射 | ❌ **无此 API** | 系统未暴露 `refract`；用 `ULTRA_THIN` + 极低着色**模拟观感** |
   * | 边缘高光随滚动位移 | ❌ **无此 API** | 系统无"跟随滚动"的折射高光 → 由调用方用描边近似（见 `headerRow`） |
   * | 玻璃/文字颜色按下方亮度自适应 | ✅ **原生** | `colorInvert: true`（官方文档原文即"自动适配背景互补色"） |
   *
   * ## `colorInvert` 的前置条件（官方原文，踩过就知道不是随便开的）
   * - 材质**至少 THIN 或 ULTRA_THIN**（`REGULAR`/`THICK` 上开了无效）
   * - 且与"应用沉浸光效的强度配置"有关；**越薄越容易满足**
   * - 生效范围**明确包含 `Text.fontColor`** —— 这正是表头文字要的
   */
  static liquidGlass(): uiMaterial.Material | undefined {
    return Mat.mLiquid;
  }

  /**
   * 悬浮玻璃 —— 用于「脱边留白、看起来浮在内容上方」的块（课表悬浮顶栏胶囊）。
   *
   * ## 与 `liquidGlass()` 的区别：**只有 `applyShadow`**
   * | | `liquidGlass()` | `floatGlass()` |
   * |---|---|---|
   * | style | ULTRA_THIN | ULTRA_THIN |
   * | materialColor | 主题色 0.10 | 主题色 0.10 |
   * | colorInvert | true | true |
   * | **applyShadow** | **false** | **true** |
   *
   * 为什么不合并成一档：**投影就是"悬浮"的物理来源**。
   * 表头是"嵌在内容里的一条"（无影），胶囊是"飘在上面的一块板"（有影）。
   * 合并后要么表头浮起来（假），要么胶囊贴回去（就不是悬浮了）。
   */
  static floatGlass(): uiMaterial.Material | undefined {
    return Mat.mFloat;
  }

  /**
   * 【已移除，2026-09-28】原 `navGlass()` —— 底栏导航胶囊的透明玻璃材质。
   *
   * 撤销原因：**底栏的材质不归 `uiMaterial` 管，归 HDS 的 `systemMaterialEffect` 管。**
   * 当初把这个材质挂在 `TabContent` 的 `.tabBar()` 单元上当"选中底板"，
   * 但 HDS 底栏的玻璃效果来自 `barFloatingStyle.systemMaterialEffect`，
   * 两者是不同层级的东西 —— 挂在这里既不能影响胶囊本体，又平添一层需要维护的材质。
   *
   * 现在按官方博客给的最简配置走：`materialType/materialLevel` 都传 `ADAPTIVE`，
   * 胶囊外观完全交给 HDS，我方不再自建底栏材质。
   */

  // ---------- 初始化 ----------

  /**
   * 探测能力 + 建材质。幂等，重复调用只探一次。
   * 必须在**第一次 build 之前**调用（`EntryAbility.onCreate` 与主页 `aboutToAppear` 各调一次，
   * 因为主页之外还有 router 推上来的独立页面）。
   *
   * ## 为什么探测要这么啰嗦（三层保险）
   * `systemMaterial` / `ImmersiveMaterial` 是 **SDK 26.0.0** 的 API，而本工程
   * `compatibleSdkVersion` 是 **6.1.0(23)** —— 在 23 的设备上直接调用可能抛异常，
   * 而 45 处 `.systemMaterial(Mat.xxx())` 都写在 build() 里，那里没有 try 可包。
   * 所以必须在**这里**就把结论钉死（详见 `detect()`）：
   * 任一层不过 → `supported = false` → 所有访问器返回 `undefined` →
   * `systemMaterial(undefined)` 等于没挂 → 界面回落到 `.backgroundColor()`，与改造前完全一致。
   * 因此**不必为那 45 处调用逐个加 apiAvailable 守卫**，压力都收敛在这一个点上。
   */
  static init(): void {
    if (Mat.inited) {
      return;
    }
    Mat.inited = true;
    Mat.supported = Mat.detect();
    // ★ 关键诊断：`Mat.supported` 决定全工程 54 处 `.systemMaterial()` 是
    //   「真挂上材质」还是「静默走 backgroundColor 降级」——两者外观差别巨大，
    //   但**从界面上看不出来**（降级时界面完全正常，只是没有玻璃感）。
    //   2026-09-28 用户反馈「还是不透明」时，我让用户看日志，却发现**这行日志从来没打过**，
    //   导致「材质到底有没有生效」只能靠猜。补上，别再犯。
    hilog.info(0x0000, 'skt',
      'uiMaterial: supported=%{public}s (isImmersiveMaterialSupported / buildAll probe)',
      Mat.supported ? 'TRUE' : 'FALSE');
    // ★ 底栏 HDS 材质是**独立的系统能力**，不依赖上面的 detect()：
    //   detect() 探的是 uiMaterial（内容卡片材质），底栏走 hdsMaterial，两套接口。
    //   此处只判"接口能不能调"（防 build() 里无 try 崩页）；档位交给官方默认的 ADAPTIVE 自适应。
    Mat.resolveNavHdsSupport();
    Mat.rebuild();
    // 主题色变了，带主题色着色的材质要重建（各页已有 @State 镜像，会自行重绘）
    Theme.onChange(() => {
      Mat.rebuild();
    });
  }

  /**
   * 三层探测。
   *
   * ⚠️ 注意：`uiMaterial` 的 syscap 是 **`SystemCapability.ArkUI.ArkUI.Full`**（不是独立的 UIMaterial 能力），
   * 而 ArkUI.Full 几乎每台设备都有 —— 所以 `canIUse` 对「SDK 26 才有这个 API」这件事**没有区分度**，
   * 真正起作用的是 ② 硬件能力探测 和 ③ 构造兜底。
   * ① 留着只为「理论上某些裁剪系统连 ArkUI.Full 都没有」的极端情形。
   */
  private static detect(): boolean {
    // ① 极端兜底：连完整 ArkUI 能力都没有的系统（正常设备都会过）
    try {
      if (!canIUse('SystemCapability.ArkUI.ArkUI.Full')) {
        return false;
      }
    } catch (e) {
      return false;
    }
    // ② 关键关卡：接口存在 ≠ 硬件支持（SDK 26 之前调用会抛 / 低端机不具备）
    try {
      if (!uiMaterial.isImmersiveMaterialSupported()) {
        return false;
      }
    } catch (e) {
      return false;
    }
    // ③ 连构造函数都试一遍：能建出来才算真的可用
    try {
      Mat.buildAll();
      return Mat.mCard !== undefined;
    } catch (e) {
      return false;
    }
  }

  /** 重建材质对象（换色系 / 首次初始化时调用）。不支持时清空 → 访问器返回 undefined */
  static rebuild(): void {
    if (!Mat.supported) {
      Mat.clearAll();
      return;
    }
    try {
      Mat.buildAll();
    } catch (e) {
      // 任何一步失败：整体退回无材质，界面照常
      Mat.clearAll();
    }
  }

  /** 清空全部材质（降级路径） */
  private static clearAll(): void {
    Mat.mCard = undefined;
    Mat.mTile = undefined;
    Mat.mBar = undefined;
    Mat.mSheet = undefined;
    Mat.mBtn = undefined;
    Mat.mLiquid = undefined;
    Mat.mFloat = undefined;
  }

  /**
   * 真正构造 5 个材质对象。**不做 supported 判断**（`detect()` 要靠它验证能否构造），
   * 失败时抛给调用方处理。
   *
   * ## ⚠️ 光效三件套（漏了就等于「只挂了块毛玻璃」，没有光影）
   * `ImmersiveOptions` 里跟**光效**直接相关的是三个字段，不是只有 `style`：
   * | 字段 | 作用 | 默认 | 我们的取值 |
   * |---|---|---|---|
   * | `interactive` | 按压弹性形变（触摸时轻微缩放） | `false` | 可交互的面（bar/button）→ `true` |
   * | `lightEffect` | **光感交互反馈**（按压点光源 + 材质流光）。**默认 `undefined` = 完全不设置！** | `undefined` | 可交互的面 → `{ color: undefined }` |
   * | `colorInvert` | 智能反色：底下的内容色与前景接近时自动调前景色 | `false` | 薄材质（tile/bar）→ `true` |
   *
   * **`lightEffect` 是「有没有光影」的分水岭**：不设它，`interactive` 只有形变没有光，
   * 界面上看不出任何「光」的感觉。文档原文：*"If this parameter is set to null,
   * the light sensing interaction feedback effect is disabled."*
   */
  private static buildAll(): void {
    // ==========================================================================
    // ⚠️ `materialColor` 的 alpha 必须**留出透明度**（2026-09-28 第五次修正）
    //
    // ## 官方语义（`@ohos.arkui.uiMaterial.d.ts`）
    // `materialColor` = 材质**自身的着色层**，`@default Color.Transparent`。
    // 文档明写：**「必须有透明度，否则完全挡住材质滤镜」**。
    //
    // ## 我犯的错（用户反馈「还是不透明」，排查后的真因）
    // 上一版这里写的是 `#E8FFFFFF`(92%白) / `#D9FFFFFF`(85%白) / `#F2FFFFFF`(95%白)。
    // 我当时以为这是"白色毛玻璃的白色分量"—— **错**。这三个值在系统眼里
    // 就是**一层 92% / 85% / 95% 的白漆**，把底下的模糊滤镜整个盖死。
    //
    // 于是全站表现为：卡片=白漆块、小块=白漆块、弹窗=白漆块。
    // 用户报的三个问题（选中项发白、块连成一片、表头无玻璃）**是同一个根因的三个表现**。
    //
    // ## 修正原则（B 方案：实卡片 + 玻璃小块/顶栏/按钮）
    // · 大卡片保留四成白 —— 卡片是大量文字的承载体，全透会伤可读性；
    //   它靠 `applyShadow` 立住层次，不靠白漆。
    // · 小块/顶栏/按钮**大幅降 alpha** —— 这几个才是"看得出玻璃"的地方。
    // · 弹窗 `sheet()` **保持厚实** —— "压住底下内容"本来就是它的职责，不参与本次透明化。
    // ==========================================================================

    // ---- 大卡片：四成白 + 自带阴影（B 方案：保留可读性，不做全透）----
    // 卡片本身不按压（点的是卡片里的东西），但要有智能反色让标题在浅内容上仍清晰
    const o: uiMaterial.ImmersiveOptions = {
      style: uiMaterial.ImmersiveStyle.REGULAR,
      materialColor: '#66FFFFFF',
      applyShadow: true,
      interactive: false,
      colorInvert: true,
    };
    Mat.mCard = new uiMaterial.ImmersiveMaterial(o);

    // ---- 卡片内嵌套块：极薄、无阴影（本次改动最大的一档）----
    // 8% 白 = 几乎纯靠模糊 + 智能反色，这是最接近"玻璃"的观感。
    // 这些块底下几乎都是卡片自身的浅底，"透出来的东西"就是卡片色 —— 观感是"玻璃嵌在卡片上"。
    const oTile: uiMaterial.ImmersiveOptions = {
      style: uiMaterial.ImmersiveStyle.THIN,
      materialColor: '#14FFFFFF',
      applyShadow: false,
      interactive: true,
      lightEffect: { color: undefined },
      colorInvert: true,
    };
    Mat.mTile = new uiMaterial.ImmersiveMaterial(oTile);

    // ---- 顶栏 / 悬浮条：主题色着色 + 沉浸光感 ----
    // 从 0.72 降到 0.30：顶栏要**看得出是主题色**，但不能再糊成一条实色带。
    // lightEffect 让顶栏上的按钮按压时出光晕；interactive 给弹性缩放
    const oBar: uiMaterial.ImmersiveOptions = {
      style: uiMaterial.ImmersiveStyle.THIN,
      materialColor: Mat.alpha(Theme.themeColor(), 0.30),
      applyShadow: false,
      interactive: true,
      lightEffect: { color: undefined },
      colorInvert: true,
    };
    Mat.mBar = new uiMaterial.ImmersiveMaterial(oBar);

    // ---- 弹窗 / 半模态：厚材质，遮住底下内容 ----
    // ⚠️ 本档**不参与透明化**（B 方案里唯一保持厚实的一档）。
    // "压得住下面的内容"就是它的职责 —— 弹窗要透光反而会看不清里面的字。
    // 面板要「压得住」下面的内容，不要智能反色（会让面板颜色跟着背景跑）
    const oSheet: uiMaterial.ImmersiveOptions = {
      style: uiMaterial.ImmersiveStyle.THICK,
      materialColor: '#F2FFFFFF',
      applyShadow: true,
      interactive: false,
    };
    Mat.mSheet = new uiMaterial.ImmersiveMaterial(oSheet);

    // ---- 主操作按钮：主题色着色 + 按压光效 ----
    // 从 REGULAR/0.85 降到 THIN/0.55：按钮仍要"是主题色"，但要留出透光。
    // REGULAR 档在官方口径里**不支持 colorInvert**，顺带一并下到 THIN。
    const oBtn: uiMaterial.ImmersiveOptions = {
      style: uiMaterial.ImmersiveStyle.THIN,
      materialColor: Mat.alpha(Theme.themeColor(), 0.55),
      applyShadow: true,
      interactive: true,
      lightEffect: { color: undefined },
      colorInvert: true,
    };
    Mat.mBtn = new uiMaterial.ImmersiveMaterial(oBtn);

    // ---- 液态玻璃：ULTRA_THIN + 极低着色 + colorInvert ----
    // 表头行专用。三个取值都不是随手定的：
    // · style = ULTRA_THIN（官方原文 "very strong transparent effect"）——
    //   这是**唯一**能让 colorInvert 生效的最薄档，同时=最接近"液态玻璃"的观感。
    // · materialColor = 主题色 alpha **0.10** —— 只要一点色彩倾向，重了就不透。
    //   （对比 `bar()` 用 0.30，那是"顶栏要立得住"的量。）
    // · interactive = false —— 表头是静态标签，不是可点面，不需要按压形变。
    // · lightEffect 不设 —— 它的语义是"按压处的光感反馈"，
    //   表头不可点，设了反而会在误触时冒出光斑。
    // · applyShadow = false —— 表头是"贴在内容上的一条"，不该浮起来。
    //   需要**浮起来**的那块用下面的 `mFloat`。
    const oLiquid: uiMaterial.ImmersiveOptions = {
      style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
      materialColor: Mat.alpha(Theme.themeColor(), 0.10),
      applyShadow: false,
      interactive: false,
      colorInvert: true,
    };
    Mat.mLiquid = new uiMaterial.ImmersiveMaterial(oLiquid);

    // ---- 悬浮玻璃块（2026-09-28 第七次修正新增）----
    // 用于「脱离屏幕边缘、四周留白、看起来浮在内容上方」的块 —— 目前是课表悬浮顶栏胶囊。
    //
    // 与 `mLiquid` 的**唯一区别是 `applyShadow: true`**：
    //   悬浮感的物理来源就是投影。同一套 ULTRA_THIN + 极低着色 + 反色，
    //   但因为带阴影，它读起来是"飘在内容上面的一块玻璃板"，
    //   而 `mLiquid` 贴在表头位置、无阴影，读起来是"嵌在内容里的一层"。
    //   → 两者不能合并：合并后要么表头浮起来（假），要么胶囊贴回去（就不是悬浮了）。
    const oFloat: uiMaterial.ImmersiveOptions = {
      style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
      materialColor: Mat.alpha(Theme.themeColor(), 0.10),
      applyShadow: true,
      interactive: false,
      colorInvert: true,
    };
    Mat.mFloat = new uiMaterial.ImmersiveMaterial(oFloat);

    // 注：原「玻璃导航胶囊」材质（oNav / mNav）已于 2026-09-28 移除。
    // 底栏材质归 HDS 的 `barFloatingStyle.systemMaterialEffect` 管，不归 uiMaterial，
    // 在这里自建一份既无效果又添维护负担。现在走官方最简配置（ADAPTIVE + ADAPTIVE）。
  }

  /**
   * `#RRGGBB` → `#AARRGGBB`（ArkUI 的 ResourceColor 用 8 位十六进制时是 AARRGGBB）。
   * `a` 取 0~1。解析不出来时原样返回，交给系统去忽略。
   */
  static alpha(hex: string, a: number): string {
    let h = hex;
    if (h.length === 4) {
      // #RGB -> #RRGGBB
      const r = h.substring(1, 2);
      const g = h.substring(2, 3);
      const b = h.substring(3, 4);
      h = '#' + r + r + g + g + b + b;
    }
    if (h.length < 7) {
      return hex;
    }
    let n = Math.round(a * 255);
    if (n < 0) {
      n = 0;
    }
    if (n > 255) {
      n = 255;
    }
    let s = n.toString(16).toUpperCase();
    if (s.length < 2) {
      s = '0' + s;
    }
    return '#' + s + h.substring(1);
  }
}
