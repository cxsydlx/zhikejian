import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppState, QuestionItem, TranscriptLine } from '../common/AppState';
import { AsrService } from '../service/AsrService';
import { LlmRunner } from '../service/LlmRunner';
import { WsClient, ServerMsg } from '../service/WsClient';
import { Runtime } from '../service/Runtime';
// 【2026-09-28】LiveViewService import 已移除：实况窗不再渲染（场景未获官方开放）。
import { Theme } from '../common/Theme';
import { Mat } from '../common/Material';
import { WindowInsets } from '../common/WindowInsets';
import { TranscriptStore } from '../common/TranscriptStore';
import { FontSize, Weight, Space, Radius, Size, Motion, Elevation, Layout } from '../common/DesignToken';
import { LiquidToggle } from './LiquidToggle';


/**
 * 听课页（Tab）：实时转写 + 问题检测 + 垂询。
 * 由原主页 Index 迁移而来，改为可嵌入 Tabs 的组件。
 */
@Component
export struct ListenView {
  // ---- 主题镜像：ArkUI 只观察「渲染中读取过」的状态；配色变化必须镜像成 @State 才会重绘 ----
  @State tc: string = Theme.themeColor();
  @State tacc: string = Theme.accentColor();
  @State tsoft: string = Theme.softColor();
  @State tpage: string = Theme.pageColor();
  @State ton: string = Theme.onTheme();
  @State tmain: string = Theme.textMain();
  @State tsub: string = Theme.textSub();
  // 【2026-10-02】液体听课键的底色。必须是**会变的字符串**：
  // Canvas 只吃字符串（不吃 Resource），而且它的重绘得靠这个值变化来触发 ——
  // 深浅色切换时其它 @State 可能因为取到同一个取值而不重绘，这个一定会变。
  @State temph: string = Theme.sysEmphasizeHex();

  @State questions: QuestionItem[] = [];
  @State transcript: TranscriptLine[] = [];
  @State partial: string = '';
  @State running: boolean = false;
  @State status: string = '未启动';
  @State elapsedText: string = '00:00';
  private ws: WsClient = new WsClient();
  private ctx: common.UIAbilityContext | null = null;
  private scroller: Scroller = new Scroller();
  private pollTimer: number = -1;
  private holdAutoScrollUntil: number = 0;   // 用户手动滚动转写区时，暂停自动跟随

  private syncTheme(): void {
    this.tc = Theme.themeColor();
    this.tacc = Theme.accentColor();
    this.tsoft = Theme.softColor();
    this.tpage = Theme.pageColor();
    this.ton = Theme.onTheme();
    this.tmain = Theme.textMain();
    this.tsub = Theme.textSub();
    this.temph = Theme.sysEmphasizeHex();
  }

  aboutToAppear(): void {
    Theme.onChange(() => {
      this.syncTheme();
    });
    this.syncTheme();

    const ctx = getContext(this) as common.UIAbilityContext;
    this.ctx = ctx;
    AppState.init(ctx);
    AppState.onQuestionsChanged((items: QuestionItem[]) => {
      this.questions = items.slice();
    });

    // 转写高频更新：200ms 轮询拉取，避免每帧刷新
    let lastVer = -1;
    let lastPartial = '';
    this.pollTimer = setInterval(() => {
      this.partial = AppState.partialText;
      const session = TranscriptStore.current;
      if (this.running && session != null) {
        const seconds = Math.max(0, Math.floor((Date.now() - session.startMs) / 1000));
        this.elapsedText = `${Math.floor(seconds / 60).toString().padStart(2, '0')}:${(seconds % 60).toString().padStart(2, '0')}`;
      }
      const verChanged = TranscriptStore.version !== lastVer;
      const partialChanged = this.partial !== lastPartial;
      if (verChanged) {
        lastVer = TranscriptStore.version;
        // 显示整节课的转写（本地保存的那份），不再是内存里的临时缓冲
        const cur = TranscriptStore.current;
        const lines: TranscriptLine[] = [];
        if (cur != null) {
          for (const l of cur.lines) {
            lines.push(new TranscriptLine(l.text, l.ts));
          }
        }
        this.transcript = lines;
      }
      if ((partialChanged || verChanged) && Date.now() > this.holdAutoScrollUntil) {
        lastPartial = this.partial;
        // 延迟到下一帧布局完成后再滚底，否则 scrollEdge 作用在旧内容上
        setTimeout(() => {
          this.scroller.scrollEdge(Edge.Bottom);
        }, 50);
      }
    }, 200);

    // 服务器检测通道
    this.ws.onOpen = () => {
      if (!this.running) {
        return;   // 停止过程中的连接事件：不改状态
      }
      this.status = '运行中（已连接服务器）';
    };
    this.ws.onError = (msg: string) => {
      if (!this.running) {
        return;   // 停止时 ws.close() 会触发 close/error：不能把状态改回"运行中"
      }
      this.status = msg.startsWith('未配置检测服务器')
        ? '运行中（端侧检测）'
        : `运行中（${msg}，端侧检测中）`;
    };
    this.ws.onMessage = (raw: string) => {
      if (!this.running) {
        return;   // 停止后服务端残留消息：不再写入问题列表
      }
      const m = ServerMsg.parse(raw);
      if (m != null && m.type === 'question' && m.isQuestion) {
        AppState.addQuestion(m.question);
      }
    };
  }

