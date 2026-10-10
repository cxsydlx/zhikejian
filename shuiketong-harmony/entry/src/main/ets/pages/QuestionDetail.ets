import { router } from '@kit.ArkUI';
import { AppState, QuestionItem } from '../common/AppState';
import { LlmRunner } from '../service/LlmRunner';
import { Theme } from '../common/Theme';
import { Mat } from '../common/Material';
import { WindowInsets } from '../common/WindowInsets';
import { FontSize, Weight, Space, Radius, Size, Motion, Layout } from '../common/DesignToken';


@Entry
@Component
struct QuestionDetail {
  // ---- 主题镜像：ArkUI 只观察「渲染中读取过」的状态；配色变化必须镜像成 @State 才会重绘 ----
  @State tc: string = Theme.themeColor();
  @State tacc: string = Theme.accentColor();
  @State tsoft: string = Theme.softColor();
  @State tpage: string = Theme.pageColor();
  @State ton: string = Theme.onTheme();
  @State tmain: string = Theme.textMain();
  @State tsub: string = Theme.textSub();

  @State questionId: number = -1;
  @State item: QuestionItem | null = null;
  /** 默认关闭深度思考：enable_thinking 是通义/Qwen 系私有字段，多数 OpenAI 兼容服务收到会 400 */
  @State thinking: boolean = false;
  @State contextText: string = '';
  private refreshTimer: number = -1;

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

