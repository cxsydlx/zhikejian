import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Theme } from '../common/Theme';
import { TranscriptStore, TrSession } from '../common/TranscriptStore';
import { ShareService, ShareKind } from '../service/ShareService';
import { Mat } from '../common/Material';
import { WindowInsets } from '../common/WindowInsets';
import { FontSize, Weight, Space, Radius, Size, Motion, Layout } from '../common/DesignToken';

/**
 * 转写笔记页：
 *   ① 本次转写 → 「一键整理」调用 LLM 生成结构化课堂笔记（流式显示，整理结果保存到该记录）；
 *   ② 历史记录 → 每节课一份，可查看（优先显示笔记，附原始转写）、可删除、可导出、可碰一碰分享。
 *
 * 主题走「@State 镜像 + Theme.onChange」模式（本项目铁律：只写不读的状态不会触发重绘）。
 *
 * 碰一碰：本页注册的监听会把「当前正在查看的那一份」设为发送源
 * （点某条记录的「碰一碰」→ 标记该 id → 两台设备碰一下即发送）。
 */
@Entry
@Component
struct TranscriptRecords {
  @State tc: string = Theme.themeColor();
  @State tacc: string = Theme.accentColor();
  @State tsoft: string = Theme.softColor();
  @State tpage: string = Theme.pageColor();
  @State ton: string = Theme.onTheme();
  @State tmain: string = Theme.textMain();
  @State tsub: string = Theme.textSub();