  aboutToDisappear(): void {
    // 组件销毁时收掉轮询定时器（原来没清理，会一直空转）
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private async toggle(): Promise<void> {
    if (this.running) {
      this.running = false;    // 先置停止态：ws 关闭事件 / 引擎残留回调据此一律丢弃
      AsrService.stop();
      this.ws.stop();
      TranscriptStore.endSession();                // 停止即归档这节课的转写
      await Runtime.stopKeepAlive(this.ctx!);      // 释放长时任务
      this.status = '已停止';
      this.elapsedText = '00:00';
      return;
    }
    if (!(await Runtime.requestMicPermission(this.ctx!))) {
      this.status = '启动失败：麦克风权限未授予';
      return;
    }
    try {
      // 顺序很重要：先真正开始录音，再申请长时任务。
      // 系统会校验「应用确实在执行该长时任务」，尚未录音时申请会判 9800005。
      await AsrService.start(this.ctx!);
      TranscriptStore.startSession();              // 开始一节新的转写记录
      this.running = true;
      this.elapsedText = '00:00';
      this.status = '运行中（系统识别）';
      await Runtime.startKeepAlive(this.ctx!);
      // 检测方式=服务器时才连 WS；本地模型/纯规则模式不占这条链路
      if (AppState.detectMode === AppState.DETECT_SERVER) {
        const url = AppState.effectiveServerUrl();
        if (url.length === 0) {
          // 用户没填地址就明确提示，不去连一个空/默许的地址（避免连到别人的服务器）
          this.status = '未配置服务器地址 · 请到「设置」填写，或改用本地模型检测';
        } else {
          this.ws.start(url);
        }
      } else {
        this.status = AppState.detectMode === AppState.DETECT_LLM ? '运行中（本地模型检测）' : '运行中（端侧规则检测）';
      }
    } catch (e) {
      this.running = false;
      this.status = `启动失败：${e.message ?? e}`;
    }
  }

  private ask(item: QuestionItem): void {
    LlmRunner.askFromItem(item, false);
  }

  private open(item: QuestionItem): void {
    router.pushUrl({ url: 'pages/QuestionDetail', params: { id: item.id } });
  }

  /**
   * 顶栏（**自绘，已从 HDS 回退**）：标题「知课笺」+ 右上「设置」。
   *
   * Tab 内页不能套 `HdsNavigation`（真机白屏，详见 CourseTableView.barContent 注释）。
   * 沉浸光感由 `Mat.bar()`（含 `lightEffect`）提供。
   */
  /**
   * 顶栏（自绘）。
   *
   * ## 【2026-09-28 第十二次修正 · 改为悬浮圆角胶囊】
   * 用户反馈：「听课、设置页你把胶囊的底色调没了，但是最顶上的听课还有设置，
   * 这些胶囊你都没有设置，**它还是作为两个不同的容器**。」
   *
   * → 原状：顶栏是一条**满宽实色条**（`backgroundColor(this.tpage)`，不透明），
   *   与下方卡片是**两套容器** —— 视觉上顶栏属于"页面"，卡片属于"内容"。
   * → 改法：与课表页顶栏胶囊**同一套玻璃语言**（对齐 `CourseTableView.barCapsule()`）：
   *   外层留白 + 内层圆角胶囊 + `Mat.floatGlass()`（含投影）+ 均匀薄雾 + 上缘高光。
   *
   * ⚠️ 圆角**必须开在内层**：外层若开圆角，外层 padding 区域会被算进圆角范围，
   *    圆角画在留白之外 → 胶囊看起来还是贴边的（课表页踩过这个坑）。
   * ⚠️ 薄雾层高度必须给确定值，不能写 `'100%'`（外层 Stack 无固定高度，
   *    写 100% 会把 Stack 撑到异常尺寸、内容跑到中间 —— 课表页踩过）。
   */
  @Builder
  barContent() {
    // ---- 外层：四周留白，让胶囊脱离屏幕边缘（"悬浮感"首先来自这里）----
    Row() {
      this.barCapsule()
    }
    .width('100%')
    .padding({
      left: Layout.screenMargin() - 6,
      right: Layout.screenMargin() - 6,
      top: Space.s + WindowInsets.statusBarVp(),
      bottom: Space.none,
    })
  }

  /** 顶栏胶囊本体（听课页）：圆角 + 玻璃 + 薄雾 + 上缘高光 */
  @Builder
  barCapsule() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ---- 薄雾层（垫在内容下面，高度必须给确定值）----
      // 【2026-09-28 第十五次修正】薄雾收敛回低值 —— 底色已经改用 soft 微染（见外层），
      // 这里若再叠 0.20 的近白，会把刚拉出来的底色**又冲淡回去**（等于白改）。
      // 薄雾现在的职责只剩「给材质加一层表面反光」，不再承担"造出底色"。
      Column()
        .width('100%')
        .height(this.barCapsuleH())
        .borderRadius(Radius.xl)
        .radialGradient({
          center: ['50%', '50%'] as [Length, Length],
          radius: '86%',
          colors: [
            [Theme.alphaOf(Theme.glassHighlight(), 0.12), 0.0],
            [Theme.alphaOf(Theme.glassHighlight(), 0.06), 1.0],
          ],
        })

      // ---- 内容 ----
      // 【2026-09-28 第二十一次修正 · 前景色改系统资源值以启用 colorInvert】
      //   用户要求顶栏也要像底栏那样"按背景亮度自动黑/白"，而 `colorInvert`
      //   **只认 `$r('sys.color.*')`**，硬编码的 `this.tmain` / `this.tsub` 不触发。
      //   → 标题走 `ohos_id_color_text_primary`，副文走 `ohos_id_color_text_secondary`
      //     （与官方语义一致：主文字 / 次级文字）。代价是这两行不再跟主题色走。
      Column() {
        Text('听课')
          .fontSize(FontSize.titleM)
          .fontWeight(Weight.bold)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .width('100%')
        Text('专注当下，留住每一堂课的重点')
          .fontSize(FontSize.bodyS)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .width('100%')
          .margin({ top: Space.textGap })
      }
      .width('100%')
      // 【2026-09-28 第十六次修正 · 适配统一后的 64 内高】
      //   内容两行：标题 titleM(24) + 间距 textGap(2) + 副文 bodyS(12) ≈ 40vp
      //   胶囊内高 64 - 上下各 12 = 40 → 正好放下，不再溢出。
      //   水平 padding 收到 Space.s(8)，与课表/设置页胶囊一致（原 Space.l 偏宽）。
      .padding({
        left: Space.s, right: Space.s, top: Space.m, bottom: Space.m,
      })
    }
    .width('100%')
    .borderRadius(Radius.xl)
    // 降级底 0.55：不能太淡 —— 太淡时在浅页面上读不出"这是一块板"
    // 【2026-09-28 第十六次修正 · 上一轮把透明性改没了】
    //   第十五轮写成 `mix(softColor, #FFF, 0.25)` —— **alpha 100%**，是块实色板，
    //   沉浸材质完全透不出来（用户：「为什么你的胶囊都不透明了」）。
    //   正解：**色相与不透明度分开调** ——
    //     · 色相/亮度参照 `softColor`（浅页面上也读得出边界）
    //     · 不透明度留 0.45（材质才有东西可透）
    .backgroundColor(Theme.floatGlassBase())
    .systemMaterial(Mat.floatGlass())
    .border({
      width: { top: 1, bottom: Size.divider },
      color: {
        top: Theme.glassHighlight(),
        // 【2026-09-28 第二十二次修正 · 下缘改中性灰分隔线】
        //   用户要求「容器和容器之间用一条灰色横线隔离」→ 特指顶栏胶囊下方。
        //   中性灰、不跟主题色走，三页统一（课表/听课/设置同一处改法）。
        bottom: Theme.alphaOf('#B3B3B3', 0.50),
      },
    })
  }

  /**
   * 顶栏胶囊内高（听课页）。
   *
   * 【2026-09-28 第十六次修正 · 三页统一为 64】
   * 用户反馈「第三个胶囊大小和前两个不一样」—— 查实三页确实**三个值**：
   *   · 课表 = `Size.touchTarget + Space.s*2` = 48+16 = **64**
   *   · 听课 = `(titleM24 + xs4 + bodyS12) * 1.4 + m12*2` = 56+24 = **80**
   *   · 设置 = `Size.touchTarget + Space.m*2` = 48+24 = **72**
   * 三页顶栏是同一套视觉语言，尺寸必须同构。以课表页为准统一成 64。
   *
   * ⚠️ 本页标题是**两行**（标题 + 副文），压到 64 后文字区 = 64 - 12*2 = 40vp，
   *    两行必须紧凑排布 —— 副文靠 `Space.textGap`(2) 贴住标题，且两行都用 `maxLines(1)`。
   */
  private barCapsuleH(): number {
    return Size.touchTarget + Space.s * 2;
  }

  build() {
    // 【2026-09-28 第十二次修正 · 顶栏改浮层】
    // 用户反馈顶栏与卡片"还是两个不同的容器" → 顶栏从 Column 的**兄弟节点**
    // 改成 Stack 里的**浮层**，让卡片内容能从它下方滚过去（玻璃才有东西可透）。
    // 结构对齐课表页：Stack(底层 Column 铺满 + 顶栏浮层)，滚动内容顶部让出胶囊高度。
    //
    // ⚠️ **Stack 里必须用一层 `Column` 包住 Scroll，不能直接把 Scroll 丢进 Stack**：
    //    `layoutWeight` 只对 Row/Column 的 flex 布局生效，Stack 里它**不生效** ——
    //    Scroll 拿不到宽度会缩成内容宽，整页看起来"只剩下半边"（本次踩的坑）。
    //    正确写法：Column().width('100%').height('100%') 内放 Scroll().width('100%')。
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Scroll() {
          Column() {
            // 顶栏占位：让内容从胶囊下方开始，滚到底时又能延伸进胶囊后方
            Blank().height(this.barTotalH())
          // ---- 状态卡：状态行 + 通栏液体听课键 ----
          // 【2026-10-02 改造 · 两行布局】
          // 由「图标 | 文案 | 右侧按钮」改为两行。原因不是审美：
          // 液体伸缩键要同时放下 60 的圆 + 28 的缝 + 四个字的文字块，最少约 190vp；
          // 原来那个位置在手机窄屏上只剩不到 40vp 给状态文案，「正在聆听 · 03:21」会被挤没。
          // 通栏后宽度充足（手机约 296vp），主操作也更醒目。
          Column() {
            Row() {
              // 状态插画：麦克风 + 声波（小尺寸做视觉锚点，不抢文字的语义信息）
              Image($r('app.media.ill_listening'))
                .width(Size.statusIll)
                .height(Size.statusIll)
                .objectFit(ImageFit.Contain)
                .margin({ right: Space.m })
              Column() {
                Row() {
                  Text(this.running ? '●' : '○')
                    .fontSize(FontSize.subtitleM)
                    .fontColor(Theme.sysEmphasize())
                  Text(this.running ? `正在聆听 · ${this.elapsedText}` : '准备听课')
                    .fontSize(FontSize.subtitleM)
                    .fontWeight(Weight.bold)
                    .fontColor(Theme.sysTextMain())
                    .margin({ left: Space.s })
                }
                .width('100%')
                Text(this.status)
                  .fontSize(FontSize.bodyS)
                  .fontColor(Theme.sysTextSub())
                  .width('100%')
                  .margin({ top: Space.s })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            // 主操作 —— 液体伸缩键。
            // 【2026-10-02 替换】原 `Button('开始听课', ButtonType.Capsule)` 已移除：
            // 胶囊外形和配色都保留了（同一对 `sysEmphasize` / `onEmphasize`），
            // 但内部改成两块同色液体，切换时圆融进长条、再从另一端分离出来。
            // 内部没有 `Mat.button()`：液体区是**不透明实色**（metaball 的物理要求，
            // 半透明进滤镜会被 alpha 矩阵直接吃掉），材质垫在下面根本透不出来。
            LiquidToggle({
              listening: this.running,
              liquid: this.temph,
              ink: Theme.onEmphasize(),
              labelIdle: '开始听课',
              labelActive: '停止听课',
              onToggle: () => {
                this.toggle();
              },
            })
              .width('100%')
              .margin({ top: Space.m })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(Space.l)
          .borderRadius(Radius.l)
          .backgroundColor(Theme.cardBase())
          .systemMaterial(Mat.card())

          // ---- 实时转写卡（历史保留 + 可翻动 + 自动滚底） ----
          Column() {
            Row() {
              Text('实时转写').fontSize(FontSize.subtitleM).fontWeight(Weight.bold).fontColor(Theme.sysTextMain()).layoutWeight(1)
              Text('笔记')
                .fontSize(FontSize.bodyS)
                .fontWeight(Weight.medium)
                .fontColor(Theme.sysEmphasize())
                .padding({ left: Space.s, right: Space.s, top: Space.xs, bottom: Space.xs })
                .textAlign(TextAlign.Center)
                .onClick(() => {
                  router.pushUrl({ url: 'pages/TranscriptRecords' });
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Scroll(this.scroller) {
              Column() {
                if (this.transcript.length === 0 && this.partial.length === 0) {
                  Text('（启动后自动转写，历史会保留）')
                    .fontSize(FontSize.bodyM)
                    .fontColor(Theme.sysTextSub())
                    .width('100%')
                }
                ForEach(this.transcript, (l: TranscriptLine) => {
                  Text(l.text)
                    .fontSize(FontSize.bodyM)
                    // 【2026-09-29 修正】原硬编码 '#8A8378'（暖灰褐），
                    // 是跟色系走的旧色残留，深色模式下几乎看不清。改用中性次级文字色。
                    .fontColor(Theme.sysTextSub())
                    .width('100%')
                    .margin({ top: Space.xs })
                }, (l: TranscriptLine) => `${l.ts}`)
                if (this.partial.length > 0) {
                  Text(this.partial)
                    .fontSize(FontSize.bodyL)
                    .fontWeight(Weight.bold)
                    .fontColor(Theme.sysTextMain())
                    .width('100%')
                    .margin({ top: Space.xsPlus })
                }
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
            // 转写视口高度：宽屏下 190vp 配 880vp 宽会变成"又扁又长的一条"，比例失凋。
            // 平板加高到 280vp（≈ 3:1），手机保持 190vp。
            // ⚠️ 这里必须是固定高度（不能用 constraintSize.minHeight）—— `Scroll` 要有确定高度才滚得动。
            .height(Layout.isTablet() ? 280 : 190)
            .margin({ top: Space.s })
            .padding(Space.m)
            .borderRadius(Radius.m)
            .backgroundColor(Theme.innerBase())
            .systemMaterial(Mat.tile())
            .align(Alignment.Bottom)
            .scrollBar(BarState.Auto)
            .onTouch((event: TouchEvent) => {
              // 用户手动上翻读历史时，4 秒内不自动拽回底部
              if (event.type === TouchType.Down) {
                this.holdAutoScrollUntil = Date.now() + 4000;
              }
            })

          }
          .width('100%')
          .padding(Space.l)
          .margin({ top: Space.m })
          .borderRadius(Radius.l)
          .backgroundColor(Theme.cardBase())
          .systemMaterial(Mat.card())

          // ---- 问题列表卡 ----
          Column() {
            Text('老师的问题')
              .fontSize(FontSize.subtitleM)
              .fontWeight(Weight.bold)
              .fontColor(Theme.sysTextMain())
              .width('100%')
            Text('点「垂询」让 AI 结合课堂上下文作答')
              .fontSize(FontSize.bodyS)
              .fontColor(Theme.sysTextSub())
              .width('100%')
              .margin({ top: Space.xs })

            if (this.questions.length === 0) {
              Column() {
                // 【2026-10-07 换图】原先用 `ill_empty_question`（气泡三点 + 翻开的书），
                // 但那张图在本页已同时用于「课程编辑」页的空态，同图两处不冲突、也无信息增量。
                // 换成 `ill_teacher_question`（手指 + 问号）—— 语义就是"提问"，
                // 与本卡「老师的问题」标题直接对上。
                Image($r('app.media.ill_teacher_question'))
                  .width(Size.emptyIll)
                  .height(Size.emptyIll)
                  .objectFit(ImageFit.Contain)
                  .margin({ bottom: Space.m })
                Text('启动后自动识别老师的问题与点名\n点「垂询」即可让 AI 作答')
                  .fontSize(FontSize.bodyM)
                  .fontColor(Theme.sysTextSub())
                  .textAlign(TextAlign.Center)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
              .padding(Space.l)
              .margin({ top: Space.m })
              .borderRadius(Radius.m)
              .backgroundColor(Theme.innerBase())
              .systemMaterial(Mat.tile())
            }

            ForEach(this.questions, (item: QuestionItem) => {
              Column() {
                Row() {
                  Text(item.text)
                    .fontSize(FontSize.bodyM)
                    .fontColor(Theme.sysTextMain())
                    .maxLines(2)
                    .layoutWeight(1)
                    .onClick(() => this.open(item))
                  // 【2026-09-28 第二十次修正 · 改官方胶囊按钮规范】
                  // 原来手写了 `height(Size.touchTarget)` + `padding(l/r)` + `borderRadius(Radius.full)`
                  // + `fontSize(bodyS)` —— 这一堆都是**在手工模拟官方胶囊按钮**。
                  // 官方 `Button` 有现成的形状/尺寸档：
                  //   · `ButtonType.Capsule` —— 胶囊形，圆角 = 高度的一半（不必手写 Radius.full）
                  //   · `controlSize(ControlSize.SMALL)` —— 官方小号档（圆角 14vp、走系统字号 Body_S）
                  //   · `role(ButtonRole.NORMAL)` —— 语义角色，供系统无障碍/自动语义使用
                  // 改用它们，形状与尺寸由官方规范决定，不再自己算。
                  // ⚠️ 仅**保留**项目的 `backgroundColor(this.tc)` 主题色实底与 `Mat.button()` 材质
                  //    —— 这两样是 App 主题体系的表达，官方规范不涉及，不属于"该交给官方的部分"。
                  // ⚠️ 字体色仍用 `Theme.onTheme()`：浅主题色时自动转深字（写死白色会看不见）。
                  Button(item.answering ? '垂询中…' : '垂询',
                    { type: ButtonType.Capsule, stateEffect: true })
                    .controlSize(ControlSize.SMALL)
                    .role(ButtonRole.NORMAL)
                    .fontWeight(Weight.medium)
                    .fontColor(Theme.onEmphasize())
                    .backgroundColor(Theme.sysEmphasize())
                    .systemMaterial(Mat.button())
                    .enabled(!item.answering)
                    .opacity(item.answering ? 0.5 : 1)
                    .onClick(() => {
                      if (!item.answering) {
                        this.ask(item);
                      }
                    })
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)

                if (item.answering || item.answer.length > 0) {
                  Text(item.answering && item.answer.length === 0
                    ? '等待模型回复…'
                    : (item.answering ? item.answer + ' ▌' : item.answer))
                    .fontSize(FontSize.bodyM)
                    .fontColor(Theme.sysTextMain())
                    .width('100%')
                    .margin({ top: Space.s })
                    .padding(Space.m)
                    .borderRadius(Radius.m)
                    .backgroundColor(Theme.innerBase())
                    .systemMaterial(Mat.tile())
                }

                Text(new Date(item.ts).toTimeString().substring(0, 8))
                  .fontSize(FontSize.captionL)
                  .fontColor(Theme.sysTextSub())
                  .width('100%')
                  .margin({ top: Space.xs })
                  .onClick(() => this.open(item))
              }
              .width('100%')
              .padding(Space.m)
              .margin({ top: Space.s })
              .borderRadius(Radius.m)
              .backgroundColor(Theme.innerBase())
              .systemMaterial(Mat.tile())
            }, (item: QuestionItem) => item.id.toString())
          }
          .width('100%')
          .padding(Space.l)
          .margin({ top: Space.m })
          .borderRadius(Radius.l)
          .backgroundColor(Theme.cardBase())
          .systemMaterial(Mat.card())
        }
        .width('100%')
        // ---- 宽屏内容约束（仅平板生效）----
        // 1400vp 屏上两张卡片若铺满，转写正文单行会到 1300vp，
        // 远超官方「正文单行 40~70 字符」的建议，读起来要左右甩头。
        //
        // ⚠️ 【2026-10-07 修正】必须用 `if` 守卫，不能无条件挂 `constraintSize`。
        //   ArkUI 里 `maxWidth` 没有"不限制"这个取值 —— 传 0 是"上限为零"，
        //   会把整棵内容 Column 压成 0 宽、卡片塌成竖条（用户实测截图）。
        //   这里显式只在平板挂；手机端完全不给这个约束。
        .constraintSize({ maxWidth: Layout.isTablet() ? Layout.contentMaxWidth() : 100000 })
        // ⚠️ 【2026-09-28 第十五次修正 · 致命 bug】**必须写成一次 `padding`**！
        //   ArkUI 里 `.padding()` 是**整体替换**语义，不是合并：
        //   原来这里写成两行 —— `.padding(Layout.screenMargin())` 紧跟
        //   `.padding({ bottom: Size.barClearanceMin })` —— 后者的 left/right 未指定即归零，
        //   于是**左右边距被整个抹掉**。后果：
        //     · 所有卡片贴死屏幕左右边缘；
        //     · 问题列表里 `Text(layoutWeight 1)` + `Button` 的 Row 失去呼吸位，
        //       按钮被顶到屏幕最右侧、只露一半（用户截图里的「垂询」）。
        //   → 合并为单次调用，四个方向一次性给全。
        .padding({
          left: Layout.screenMargin(),
          right: Layout.screenMargin(),
          // 底部内边距：给悬浮胶囊让出空间，最末内容仍能滚进胶囊后方让材质透出颜色
          bottom: Size.barClearanceMin,
        });
      }
      .scrollBar(BarState.Auto)
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')

      // 顶栏浮层：浮在滚动内容之上，材质才有东西可透
      this.barContent()
    }
    .width('100%')
    .height('100%')
    // 外层兜底底色：内层若因任何原因没撑满，下方不会露出透明区域
    .backgroundColor(Theme.sysPage())
  }

  /**
   * 胶囊**总占位高度** —— 滚动内容需要让出的顶部空间。
   * 与课表页 `barTotalH()` 同构：状态栏 + 上留白 + 胶囊内高 + 下留白。
   * ⚠️ 必须精确：少算 → 第一张卡被胶囊盖住；多算 → 顶部凭空多一段空白。
   *
   * 【2026-09-28 第十五次修正】下侧余量 `Space.s`(8) → `Space.l`(16)，
   * 与设置页同步（原因见 Settings.barTotalH 注释）。
   */
  private barTotalH(): number {
    return WindowInsets.statusBarVp() + Space.s + this.barCapsuleH() + Space.l;
  }
}