    const params = router.getParams() as Record<string, number> | undefined;
    if (params != null && typeof params['id'] === 'number') {
      this.questionId = params['id'] as number;
    }
    this.refresh();
    this.refreshTimer = setInterval(() => {
      this.refresh();
    }, 300);
  }

  aboutToDisappear(): void {
    if (this.refreshTimer >= 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
  }

  private refresh(): void {
    const q = AppState.findQuestion(this.questionId);
    if (q != null) {
      this.item = q;
      if (this.contextText.length === 0) {
        this.contextText = AppState.buffer.windowBefore(q.ts, 90000, 600);
      }
    }
  }

  private ask(): void {
    const q = AppState.findQuestion(this.questionId);
    if (q == null || q.answering) {
      return;
    }
    // 程序自主取该问题出现前 90 秒内、最多 600 字的相关上下文
    const ctx = AppState.buffer.windowBefore(q.ts, 90000, 600);
    this.contextText = ctx;
    LlmRunner.ask(q.id, q.text, ctx, this.thinking);
  }

  /**
   * 自绘顶栏（返回键 + 标题）。
   *
   * ⛔ 不用 `HdsNavigation`：真机实测其子树永不渲染（整页白屏），
   * 详见 `common/RouteBar.ets` 头部。也不用全局 `RouteBar()` ——
   * 全局 `@Builder` 参数**按值传递**，依赖页面状态时会不刷新。
   *
   * 视觉规格与 `CourseEdit.barContent()` / `ImportSchedule.barContent()` 完全一致
   * （主题色满铺 + `Size.bar` 高度 + 状态栏避让），路由页之间跳转不会"跳一下"。
   * 本页无右上动作，故不画胶囊，标题也不带副标题。
   */
  @Builder
  barContent() {
    Row() {
      // 返回键：48×48 触控热区（官方无障碍硬指标）
      Text('\u2039')
        .fontSize(FontSize.titleM)
        .fontColor(Theme.sysTextMain())
        .width(Size.touchTarget)
        .height(Size.touchTarget)
        .textAlign(TextAlign.Center)
        .borderRadius(Radius.full)
        .onClick(() => {
          router.back();
        })

      Text('问题详情')
        .fontSize(FontSize.titleS)
        .fontWeight(Weight.bold)
        .fontColor(Theme.sysTextMain())
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
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
    .backgroundColor(Theme.sysPage())
  }

  /** 页面骨架：自绘顶栏 + 内容流（不再用 HdsNavigation，真机不渲染子树） */
  build() {
    Column() {
      this.barContent()
      Scroll() {
        Column() {
          if (this.item != null) {
            // ---- 问题 ----
            Column() {
              Text('问题')
                .fontSize(FontSize.bodyS)
                .fontWeight(Weight.medium)
                .fontColor(Theme.sysTextSub())
                .width('100%')
              Text(this.item!.text)
                .fontSize(FontSize.titleS)
                .fontWeight(Weight.bold)
                .fontColor(Theme.sysTextMain())
                .width('100%')
                .margin({ top: Space.s })
              Text(`检测于 ${new Date(this.item!.ts).toTimeString().substring(0, 8)}`)
                .fontSize(FontSize.bodyS)
                .fontColor(Theme.sysTextSub())
                .width('100%')
                .margin({ top: Space.s })
            }
            .width('100%')
            .padding(Space.l)
            .borderRadius(Radius.l)
            .backgroundColor(Theme.cardBase())
            .systemMaterial(Mat.card())

            if (this.item!.answering) {
              Row() {
                // 思考状态插图：头部侧影 + 脑内螺旋（左上四分之一格构图，故裁成正方）
                Image($r('app.media.ill_thinking'))
                  .width(Size.statusIll)
                  .height(Size.statusIll)
                  .objectFit(ImageFit.Contain)
                Text(this.item!.answer.length > 0 ? '正在生成答案…' : '正在思考中…')
                  .fontSize(FontSize.subtitleM)
                  .fontWeight(Weight.medium)
                  .fontColor(Theme.sysTextMain())
                  .margin({ left: Space.m })
                  .layoutWeight(1)
                // 转圈保留在右侧：插图表达"在想什么"，转圈表达"还在进行中"，语义不重复
                LoadingProgress()
                  .width(20)
                  .height(20)
                  .color(Theme.sysEmphasize())
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding(Space.l)
              .margin({ top: Space.m })
              .borderRadius(Radius.l)
              .backgroundColor(Theme.cardBase())
              .systemMaterial(Mat.card())
            }

            // ---- 控制行 ----
            Row() {
              Column() {
                Text('深度思考')
                  .fontSize(FontSize.subtitleM)
                  .fontColor(Theme.sysTextMain())
                Text('更准但更慢（R1/Qwen3 类思考模型）')
                  .fontSize(FontSize.captionM)
                  .fontColor(Theme.sysTextSub())
                  .margin({ top: Space.textGap })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Toggle({ type: ToggleType.Switch, isOn: this.thinking })
                .systemMaterial(Mat.tile())
                .onChange((on: boolean) => {
                  this.thinking = on;
                })

              // 【2026-09-28 第二十次修正 · 改官方胶囊按钮规范】
              // 原来手写 `height(touchTarget)` + `padding(l/r)` + `borderRadius(Radius.full)`
              // + `fontSize(subtitleS)` —— 在用 padding 和圆角**手工模拟官方胶囊按钮**。
              // 官方 `Button` 自带形状/尺寸档，改用它：
              //   · `ButtonType.Capsule` —— 胶囊形（圆角 = 高度一半）
              //   · `controlSize(ControlSize.NORMAL)` —— 官方标准档（本页正文按钮比列表行内的大一号，
              //      故用 NORMAL 而非 SMALL；圆角 20vp、走系统字号）
              //   · `role(ButtonRole.NORMAL)` —— 语义角色，供无障碍/自动语义
              // ⚠️ 仅保留 App 主题体系的表达：`backgroundColor(this.tc)` + `Mat.button()` 材质。
              //    （原来就去掉了硬编码 '#F97316'，这条继续有效。）
              Button(this.item!.answering ? '垂询中…' : (this.item!.done ? '重新垂询' : '垂询'),
                { type: ButtonType.Capsule, stateEffect: true })
                .controlSize(ControlSize.NORMAL)
                .role(ButtonRole.NORMAL)
                .fontWeight(Weight.medium)
                .fontColor(Theme.onEmphasize())
                .backgroundColor(Theme.sysEmphasize())
                .systemMaterial(Mat.button())
                .enabled(!this.item!.answering)
                .opacity(this.item!.answering ? 0.5 : 1)
                .margin({ left: Space.m })
                .onClick(() => {
                  this.ask();
                })
            }
            .width('100%')
            .padding(Space.l)
            .margin({ top: Space.m })
            .borderRadius(Radius.l)
            .backgroundColor(Theme.cardBase())
            .systemMaterial(Mat.card())
            .alignItems(VerticalAlign.Center)

            // ---- 思考过程 ----
            if (this.item!.reasoning.length > 0) {
              Column() {
                Text('思考过程')
                  .fontSize(FontSize.subtitleM)
                  .fontWeight(Weight.bold)
                  .fontColor(Theme.sysEmphasize())
                  .width('100%')
                Scroll() {
                  Text(this.item!.answering ? this.item!.reasoning + ' ▌' : this.item!.reasoning)
                    .fontSize(FontSize.bodyS)
                    .fontColor(Theme.sysTextSub())
                    .width('100%')
                }
                .height(140)
                .margin({ top: Space.s })
                .padding(Space.m)
                .borderRadius(Radius.m)
                .backgroundColor(Theme.tintColor(0.9))
                .scrollBar(BarState.Auto)
                .align(Alignment.Bottom)
              }
              .width('100%')
              .padding(Space.l)
              .margin({ top: Space.m })
              .borderRadius(Radius.l)
              .backgroundColor(Theme.innerBase())
              .systemMaterial(Mat.tile())
            }

            // ---- 答案 ----
            Column() {
              Row() {
                // 答案插图：灯泡 + 星光
                Image($r('app.media.ill_answer'))
                  .width(28)
                  .height(28)
                  .objectFit(ImageFit.Contain)
                Text('AI 解答')
                  .fontSize(FontSize.subtitleM)
                  .fontWeight(Weight.bold)
                  .fontColor(Theme.sysEmphasize())
                  .margin({ left: Space.s })
                  .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              Text(this.answerText())
                .fontSize(FontSize.bodyM)
                .fontColor(Theme.sysTextMain())
                .width('100%')
                .margin({ top: Space.s })
                .padding(Space.m)
                .borderRadius(Radius.m)
                .backgroundColor(Theme.tintColor(0.9))
            }
            .width('100%')
            .padding(Space.l)
            .margin({ top: Space.m })
            .borderRadius(Radius.l)
            .backgroundColor(Theme.cardBase())
            .systemMaterial(Mat.card())
            Column() {
              Row() {
                // 依据插图：文档 + 高亮段 + 放大镜（小尺寸，与下方引用块形成视觉呼应）
                Image($r('app.media.ill_source'))
                  .width(28)
                  .height(28)
                  .objectFit(ImageFit.Contain)
                Text('课堂原文依据')
                  .fontSize(FontSize.subtitleM)
                  .fontWeight(Weight.bold)
                  .fontColor(Theme.sysTextMain())
                  .margin({ left: Space.s })
                  .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              Scroll() {
                Text(this.contextText === '' ? '垂询时会自动截取提问前的相关转写' : this.contextText)
                  .fontSize(FontSize.bodyS)
                  .fontColor(Theme.sysTextSub())
                  .width('100%')
              }
              .height(100)
              .margin({ top: Space.s })
              .padding(Space.m)
              .borderRadius(Radius.m)
              .backgroundColor(Theme.innerBase())
              .scrollBar(BarState.Auto)
            }
            .width('100%')
            .padding(Space.l)
            .margin({ top: Space.m })
            .borderRadius(Radius.l)
            .backgroundColor(Theme.cardBase())
            .systemMaterial(Mat.card())
          } else {
            Text('该问题已不存在')
              .fontSize(FontSize.bodyM)
              .fontColor(Theme.sysTextSub())
          }
        }
        .width('100%')
        .padding({ left: Layout.screenMargin(), right: Layout.screenMargin(), top: Space.m, bottom: Space.m })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    }.transition(Motion.pageEnter())
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.sysPage())
  }

  private answerText(): string {
    const q = this.item;
    if (q == null) {
      return '';
    }
    if (q.answering && q.answer.length === 0 && q.reasoning.length === 0) {
      return '等待模型回复…（思考模型首次响应可能较慢）';
    }
    if (q.answering && q.answer.length === 0) {
      return '模型思考中，答案稍后输出…';
    }
    if (q.answering) {
      return q.answer + ' ▌';
    }
    if (q.answer.length > 0) {
      return q.answer;
    }
    return '点「垂询」让 AI 结合上下文作答';
  }
}