  @State curCount: number = 0;
  @State sessions: TrSession[] = [];
  @State summary: string = '';
  @State busy: boolean = false;
  @State tip: string = '';
  @State openId: string = '';
  @State openText: string = '';
  /** 碰一碰是否就绪 */
  @State shareOn: boolean = false;
  /** 碰一碰状态 / 分享目标提示 */
  @State shareStatus: string = '';

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
    TranscriptStore.onChange(() => {
      this.pull();
    });
    this.pull();
  }

  /**
   * 碰一碰监听在**页面可见时**才注册，隐藏即注销（同设置页口径）：
   * 避免用户不在本页时误碰触发、避免重复注册导致一次碰触多次回调。
   */
  onPageShow(): void {
    this.enableKnock('');
  }

  onPageHide(): void {
    ShareService.unregisterKnock();
    this.shareOn = false;
    this.shareStatus = '';
  }

  /** 开启碰一碰（预置发送源：空串 = 当前会话，否则 = 指定历史记录） */
  private enableKnock(sessionId: string): void {
    ShareService.setPendingSource(ShareKind.TRANSCRIPT, sessionId);
    const ctx = getContext(this) as common.UIAbilityContext;
    ShareService.registerKnock(ctx, (text: string) => {
      this.shareStatus = text;
    }).then((ok: boolean) => {
      this.shareOn = ok;
    });
  }

  /** 点某条记录的「碰一碰」：重设发送源并给明确反馈 */
  private knockFor(s: TrSession): void {
    this.enableKnock(s.id);
    if (!this.shareOn) {
      promptAction.showToast({ message: '这台设备不支持碰一碰', duration: 2000 });
      return;
    }
    promptAction.showToast({
      message: `已就绪：两台设备顶部碰一下，发送「${s.title}」`,
      duration: 3000,
    });
  }

  /** 从存储拉取（当前会话 + 历史列表） */
  private pull(): void {
    this.sessions = TranscriptStore.list();
    const c = TranscriptStore.current;
    this.curCount = c == null ? 0 : c.lines.length;
    if (this.openId.length > 0) {
      const s = TranscriptStore.find(this.openId);
      this.openText = s == null ? '' : this.plainOf(s);
    }
  }

  private plainOf(s: TrSession): string {
    let out = '';
    if (s.summary.length > 0) {
      out += s.summary + '\n\n———— 原始转写 ————\n';
    }
    const arr: string[] = [];
    for (const l of s.lines) {
      arr.push(l.text);
    }
    return out + arr.join('\n');
  }

  private copy(text: string): void {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      this.tip = '已复制到剪贴板';
    }).catch(() => {
      this.tip = '复制失败';
    });
  }

  /** 一键整理当前这节课的转写 */
  private doSummarizeCurrent(): void {
    if (this.busy) {
      return;
    }
    if (this.curCount === 0) {
      this.tip = '本次转写还没有内容';
      return;
    }
    this.busy = true;
    this.summary = '正在用大模型整理这节课的转写…';
    let acc = '';
    TranscriptStore.summarize('', (delta: string) => {
      acc += delta;
      this.summary = acc;
    }, (err: string) => {
      this.busy = false;
      if (err.length > 0) {
        this.tip = `整理失败：${err}`;
        if (acc.length === 0) {
          this.summary = '';
        }
      } else {
        this.tip = '整理完成，已保存到这次记录';
      }
    });
  }

  /** 整理某条历史记录 */
  private doSummarize(id: string): void {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.tip = '';
    let acc = '';
    TranscriptStore.summarize(id, (delta: string) => {
      acc += delta;
      this.openText = acc;
    }, (err: string) => {
      this.busy = false;
      if (err.length > 0) {
        this.tip = `整理失败：${err}`;
      } else {
        this.tip = '整理完成';
      }
    });
  }

  // ---------- 导出 ----------

  private pickSession(id: string): TrSession | null {
    return id.length === 0 ? TranscriptStore.current : TranscriptStore.find(id);
  }

  /**
   * 导出当前/指定记录。
   * @param kind doc(Word 兼容) | md | txt | json
   */
  private async exportAs(id: string, kind: string): Promise<void> {
    const s = this.pickSession(id);
    if (s == null || (s.lines.length === 0 && s.summary.length === 0)) {
      this.tip = '还没有可导出的转写';
      return;
    }
    let content = '';
    let name = '';
    const stamp = this.stampOf(s);
    if (kind === 'doc') {
      content = this.buildDocHtml(s, true);
      name = `知课笺-${this.safeName(s.title)}-${stamp}.doc`;
    } else if (kind === 'md') {
      content = this.buildMarkdown(s, true);
      name = `知课笺-${this.safeName(s.title)}-${stamp}.md`;
    } else if (kind === 'txt') {
      content = this.buildPlain(s, true);
      name = `知课笺-${this.safeName(s.title)}-${stamp}.txt`;
    } else {
      content = this.buildJson(s);
      name = `知课笺-${this.safeName(s.title)}-${stamp}.json`;
    }
    try {
      const p = new picker.DocumentViewPicker(this.getUIContext().getHostContext() as common.UIAbilityContext);
      const opt = new picker.DocumentSaveOptions();
      opt.newFileNames = [name];
      const uris = await p.save(opt);
      if (uris == null || uris.length === 0) {
        return;
      }
      const file = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, content);
      } finally {
        fs.closeSync(file);
      }
      this.tip = '已导出：' + name;
    } catch (e) {
      const err = e as BusinessError;
      this.tip = `导出失败：${err.message ?? err}`;
    }
  }

  /** 批量导出：所有历史记录合成一份 Markdown */
  private async exportAllMarkdown(): Promise<void> {
    if (this.sessions.length === 0) {
      this.tip = '还没有历史记录';
      return;
    }
    const parts: string[] = [];
    parts.push(`# 知课笺 · 课堂笔记汇总\n`);
    parts.push(`导出时间：${new Date().toLocaleString()}\n`);
    parts.push(`共 ${this.sessions.length} 次记录\n`);
    for (const s of this.sessions) {
      parts.push('\n---\n');
      parts.push(this.buildMarkdown(s, true));
    }
    const stamp = this.stampNow();
    const name = `知课笺-课堂笔记汇总-${stamp}.md`;
    try {
      const p = new picker.DocumentViewPicker(this.getUIContext().getHostContext() as common.UIAbilityContext);
      const opt = new picker.DocumentSaveOptions();
      opt.newFileNames = [name];
      const uris = await p.save(opt);
      if (uris == null || uris.length === 0) {
        return;
      }
      const file = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, parts.join('\n'));
      } finally {
        fs.closeSync(file);
      }
      this.tip = `已导出：${name}（${this.sessions.length} 份）`;
    } catch (e) {
      const err = e as BusinessError;
      this.tip = `导出失败：${err.message ?? err}`;
    }
  }

  /** Markdown：笔记在前，原始转写附后 */
  private buildMarkdown(s: TrSession, withSummary: boolean): string {
    let out = `## ${s.title}\n\n`;
    out += `> 时间：${this.timeOf(s)}　共 ${s.lines.length} 句　时长 ${s.durationText()}\n\n`;
    if (withSummary && s.summary.length > 0) {
      out += s.summary + '\n\n### 原始转写\n\n';
    }
    for (const l of s.lines) {
      out += `- ${l.text}\n`;
    }
    return out;
  }

  /** 纯文本 */
  private buildPlain(s: TrSession, withSummary: boolean): string {
    let out = `${s.title}\n时间：${this.timeOf(s)}　共 ${s.lines.length} 句\n\n`;
    if (withSummary && s.summary.length > 0) {
      out += `${s.summary}\n\n———— 原始转写 ————\n`;
    }
    for (const l of s.lines) {
      out += `${l.text}\n`;
    }
    return out;
  }

  /** 结构化 JSON（含摘要与逐句时间） */
  private buildJson(s: TrSession): string {
    const arr: Array<Record<string, Object>> = [];
    for (const l of s.lines) {
      arr.push({ 'text': l.text, 'ts': l.ts } as Record<string, Object>);
    }
    const root: Record<string, Object> = {
      'app': '知课笺',
      'exportedAt': new Date().toISOString(),
      'title': s.title,
      'startMs': s.startMs,
      'endMs': s.endMs,
      'durationText': s.durationText(),
      'summary': s.summary,
      'lines': arr,
    };
    return JSON.stringify(root, null, 2);
  }

  /** 生成 Word 兼容 HTML */
  private buildDocHtml(s: TrSession, withSummary: boolean): string {
    const meta = `${this.timeOf(s)}　共 ${s.lines.length} 句　时长 ${s.durationText()}`;
    let out = '<html xmlns:o="urn:schemas-microsoft-com:office:office" '
      + 'xmlns:w="urn:schemas-microsoft-com:office:word" '
      + 'xmlns="http://www.w3.org/TR/REC-html40">'
      + '<head><meta charset="utf-8"><title>' + this.esc(s.title) + '</title>'
      + '<style>body{font-family:\'Microsoft YaHei\',sans-serif;font-size:11pt;line-height:1.75;color:#1C1917;}'
      + 'h1{font-size:16pt;}h2{font-size:13pt;margin-top:14pt;}p{margin:0 0 6pt 0;}'
      + '.meta{color:#78716C;font-size:9.5pt;}</style></head><body>'
      + '<h1>' + this.esc(s.title) + '</h1>'
      + '<p class="meta">' + meta + '</p>';
    if (withSummary && s.summary.length > 0) {
      out += '<h2>课堂笔记（AI 整理）</h2>';
      for (const line of s.summary.split('\n')) {
        if (line.trim().length === 0) {
          continue;
        }
        out += '<p>' + this.esc(line) + '</p>';
      }
      out += '<h2>原始转写</h2>';
    }
    for (const l of s.lines) {
      out += '<p>' + this.esc(l.text) + '</p>';
    }
    out += '</body></html>';
    return out;
  }

  private esc(t: string): string {
    return t.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  /** 文件名里不能出现的字符替换掉 */
  private safeName(t: string): string {
    const s = t.replace(/[\\/:*?"<>|\s]+/g, '_');
    return s.length > 0 ? s : '课堂笔记';
  }

  private timeOf(s: TrSession): string {
    const d = new Date(s.startMs);
    const mm = (d.getMonth() + 1).toString().padStart(2, '0');
    const dd = d.getDate().toString().padStart(2, '0');
    const hh = d.getHours().toString().padStart(2, '0');
    const mi = d.getMinutes().toString().padStart(2, '0');
    return `${mm}-${dd} ${hh}:${mi}`;
  }

  private stampOf(s: TrSession): string {
    const d = new Date(s.startMs);
    const mm = (d.getMonth() + 1).toString().padStart(2, '0');
    const dd = d.getDate().toString().padStart(2, '0');
    const hh = d.getHours().toString().padStart(2, '0');
    const mi = d.getMinutes().toString().padStart(2, '0');
    return `${mm}${dd}-${hh}${mi}`;
  }

  private stampNow(): string {
    return this.stampOf(new TrSession('', '', Date.now()));
  }

  // ---------- UI ----------

  /**
   * 自绘顶栏。
   *
   * ⚠️ 撤掉 `HdsNavigation` 的原因：`canIUse('SystemCapability.UIDesign.HDSComponent.Core')`
   * 返回 true，但 `HdsNavigation() { ... }` 的内容子树在本工程设备上**永不渲染**（全白屏），
   * 已用最小复现页证实。故顶栏改自绘，视觉规格与
   * `ThemeSettings.barContent()` / `CourseEdit.barContent()` 完全一致
   * （主题色满铺 + `Size.bar` 高度 + 状态栏避让 + 右上白底胶囊），路由页之间跳转不会"跳一下"。
   *
   * title / subTitle 原值照搬自改造前的 `hdsBar()`：
   *   title    = '转写笔记'
   *   subTitle = '碰一碰就绪'（仅 `this.shareOn` 为真时显示）
   * 无 menu（原顶栏只有「返回键 + 标题 + 副标题」，碰一碰徽标降级为副标题）。
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

      // 标题 + 副标题
      Column() {
        Text('转写笔记')
          .fontSize(FontSize.titleS)
          .fontWeight(Weight.bold)
          .fontColor(this.ton)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.shareOn) {
          Text('碰一碰就绪')
            .fontSize(FontSize.captionL)
            .fontColor(Theme.mix(this.ton, this.tc, 0.45))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: Space.textGap })
        }
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
  currentCard() {
    Column() {
      Row() {
        Text(`本次转写 · ${this.curCount} 句`)
          .fontSize(FontSize.subtitleM)
          .fontWeight(Weight.bold)
          .fontColor(Theme.sysTextMain())
          .layoutWeight(1);
        Text('导出')
          .fontSize(FontSize.subtitleS)
          .fontWeight(Weight.medium)
          .fontColor(Theme.sysEmphasize())
          .textAlign(TextAlign.Center)
          .padding({ left: Space.m, right: Space.m, top: Space.xs, bottom: Space.xs })
          .margin({ right: Space.s })
          .borderRadius(Radius.full)
          .backgroundColor(Theme.mix(this.tsoft, '#FFFFFF', 0.5))
          .systemMaterial(Mat.tile())
          .onClick(() => {
            this.exportMenu('');
          });
        Text(this.busy ? '整理中…' : '一键整理')
          .fontSize(FontSize.subtitleS)
          .fontWeight(Weight.medium)
          .fontColor(Theme.onEmphasize())
          .textAlign(TextAlign.Center)
          .padding({ left: Space.l, right: Space.l })
          .constraintSize({ minHeight: Size.touchTarget })
          .borderRadius(Radius.full)
          .backgroundColor(Theme.sysEmphasize())
          .systemMaterial(Mat.button())
          .onClick(() => {
            this.doSummarizeCurrent();
          });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      if (this.summary.length > 0) {
        Text(this.summary)
          .fontSize(FontSize.bodyM)
          .fontColor(Theme.sysTextMain())
          .width('100%')
          .padding({ top: Space.m })
          .onClick(() => {
            this.copy(this.summary);
          });
      } else {
        Text('停止转写后会自动保存成本次记录；点「一键整理」让大模型把它整理成结构化笔记。')
          .fontSize(FontSize.bodyS)
          .fontColor(Theme.sysTextSub())
          .width('100%')
          .padding({ top: Space.m });
      }
    }
    .width('100%')
    .padding(Space.l)
    .margin({ top: Space.m })
    .borderRadius(Radius.l)
    .backgroundColor(Theme.sysCard())
    .systemMaterial(Mat.card())
    .alignItems(HorizontalAlign.Start);
  }

  /** 导出格式选择（自绘底部弹层，不依赖系统菜单） */
  @State exportFor: string = '';
  @State exportMenuShow: boolean = false;

  private exportMenu(id: string): void {
    this.exportFor = id;
    this.exportMenuShow = true;
  }

  @Builder
  exportPanel() {
    Column() {
      Column() {
        Text('导出格式')
          .fontSize(FontSize.subtitleL)
          .fontWeight(Weight.bold)
          .fontColor(Theme.sysTextMain())
          .width('100%');
        Text('选好后在系统「保存」对话框里选目录即可。')
          .fontSize(FontSize.bodyS)
          .fontColor(Theme.sysTextSub())
          .width('100%')
          .margin({ top: Space.s });

        Row() {
          this.exportChoice('Word 文档（.doc）', '在 Word / WPS 里打开，可继续编辑', 'doc');
        }
        .width('100%')
        .margin({ top: Space.m });
        Row() {
          this.exportChoice('Markdown（.md）', '纯文本带格式标记，适合二次整理', 'md');
        }
        .width('100%')
        .margin({ top: Space.s });
        Row() {
          this.exportChoice('纯文本（.txt）', '最通用，任何设备都能看', 'txt');
        }
        .width('100%')
        .margin({ top: Space.s });
        Row() {
          this.exportChoice('JSON（.json）', '含逐句时间戳，适合程序处理', 'json');
        }
        .width('100%')
        .margin({ top: Space.s });

        Row() {
          Text('取消')
            .fontSize(FontSize.subtitleS)
            .fontWeight(Weight.medium)
            .fontColor(Theme.sysTextSub())
            .textAlign(TextAlign.Center)
            .padding({ top: Space.xs, bottom: Space.xs })
            .layoutWeight(1)
            .borderRadius(Radius.full)
            .backgroundColor(Theme.mix(this.tsoft, '#FFFFFF', 0.5))
            .systemMaterial(Mat.tile())
            .onClick(() => {
              this.exportMenuShow = false;
            });
        }
        .width('100%')
        .margin({ top: Space.l });
      }
      .width('88%')
      .padding(Space.xl)
      .borderRadius(Radius.xl)
      .backgroundColor(Theme.sysCard())
      .systemMaterial(Mat.sheet())
      .alignItems(HorizontalAlign.Start);
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#00000055')
    .transition(Motion.fadeIn());
  }

  @Builder
  exportChoice(title: string, desc: string, kind: string) {
    Column() {
      Text(title)
        .fontSize(FontSize.subtitleM)
        .fontColor(Theme.sysTextMain());
      Text(desc)
        .fontSize(FontSize.bodyS)
        .fontColor(Theme.sysTextSub())
        .margin({ top: Space.textGap });
    }
    .width('100%')
    .padding(Space.m)
    .constraintSize({ minHeight: Size.touchTarget })
    .borderRadius(Radius.m)
    .backgroundColor(Theme.mix(this.tsoft, '#FFFFFF', 0.5))
    .systemMaterial(Mat.tile())
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.exportMenuShow = false;
      this.exportAs(this.exportFor, kind);
    });
  }

  @Builder
  historyCard() {
    Column() {
      Row() {
        // 【2026-10-07 接入 ill_note_chat】标题左侧加一张小笔记插画。
        // 这个页面产出的是"课堂笔记"，但原来标题只有四个字，没有任何东西
        // 表明它和「笔记」有关（听课页的「笔记」入口就是跳到这里）。
        // 尺寸取 statusIll（44vp），和小徽标一个量级，不挤压右侧的「全部导出」。
        Image($r('app.media.ill_note_chat'))
          .width(Size.statusIll)
          .height(Size.statusIll)
          .objectFit(ImageFit.Contain)
          .margin({ right: Space.s })
        Text('历史记录')
          .fontSize(FontSize.subtitleM)
          .fontWeight(Weight.bold)
          .fontColor(Theme.sysTextMain())
          .layoutWeight(1);
        if (this.sessions.length > 0) {
          Text('全部导出（Markdown）')
            .fontSize(FontSize.subtitleS)
            .fontWeight(Weight.medium)
            .fontColor(Theme.sysEmphasize())
            .textAlign(TextAlign.Center)
            .padding({ left: Space.s, right: Space.s })
            .constraintSize({ minHeight: Size.touchTarget })
            .onClick(() => {
              this.exportAllMarkdown();
            });
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      if (this.sessions.length === 0) {
        Column() {
          // 【2026-10-07 换图】原先用 `ill_listening`（声波 + 麦克风），
          // 但那张图在「听课」页状态卡里已经在用，同图两处。
          // 换成 `ill_mic_stand`（麦克风架静置）—— "架着但没在录" 就是"还没有历史记录"，
          // 比声波图更贴合空态语义。
          Image($r('app.media.ill_mic_stand'))
            .width(Size.emptyIll)
            .height(Size.emptyIll)
            .objectFit(ImageFit.Contain)
            .margin({ bottom: Space.l })
          Text('还没有历史记录。每次停止转写都会自动保存一节。')
            .fontSize(FontSize.bodyM)
            .fontColor(Theme.sysTextSub())
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ top: Space.xl, bottom: Space.m });
      }

      ForEach(this.sessions, (s: TrSession) => {
        Column() {
          Row() {
            Column() {
              Text(s.title)
                .fontSize(FontSize.subtitleM)
                .fontColor(Theme.sysTextMain())
                .width('100%');
              Text(`${s.lines.length} 句 · ${s.durationText()}${s.summary.length > 0 ? ' · 已整理' : ''}`)
                .fontSize(FontSize.bodyS)
                .fontColor(Theme.sysTextSub())
                .width('100%')
                .margin({ top: Space.textGap });
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start);

            Text('删除')
              .fontSize(FontSize.subtitleS)
              .fontWeight(Weight.medium)
              .fontColor(Theme.danger())
              .textAlign(TextAlign.Center)
              .padding({ left: Space.m, right: Space.m })
              .constraintSize({ minHeight: Size.touchTarget })
              .onClick(() => {
                TranscriptStore.delete(s.id);
                if (this.openId === s.id) {
                  this.openId = '';
                  this.openText = '';
                }
              });
          }
          .width('100%')
          .constraintSize({ minHeight: Size.touchTarget })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            if (this.openId === s.id) {
              this.openId = '';
              this.openText = '';
            } else {
              this.openId = s.id;
              const full = TranscriptStore.find(s.id);
              this.openText = full == null ? '' : this.plainOf(full);
            }
          });

          if (this.openId === s.id) {
            Text(this.openText)
              .fontSize(FontSize.bodyM)
              .fontColor(Theme.sysTextMain())
              .width('100%')
              .padding({ top: Space.m });
            Row() {
              Text('复制')
                .fontSize(FontSize.subtitleS)
                .fontWeight(Weight.medium)
                .fontColor(Theme.sysEmphasize())
                .textAlign(TextAlign.Center)
                .padding({ left: Space.m, right: Space.m })
                .constraintSize({ minHeight: Size.touchTarget })
                .onClick(() => {
                  this.copy(this.openText);
                });
              Text(s.summary.length > 0 ? '重新整理' : '用大模型整理')
                .fontSize(FontSize.subtitleS)
                .fontWeight(Weight.medium)
                .fontColor(Theme.sysEmphasize())
                .textAlign(TextAlign.Center)
                .padding({ left: Space.m, right: Space.m })
                .constraintSize({ minHeight: Size.touchTarget })
                .onClick(() => {
                  this.doSummarize(s.id);
                });
              Text('导出')
                .fontSize(FontSize.subtitleS)
                .fontWeight(Weight.medium)
                .fontColor(Theme.sysEmphasize())
                .textAlign(TextAlign.Center)
                .padding({ left: Space.m, right: Space.m })
                .constraintSize({ minHeight: Size.touchTarget })
                .onClick(() => {
                  this.exportMenu(s.id);
                });
              Text('碰一碰发送')
                .fontSize(FontSize.subtitleS)
                .fontWeight(Weight.medium)
                .fontColor(this.shareOn ? Theme.sysEmphasize() : Theme.sysTextSub())
                .textAlign(TextAlign.Center)
                .padding({ left: Space.m, right: Space.m })
                .constraintSize({ minHeight: Size.touchTarget })
                .onClick(() => {
                  this.knockFor(s);
                });
            }
            .width('100%')
            .padding({ top: Space.s })
            .alignItems(VerticalAlign.Center);
          }
        }
        .width('100%')
        .padding({ top: Space.m, bottom: Space.m })
        .border({
          width: { bottom: Size.divider },
          color: Theme.sysSeparator(),
        })
        .alignItems(HorizontalAlign.Start);
      }, (s: TrSession) => `s-${s.id}-${s.summary.length}-${this.openId === s.id ? 1 : 0}`);
    }
    .width('100%')
    .padding(Space.l)
    .margin({ top: Space.m, bottom: Space.xxl })
    .borderRadius(Radius.l)
    .backgroundColor(Theme.sysCard())
    .alignItems(HorizontalAlign.Start);
  }

  build() {
    // Stack 必须保留：exportPanel() 是靠它盖在内容之上的浮层
    Stack() {
      Column() {
        this.barContent()

        Scroll() {
          Column() {
            if (this.tip.length > 0) {
              Text(this.tip)
                .fontSize(FontSize.bodyM)
                .fontWeight(Weight.medium)
                .fontColor(this.ton)
                .width('100%')
                .padding({ left: Space.m, right: Space.m, top: Space.m, bottom: Space.m })
                .borderRadius(Radius.m)
                .backgroundColor(this.tacc)
                .margin({ top: Space.m });
            }
            if (this.shareStatus.length > 0) {
              Text(this.shareStatus)
                .fontSize(FontSize.bodyS)
                .fontColor(Theme.sysTextSub())
                .width('100%')
                .padding({ left: Space.m, right: Space.m, top: Space.s, bottom: Space.s });
            }
            this.currentCard();
            this.historyCard();
          }
          .width('100%')
          .padding({ left: Layout.screenMargin(), right: Layout.screenMargin() });
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
        .align(Alignment.Top);
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.sysPage());

      if (this.exportMenuShow) {
        this.exportPanel();
      }
    }.transition(Motion.pageEnter())
    .width('100%')
    .height('100%');
  }
}
