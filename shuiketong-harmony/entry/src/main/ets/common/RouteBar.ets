import { Theme } from './Theme';
import { Mat } from './Material';
import { WindowInsets } from './WindowInsets';
import { FontSize, Weight, Space, Radius, Size, Layout } from './DesignToken';

/**
 * 路由页顶栏（返回键 + 标题 + 可选副标题 + 右上动作）。
 *
 * ## 为什么自绘而不用 HDS 的 `HdsNavigation.titleBar`
 *
 * ⛔ **`HdsNavigation` 在本工程设备上不可用 —— 真机实测，`canIUse` 骗人。**
 *
 * 2026-09-27 用最小复现页证实：
 * ```
 * canIUse('SystemCapability.UIDesign.HDSComponent.Core')  →  TRUE   （系统声称支持）
 * HdsNavigation() { Text('★ 内部内容 ★') }                  →  空白   （子树永不渲染）
 * ```
 * 同一页面上，放在 `HdsNavigation` **外面**的文字全部正常显示，
 * 只有它内部的子树永远出不来；`uitest dumpLayout` 里 `Navigation` 节点有 bounds、
 * 子节点数为 0。
 *
 * 这个缺陷与用法无关，三种场景全部复现：
 *   · 放进 `HdsTabs` 的 `TabContent`   → 整页白屏（三个 Tab 内页因此改自绘）
 *   · 放在 `@Entry` 路由页顶层         → 整页白屏（5 个路由页本次因此改自绘）
 *   · 传极简 titleBar（无 style / 材质）→ 依然白屏（排除"参数写错"）
 *
 * ∴ **本工程一律不使用 `HdsNavigation`。** 顶栏统一由本文件自绘，
 * 沉浸光感由 `Mat.bar()`（含 `lightEffect`）提供 —— 代价是拿不到 HDS 的滚动渐变模糊。
 *
 * ## 为什么是 `@Builder export function` 而不是 `@Component`
 * ArkTS **不允许跨文件实例化 struct**（错误码 10905204）。
 * 本工程既有约定见 `Settings.ets` 尾部的 `TabSettingsView()` —— 同一套做法。
 *
 * ## 与 Tab 内页顶栏的一致性
 * 视觉规格与 `CourseTableView.barContent()` / `ListenView.barContent()` /
 * `Settings.barContent()` 完全一致：主题色满铺横条 + `Size.bar` 高度 + 状态栏避让 +
 * 右上白底胶囊按钮。这样 Tab 内页 ⇄ 路由页来回跳转时顶栏不会"跳一下"。
 */

/** 顶栏右上动作（白底胶囊按钮） */
export interface RouteAction {
  /** 按钮文字 */
  text: string;
  /** 点击回调 */
  onClick: () => void;
  /** 是否可用；false 时降透明度且不响应点击 */
  enabled?: boolean;
}

/**
 * 渲染路由页顶栏（全局 @Builder）。
 *
 * ⚠️ 全局 `@Builder` 的**参数是按值传递**，不会响应状态变化。
 * 因此本 builder 只接受"调用时就确定"的普通值；页面若有会变的状态
 * （如"抓取中…"），把变化体现在**传进来的字符串**上并在页面里 `rev` 触发重建，
 * 或直接不用本 builder、在页面内自绘（本工程几个页面就是这么做的）。
 *
 * 用法（页面 `build()` 最外层 `Column` 的第一个子节点）：
 * ```
 * Column() {
 *   RouteBar({ title: '导入课表', subTitle: '教务系统', onBack: () => router.back() })
 *   ...页面内容...
 * }
 * ```
 */
@Builder
export function RouteBar(o: RouteBarOptions) {
  Row() {
    // ---- 返回键：48×48 触控热区（官方无障碍硬指标）----
    if (o.onBack !== undefined) {
      Text('\u2039')
        .fontSize(FontSize.titleM)
        .fontColor(Theme.onTheme())
        .width(Size.touchTarget)
        .height(Size.touchTarget)
        .textAlign(TextAlign.Center)
        .borderRadius(Radius.full)
        .onClick(() => {
          if (o.onBack !== undefined) {
            o.onBack();
          }
        })
    }

    // ---- 标题区 ----
    Column() {
      Text(o.title)
        .fontSize(FontSize.titleS)
        .fontWeight(Weight.bold)
        .fontColor(Theme.onTheme())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (o.subTitle !== undefined && o.subTitle.length > 0) {
        Text(o.subTitle)
          .fontSize(FontSize.captionL)
          .fontColor(Theme.mix(Theme.onTheme(), Theme.themeColor(), 0.45))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: Space.textGap })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
    .padding({ left: o.onBack !== undefined ? Space.s : Space.none })

    // ---- 右上动作：白底胶囊（与 Tab 内页顶栏同规格）----
    if (o.actions !== undefined) {
      ForEach(o.actions, (a: RouteAction, i: number) => {
        Text(a.text)
          .fontSize(FontSize.subtitleS)
          .fontWeight(Weight.medium)
          .fontColor(Theme.themeColor())
          .padding({ left: Space.l, right: Space.l, top: Space.xsPlus, bottom: Space.xsPlus })
          .margin({ left: i === 0 ? Space.none : Space.s })
          .borderRadius(Radius.full)
          .backgroundColor(Theme.sysFill())
          .systemMaterial(Mat.tile())
          .textAlign(TextAlign.Center)
          .opacity(a.enabled === false ? 0.5 : 1)
          .onClick(() => {
            if (a.enabled !== false) {
              a.onClick();
            }
          })
      }, (a: RouteAction, i: number) => `act-${i}-${a.text}`)
    }
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
  .backgroundColor(Theme.themeColor())
  .systemMaterial(Mat.bar())
}

/** 顶栏配置 */
export interface RouteBarOptions {
  /** 主标题 */
  title: string;
  /** 副标题（可空；有值时显示在主标题下方一行小字） */
  subTitle?: string;
  /** 返回键回调。不传则**不显示**返回键（如作为首屏时） */
  onBack?: () => void;
  /** 右上动作，最多展示 2 个（再多会挤掉标题） */
  actions?: RouteAction[];
}
