/**
 * 词典页 —— 第 4 个 Tab（2026-10-10新增）
 *
 * ## 结构来源：抄Settings 页的**浮层版**骨架
 * 用 `Settings.ets:2468-2545` 那套 `Stack(TopStart){ Column{Scroll}; barContent() }`，
 * **不是** `TranscriptRecords` 那套 —— 因为词典在 Tab 内，需要沉浸材质透出滚动内容。
 *
 * ## 必守的三个坑（都是从工程血泪里学来的）
 * ① `Blank().height(barTotalH())` 必须在 **Scroll 内容里**，不能是 Scroll 的兄弟。
 *    兄弟 Blank 是实体、永久占位 → 视口被推下去 → 内容永远进不了胶囊区域，
 *    材质「没东西可透」，等于不做材质（`Settings.ets:2478-2496` 的修正记录）。
 * ② Stack 里必须用一层 `Column` 包住 Scroll，否则 `layoutWeight` 不生效、
 *    Scroll 拿不到宽度会缩成内容宽（`ListenView.ets:321-324` 的记录）。
 * ③ 薄雾层必须给**确定高度**，写 '100%' 会去解析尚不存在的父高度 → Stack 撑爆。
 *
 * ## 查词流程
 *   输入 → 本地命中？（DictStore）→ 未命中则打服务端 → 命中则存进本地
 * 联网优先、本地兜底：离线也能查最近查过的词。
 */

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction } from '@kit.ArkUI';
import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppState } from '../common/AppState';
import { Theme } from '../common/Theme';
import { Mat } from '../common/Material';
import { WindowInsets } from '../common/WindowInsets';
import { Layout, FontSize, Weight, Space, Radius, Size, Motion } from '../common/DesignToken';
import { DictStore, StoredWord } from '../common/DictStore';
import {
  DictionaryClient, DictResult, dictAudioUrl
} from '../service/DictionaryClient';

const TAG: string = 'DictView';

@Component
export struct DictView {
  // ---- 主题镜像（ArkUI 只观察「渲染中读过」的状态，必须镜像成 @State）----
  @State tc: string = Theme.themeColor();
  @State tsoft: string = Theme.softColor();
  @State tpage: string = Theme.pageColor();
  @State ton: string = Theme.onTheme();
  @State tmain: string = Theme.textMain();
  @State tsub: string = Theme.textSub();

  @State query: string = '';
  @State busy: boolean = false;
  @State status: string = '';
  @State curWord: string = '';
  @State ipa: string = '';
  @State posZh: string = '';
  @State glosses: string[] = [];
  // ---- 中文释义 / 考纲标签 / 星级（2026-10-10 补）----
  // ⚠️ 这三个字段之前**根本没声明也没读**，导致查词只显示英文释义。
  //   服务端自 v1.1.0 起就会返回 definitionZh / tags / collins。
  @State zhLines: string[] = [];
  @State tags: string[] = [];
  @State collins: number = 0;
  @State source: string = '';
  @State userDef: string = '';
  @State userDefAt: number = 0;
  @State fromLocal: boolean = false;
  @State history: StoredWord[] = [];

  // 改写释义浮层
  @State showEdit: boolean = false;
  @State editText: string = '';
  @State editNote: string = '';
  @State editAgree: boolean = false;
  @State submitting: boolean = false;

  private ctx: common.UIAbilityContext | undefined = getContext(this) as common.UIAbilityContext;
  private player: media.AVPlayer | undefined = undefined;

  aboutToAppear(): void {
    Layout.init();
    Mat.init();
    WindowInsets.sync();
    Theme.onChange(() => {
      this.tc = Theme.themeColor();
      this.tsoft = Theme.softColor();
      this.tpage = Theme.pageColor();
      this.ton = Theme.onTheme();
      this.tmain = Theme.textMain();
      this.tsub = Theme.textSub();
    });
    DictStore.onChange(() => {
      this.history = DictStore.recent(10);
    });
    this.history = DictStore.recent(10);
    if (this.ctx !== undefined) {
      DictStore.init(this.ctx);
    }
    // 恢复上次查的词，让页面不空着
    const last: StoredWord[] = DictStore.recent(1);
    if (last.length > 0) {
      this.show(last[0]);
    }
  }

  aboutToDisappear(): void {
    // ⚠️ **不要在这里释放播放器**。
    //实测日志显示：`url set → initialized` 之后紧跟一条 `released` ——
    //   就是 aboutToDisappear 把实例释放了。而 `prepare()` 是**异步**的，
    //   释放发生在它完成之前 → 竞态，某些时机下播放会被打断。
    //   单词发音只有约 0.8 秒，让它自然播完更合理；
    //   实例泄漏由"下次播放前先releasePlayer()"兜住（见 play()）。
  }

  // ================= 查词 =================

  private doSearch(): void {
    const w: string = this.query.trim().toLowerCase();
    if (w.length === 0) {
      return;
    }
    this.releasePlayer();
    // 先看本地有没有 —— 有就直接显示，秒回
    const local: StoredWord | undefined = DictStore.find(w);
    if (local !== undefined) {
      this.show(local);
      // 本地有的仍尝试刷新一次（拿服务端可能更新过的释义），但**不阻塞显示**
      this.fetchRemote(w, true);
      return;
    }
    this.fetchRemote(w, false);
  }

  private fetchRemote(word: string, silent: boolean): void {
    this.busy = true;
    if (!silent) {
      this.status = '查询中…';
    }
    DictionaryClient.lookup(word, (r: DictResult) => {
      this.busy = false;
      if (!r.found) {
        this.status = `未找到 ${word}`;
        if (!silent) {
          this.clearResult();
        }
        return;
      }
      this.applyResult(r);
      DictStore.saveResult(r);
    }, (msg: string) => {
      this.busy = false;
      // 静默失败不打扰：本地已经显示了
      if (!silent) {
        this.status = msg;
      }
    });
  }

  private applyResult(r: DictResult): void {
    this.clearResult();
    this.curWord = r.word;
    this.status = '';
    this.fromLocal = false;
    if (r.entry != null) {
      this.ipa = r.entry.ipa;
      this.posZh = r.entry.posLabelZh.length > 0 ? r.entry.posLabelZh : r.entry.posLabel;
      this.source = r.entry.source;
      // ---- 中文释义 + 考纲标签 + 星级（2026-10-10 补）----
      // ⚠️ 之前这里**只取了英文释义**，导致词典页查出来只有英文、没有中文 ——
      //    服务端 v1.1.0 就已经返回 definitionZh 了，是客户端漏读。
      this.zhLines = DictView.splitLines(r.entry.definitionZh);
      this.tags = r.entry.tags;
      this.collins = r.entry.collins;
      for (const s of r.entry.senses) {
        this.glosses.push(s.gloss);
      }
    }
    if (r.userEdit != null) {
      this.userDef = r.userEdit.definition;
      this.userDefAt = r.userEdit.createdAt;
    }
  }

  private show(w: StoredWord): void {
    this.clearResult();
    this.curWord = w.word;
    this.ipa = w.ipa;
    this.posZh = w.posZh;
    this.source = w.source;
    // ---- 中文释义等（离线也要显示，不能只有英文）----
    this.zhLines = DictView.splitLines(w.defZh);
    this.tags = w.tags;
    this.collins = w.collins;
    for (const g of w.glosses) {
      this.glosses.push(g);
    }
    this.userDef = w.userDef;
    this.userDefAt = w.userDefAt;
    this.fromLocal = true;
    this.status = '';
  }

  /**
   * 把服务端的多行中文释义拆成行。
   *
   * ⚠️ 服务端返回的是**带真换行**的字符串（"n. 电脑\n[计] 计算机"）——
   *   导入侧已修过字面 `\n` 的问题（见字典站 import_ecdict.py）。
   *   这里按真换行 split，并清掉可能残留的空行与首尾空白。
   */
  private static splitLines(def: string): string[] {
    const out: string[] = [];
    if (def.length === 0) {
      return out;
    }
    const parts: string[] = def.split('\n');
    for (const p of parts) {
      const t: string = p.trim();
      if (t.length > 0) {
        out.push(t);
      }
    }
    return out;
  }

  /**
   * 取出中文释义行开头的词性标记。
   *
   * ECDICT 的释义形如：
   *   `n. 水, 雨水, 海水`/ `vt. 用打字机打` / `[计] 类型; 键入`
   * 前缀两类：① 方括号类（`[计]` `[医]` `[网络]`）② 词性缩写+点（`n.` `vt.` `a.` …）。
   * 匹配失败返回空串 —— 此时整行都当释义正文。
   */
  private static posTagOf(line: string): string {
    const m: RegExpMatchArray | null = line.match(
      /^(\[[^\]]{1,6}\]|(?:vt|vi|vs|n|a|ad|adv|r|v|pron|prep|conj|num|art|int|aux|abbr)\.)/
    );
    return m == null ? '' : m[1];
  }

  /** 去掉词性标记，只留释义正文 */
  private static stripPosTag(line: string): string {
    const tag: string = DictView.posTagOf(line);
    return tag.length > 0 ? line.substring(tag.length).trim() : line;
  }

  private clearResult(): void {
    this.curWord = '';
    this.ipa = '';
    this.posZh = '';
    this.glosses = [];
    // ⚠️ 中文相关字段也要清 —— 否则查下一个词时会残留上一个词的中文
    this.zhLines = [];
    this.tags = [];
    this.collins = 0;
    this.source = '';
    this.userDef = '';
    this.userDefAt = 0;
    this.fromLocal = false;
  }

  // ================= 发音 =================

  /**
   * 播放英音或美音 —— 服务端 espeak-ng 合成，本地不存音频文件。
   *
   * 用 `AVPlayer`（可直接播 URL）而不是 `AudioRenderer`（只吃 PCM 裸流，
   * 还得自己解 WAV 封装）。工程里之前**只有录音没有播放**，这是第一处播放。
   * ⚠️ 播放不需新增权限（`INTERNET` 已有，SDK 只要求这一个）。
   *
   * ## ⚠️⚠️⚠️ 踩坑史：三次都栽在 AVPlayer 的**状态机**上
   *
   * SDK 对每个 API 的前置状态写得很死（错误码 **5400102
   * = AVERR_OPERATE_NOT_PERMIT**，官方描述 "Operation not allowed"）：
   *
   * | 步骤 | 前置状态 | 我犯的错 |
   *   |---|---|---|
   *   | `createAVPlayer()` | — | 返回的是 `Promise<AVPlayer>`，我当同步用了 |
   *   | 设`url` | **idle** | 没错，但设完状态**异步**切到 initialized |
   *   | `prepare()` | **initialized** | 我设完 url **立刻** await prepare → 状态还没切完 → **5400102** |
   *   | `play()` | **prepared / paused** | 没错 |
   *
   * ∴ **正确做法：设 url 之后必须等 `stateChange` 事件通知到`initialized`，
   *   才能调 prepare()** —— 不能用固定 setTimeout 猜时间。
   */
  private async play(accent: string): Promise<void> {
    const base: string = AppState.dictBaseUrl;
    if (base.length === 0) {
      promptAction.showToast({ message: '未配置词典服务器地址', duration: 2000 });
      return;
    }
    const url: string = dictAudioUrl(base, this.curWord, accent);
    // ⚠️ 为什么不能省掉这次 release：SDK 明确警告
    //    「You are advised to create a maximum of 16 AVPlayer instances」，
    //    部分芯片（RK3568）**上限只有 6 个** —— 不释放必然泄漏。
    //    代价是日志里会夹一条 stateChange: released，属预期行为。
    this.releasePlayer();

    let created: media.AVPlayer | undefined = undefined;
    try {
      created = await media.createAVPlayer();
    } catch (e) {
      hilog.error(0x0000, TAG, 'createAVPlayer failed: %{public}s', JSON.stringify(e));
      promptAction.showToast({ message: '播放器创建失败', duration: 2000 });
      return;
    }
    if (created === undefined) {
      return;
    }
    const player: media.AVPlayer = created;
    this.player = player;

    // ---- ⭐ 用 stateChange 事件把状态机走对 ----
    // 新建实例是 idle；设 url 后系统**异步**切到 initialized；
    // 必须在回调里才调 prepare()，否则就是 5400102。
    let prepared: boolean = false;
    let failed: boolean = false;

    player.on('stateChange', (state: string) => {
      hilog.info(0x0000, TAG, 'stateChange: %{public}s', state);
      if (failed) {
        return;
      }
      if (state === 'initialized') {
        // ✅ 现在才是 prepare() 的合法时机
        player.prepare()
          .then(() => {
            hilog.info(0x0000, TAG, 'prepared ok');
            return player.play();
          })
          .catch((e: BusinessError) => {
            if (failed) {
              return;
            }
            failed = true;
            hilog.error(0x0000, TAG,
              'prepare/play failed: code=%{public}d msg=%{public}s', e.code, e.message);
            this.releasePlayer();
            promptAction.showToast({ message: `发音失败（${e.code}）`, duration: 2400 });
          });
      } else if (state === 'completed') {
        // 单个单词发音约 0.7~0.9 秒（espeak-ng 合成孤立音节），
        // 点一次播一遍 —— 与 Oxford / Cambridge 一致，想再听就再点一次。
        // ⚠️ 2026-10-10 用户拍板：**不自动补播**。
        //    （我曾自作主张播两遍，理由是"0.7 秒容易一带而过"；
        //     他确认后改回单遍。改这个行为前先问。）
        hilog.info(0x0000, TAG, 'play completed accent=%{public}s', accent);
      }
    });

    player.on('error', (err: BusinessError) => {
      if (failed) {
        return;
      }
      failed = true;
      hilog.error(0x0000, TAG,
        'player error: code=%{public}d msg=%{public}s url=%{public}s',
        err.code, err.message, url);
      this.releasePlayer();
      promptAction.showToast({ message: `发音失败（${err.code}）`, duration: 2400 });
    });

    try {
      // ⚠️ 设 url 必须在 idle 态；新建实例天然是 idle，可以直接设。
      //    设完**不要**紧接着 prepare —— 等上面的 stateChange 回调。
      player.url = url;
      hilog.info(0x0000, TAG, 'url set, waiting initialized: %{public}s', url);
    } catch (e) {
      failed = true;
      const be: BusinessError = e as BusinessError;
      hilog.error(0x0000, TAG, 'set url failed: code=%{public}d', be.code);
      this.releasePlayer();
      promptAction.showToast({ message: `发音失败（${be.code}）`, duration: 2400 });
    }
  }

  private releasePlayer(): void {
    const p: media.AVPlayer | undefined = this.player;
    if (p === undefined) {
      return;
    }
    // 先清引用：保证即使 stop/release 抛错，this.player 也不会指向已废弃实例
    this.player = undefined;
    try {
      p.stop();
    } catch (e) {
      // ⚠️ 对不在播放态的实例调 stop() 会抛 5400102（AVERR_OPERATE_NOT_PERMIT），
      //   忽略即可。但 **release() 一定要执行** ——
      //   SDK 文档明确警告「You are advised to create a maximum of 16 AVPlayer
      //   instances... 在部分芯片（RK3568）上限只有 6 个」，泄漏实例是真问题。
    }
    try {
      p.release();
    } catch (e) {
      hilog.error(0x0000, TAG, 'release failed: %{public}s', JSON.stringify(e));
    }
  }

  // ================= 改写释义 =================

  private openEdit(): void {
    this.editText = this.userDef;
    this.editNote = '';
    // ⚠️ 默认**不勾选**授权同意 —— 必须用户主动勾。
    //    勾了即代表同意以 CC BY-SA 4.0 发布，服务端会留证。
    this.editAgree = false;
    this.showEdit = true;
  }

  private submitEdit(): void {
    if (this.editText.trim().length === 0) {
      promptAction.showToast({ message: '释义不能为空', duration: 2000 });
      return;
    }
    if (!this.editAgree) {
      promptAction.showToast({ message: '请先勾选同意授权条款', duration: 2400 });
      return;
    }
    this.submitting = true;
    const word: string = this.curWord;
    const def: string = this.editText.trim();
    // 先写本地（离线也能看到自己的修改），再提交服务端
    DictStore.saveUserEdit(word, def);
    DictionaryClient.submitEdit(word, def, this.editNote, '', true,
      () => {
        this.submitting = false;
        this.showEdit = false;
        this.userDef = def;
        this.userDefAt = Date.now();
        promptAction.showToast({ message: '已提交并保存到本机', duration: 2200 });
      },
      (msg: string) => {
        this.submitting = false;
        // 本地已存，提示服务端失败但不丢用户成果
        promptAction.showToast({ message: `${msg}（已保存在本机）`, duration: 3200 });
        this.showEdit = false;
      });
  }

  // ================= 顶栏 =================

  private barCapsuleH(): number {
    return Size.touchTarget + Space.s * 2;
  }

  private barTotalH(): number {
    return WindowInsets.statusBarVp() + Space.s + this.barCapsuleH() + Space.l;
  }

  @Builder
  barContent() {
    Row() {
      Stack({ alignContent: Alignment.TopStart }) {
        // 薄雾层：高度必须给确定值，不能写 '100%'
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
        Row() {
          Text('词典')
            .fontSize(FontSize.titleM)
            .fontWeight(Weight.medium)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
          Blank()
          Text(`${DictStore.count()}`)
            .fontSize(FontSize.bodyS)
            .fontColor(Theme.sysTextSub())
        }
        .width('100%')
        .height(this.barCapsuleH())
        .padding({ left: Space.s, right: Space.s })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .borderRadius(Radius.xl)
      .backgroundColor(Theme.floatGlassBase())
      .systemMaterial(Mat.floatGlass())
    }
    .width('100%')
    .padding({
      left: Layout.screenMargin() - 6,
      right: Layout.screenMargin() - 6,
      top: Space.s + WindowInsets.statusBarVp(),
      bottom: Space.none,
    })
  }

  // ================= 主体 =================

  @Builder
  searchCard() {
    Column() {
      Row() {
        TextInput({
          text: this.query,
          placeholder: '输入英文单词'
        })
          .fontSize(FontSize.subtitleM)
          .fontColor(Theme.sysTextMain())
          .placeholderColor(Theme.sysTextSub())
          .layoutWeight(1)
          .height(Size.touchTarget)
          .backgroundColor(Theme.sysFill())
          .borderRadius(Radius.m)
          .onChange((v: string) => {
            this.query = v;
          })
          .onSubmit(() => {
            this.doSearch();
          })
        Row().width(Space.s)
        Button('查询', { type: ButtonType.Capsule, stateEffect: true })
          .controlSize(ControlSize.SMALL)
          .height(Size.touchTarget)
          .padding({ left: Space.m, right: Space.m })
          .fontWeight(Weight.medium)
          .fontColor(Theme.onEmphasize())
          .backgroundColor(Theme.sysEmphasize())
          .enabled(!this.busy)
          .onClick(() => {
            this.doSearch();
          });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: Size.listDoubleWithIcon })

      if (this.busy) {
        Text('查询中…')
          .fontSize(FontSize.bodyS)
          .fontColor(Theme.sysTextSub())
          .width('100%')
          .margin({ top: Space.s })
      } else if (this.status.length > 0) {
        Text(this.status)
          .fontSize(FontSize.bodyS)
          .fontColor(Theme.sysTextSub())
          .width('100%')
          .margin({ top: Space.s })
      }
    }
    .width('100%')
    .padding(Space.l)
    .borderRadius(Radius.l)
    .backgroundColor(Theme.cardBase())
    .systemMaterial(Mat.card())
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  resultCard() {
    Column() {
      // 词头行：单词 + 音标 + 词性
      Row() {
        Text(this.curWord)
          .fontSize(FontSize.titleM)
          .fontWeight(Weight.bold)
          .fontColor(Theme.sysTextMain())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.posZh.length > 0) {
          Text(this.posZh)
            .fontSize(FontSize.bodyS)
            .fontColor(this.ton)
            .padding({ left: Space.s, right: Space.s, top: 2, bottom: 2 })
            .borderRadius(Radius.s)
            .backgroundColor(this.tc)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.ipa.length > 0) {
        Text(`/${this.ipa}/`)
          .fontSize(FontSize.bodyM)
          .fontColor(Theme.sysTextSub())
          .fontFamily('monospace')
          .width('100%')
          .margin({ top: Space.xs })
      }

      // ---- 考纲标签 + 星级（2026-10-10）----
      if (this.tags.length > 0 || this.collins > 0) {
        Row() {
          // ⚠️ 用 ForEach 而非固定 8 个 Text —— 标签数量不定（最多 8 种）
          ForEach(this.tags, (t: string) => {
            Text(t)
              .fontSize(FontSize.captionL)
              .fontColor(Theme.onEmphasize())
              .padding({ left: Space.s, right: Space.s, top: 2, bottom: 2 })
              .borderRadius(Radius.s)
              .backgroundColor(this.tc)
              .margin({ right: Space.xs })
          }, (t: string) => `tag-${t}`)
          if (this.collins > 0) {
            Text(`柯林斯 ${'★'.repeat(this.collins)}`)
              .fontSize(FontSize.captionL)
              .fontColor(Theme.sysTextSub())
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: Space.s })
      }

      // ---- ⭐ 中文释义（英汉词典的主体，放在最显眼处）----
      if (this.zhLines.length > 0) {
        Column() {
          ForEach(this.zhLines, (z: string, i: number) => {
            Row() {
              // 词性标记（n. / vt. / [计]等）用主题色，与释义正文区分
              Text(DictView.posTagOf(z))
                .fontSize(FontSize.bodyS)
                .fontColor(this.tc)
                .fontWeight(Weight.medium)
                .width(DictView.posTagOf(z).length > 0 ? 46 :0)
              Text(DictView.stripPosTag(z))
                .fontSize(FontSize.bodyM)
                .fontColor(Theme.sysTextMain())
                .layoutWeight(1)
                .lineHeight(FontSize.bodyM * 1.5)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .margin({ top: i === 0 ? Space.xs : Space.s })
          }, (z: string, i: number) => `zh-${i}-${z.length}`)
        }
        .width('100%')
        .padding(Space.m)
        .margin({ top: Space.m })
        .borderRadius(Radius.m)
        .border({ width: { left: 3 }, color: this.tc })
        .backgroundColor(Theme.innerBase())
        .systemMaterial(Mat.tile())
        .alignItems(HorizontalAlign.Start)
      }

      // 英音 / 美音 —— 服务端 espeak-ng 合成，两套音色确实不同
      Row() {
        Button('英音', { type: ButtonType.Normal, stateEffect: true })
          .controlSize(ControlSize.SMALL)
          .fontSize(FontSize.bodyS)
          .fontColor(Theme.sysEmphasize())
          .backgroundColor(Theme.sysFill())
          .padding({ left: Space.m, right: Space.m })
          .onClick(() => {
            this.play('gb');
          })
        Row().width(Space.s)
        Button('美音', { type: ButtonType.Normal, stateEffect: true })
          .controlSize(ControlSize.SMALL)
          .fontSize(FontSize.bodyS)
          .fontColor(Theme.sysEmphasize())
          .backgroundColor(Theme.sysFill())
          .padding({ left: Space.m, right: Space.m })
          .onClick(() => {
            this.play('us');
          })
        Blank()
        if (this.fromLocal) {
          Text('本机缓存')
            .fontSize(FontSize.captionL)
            .fontColor(Theme.sysTextSub())
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: Space.m })

      if (this.glosses.length > 0) {
        Column() {
          // 英文释义是**次要**信息（中文才是主体），加个小标题区分层次
          Text('英文释义')
            .fontSize(FontSize.captionL)
            .fontColor(Theme.sysTextSub())
            .width('100%')
            .margin({ top: Space.m })
          ForEach(this.glosses, (g: string, i: number) => {
            // ⚠️ **`Row` 没有 `alignContent` 参数**（那是 `Stack` 的）。
            //    编译报 "Object literal may only specify known properties, and
            //    'alignContent' does not exist in type 'RowOptions'"。
            //    Row 顶对齐用属性 `.alignItems(VerticalAlign.Top)`。
            Row() {
              Text(`${i + 1}`)
                .fontSize(FontSize.bodyS)
                .fontColor(Theme.sysTextSub())
                .width(18)
              Text(g)
                .fontSize(FontSize.bodyM)
                .fontColor(Theme.sysTextMain())
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)   // 顶对齐（替代 Row 不支持的 alignContent）
            .margin({ top: i === 0 ? Space.xs : Space.s })
          }, (g: string, i: number) => `gl-${i}-${g.length}`)
        }
        .width('100%')
        .padding(Space.m)
        .margin({ top: Space.m })
        .borderRadius(Radius.m)
        .backgroundColor(Theme.innerBase())
        .systemMaterial(Mat.tile())
        .alignItems(HorizontalAlign.Start)
      }

      // 用户改写层 —— 服务端返回的社区释义
      if (this.userDef.length > 0) {
        Column() {
          Row() {
            Text('社区释义')
              .fontSize(FontSize.captionL)
              .fontColor(Theme.sysEmphasize())
              .fontWeight(Weight.medium)
            Blank()
            Text('CC BY-SA 4.0')
              .fontSize(FontSize.captionL)
              .fontColor(Theme.sysTextSub())
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          Text(this.userDef)
            .fontSize(FontSize.bodyM)
            .fontColor(Theme.sysTextMain())
            .width('100%')
            .margin({ top: Space.xsPlus })
        }
        .width('100%')
        .padding(Space.m)
        .margin({ top: Space.m })
        .borderRadius(Radius.m)
        .border({ width: { left: 3 }, color: Theme.sysEmphasize() })
        .alignItems(HorizontalAlign.Start)
      }

      Row() {
        Blank()
        Text(this.userDef.length > 0 ? '修改释义' : '添加释义')
          .fontSize(FontSize.bodyS)
          .fontWeight(Weight.medium)
          .fontColor(Theme.sysEmphasize())
          .constraintSize({ minHeight: Size.touchTarget })
          .padding({ left: Space.s, right: Space.s })
          .onClick(() => {
            this.openEdit();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: Space.s })

      // 署名 —— CC BY 4.0 要求必须署名 Princeton WordNet 与 OEWN 两者
      if (this.source.length > 0 || this.glosses.length > 0) {
        Text(this.source.length > 0
          ? `${this.source}；本站释义未作修改`
          : '释义来自 Open English WordNet（CC BY 4.0），未作修改')
          .fontSize(FontSize.captionL)
          .fontColor(Theme.sysTextSub())
          .width('100%')
          .lineHeight(FontSize.captionL * 1.4)
          .margin({ top: Space.s })
      }
    }
    .width('100%')
    .padding(Space.l)
    .margin({ top: Space.m })
    .borderRadius(Radius.l)
    .backgroundColor(Theme.cardBase())
    .systemMaterial(Mat.card())
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  historyCard() {
    Column() {
      Row() {
        Text('最近查过')
          .fontSize(FontSize.subtitleM)
          .fontWeight(Weight.bold)
          .fontColor(Theme.sysTextMain())
          .layoutWeight(1)
        if (this.history.length > 0) {
          Text('清空')
            .fontSize(FontSize.bodyS)
            .fontColor(Theme.sysTextSub())
            .constraintSize({ minHeight: Size.touchTarget })
            .padding({ left: Space.s, right: Space.s })
            .onClick(() => {
              DictStore.clear();
              this.clearResult();
            });
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.history.length === 0) {
        Text('查过的词会保存在本机，没网也能查。')
          .fontSize(FontSize.bodyM)
          .fontColor(Theme.sysTextSub())
          .width('100%')
          .margin({ top: Space.s })
      } else {
        Column() {
          ForEach(this.history, (w: StoredWord) => {
            Row() {
              Text(w.word)
                .fontSize(FontSize.bodyM)
                .fontColor(Theme.sysTextMain())
                .layoutWeight(1)
              if (w.glosses.length > 0) {
                Text(w.glosses[0])
                  .fontSize(FontSize.captionL)
                  .fontColor(Theme.sysTextSub())
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(2)
              }
            }
            .width('100%')
            .constraintSize({ minHeight: Size.touchTarget })
            .onClick(() => {
              this.query = w.word;
              this.show(w);
              this.fetchRemote(w.word, true);
            });
            if (w.word !== this.history[this.history.length - 1].word) {
              Divider()
                .color(Theme.sysSeparator())
                .margin({ top: Space.s, bottom: Space.s })
            }
          }, (w: StoredWord) => `h-${w.word}`)
        }
        .width('100%')
        .margin({ top: Space.xs })
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .padding(Space.l)
    .margin({ top: Space.m })
    .borderRadius(Radius.l)
    .backgroundColor(Theme.cardBase())
    .systemMaterial(Mat.card())
    .alignItems(HorizontalAlign.Start)
  }

  /** 改写释义浮层 —— 复用周选择器那套「蒙层 + Mat.sheet()」 */
  @Builder
  editPanel() {
    Column() {
      Column() {
        Text(this.curWord.length > 0 ? `修改「${this.curWord}」的释义` : '添加释义')
          .fontSize(FontSize.subtitleM)
          .fontWeight(Weight.bold)
          .fontColor(Theme.sysTextMain())
          .width('100%')

        TextArea({
          text: this.editText,
          placeholder: '写下你理解的释义'
        })
          .fontSize(FontSize.bodyM)
          .fontColor(Theme.sysTextMain())
          .placeholderColor(Theme.sysTextSub())
          .width('100%')
          .height(120)
          .margin({ top: Space.m })
          .backgroundColor(Theme.sysFill())
          .borderRadius(Radius.m)
          .onChange((v: string) => {
            this.editText = v;
          })

        TextInput({
          text: this.editNote,
          placeholder: '备注（可选，如出处、记忆方法）'
        })
          .fontSize(FontSize.bodyS)
          .fontColor(Theme.sysTextMain())
          .placeholderColor(Theme.sysTextSub())
          .width('100%')
          .height(Size.touchTarget)
          .margin({ top: Space.s })
          .backgroundColor(Theme.sysFill())
          .borderRadius(Radius.m)
          .onChange((v: string) => {
            this.editNote = v;
          })

        // ⚠️ 组件名是 **`Checkbox`**（小写 b），不是 `CheckBox` —— 编译器会提示
//    "Cannot find name 'CheckBox'. Did you mean 'Checkbox'?"
        //    必须用户**主动勾选**，不能默认勾上、也不能静默代填。
        Row() {
          // ⚠️ 组件名是 **`Checkbox`**（小写 b），不是 `CheckBox` —— 编译器会提示
          //    "Cannot find name 'CheckBox'. Did you mean 'Checkbox'?"
          Checkbox({ name: 'agree', group: 'agree' })
            .select(this.editAgree)
            .width(20)
            .height(20)
            .onChange((v: boolean) => {
              this.editAgree = v;
            })
          Text('我同意将这段释义以 CC BY-SA 4.0 授权发布（保留时间戳与提交标识）')
            .fontSize(FontSize.captionL)
            .fontColor(Theme.sysTextSub())
            .layoutWeight(1)
            .lineHeight(FontSize.captionL * 1.4)
            .margin({ left: Space.s })
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .margin({ top: Space.m })
      }
      .width('100%')
      .padding(Space.l)
      .borderRadius(Radius.l)
      .backgroundColor(Theme.innerBase())
      .systemMaterial(Mat.tile())
      .alignItems(HorizontalAlign.Start)

      Row() {
        Button('取消', { type: ButtonType.Capsule, stateEffect: true })
          .layoutWeight(1)
          .controlSize(ControlSize.NORMAL)
          .fontColor(Theme.sysEmphasize())
          .backgroundColor(Theme.sysFill())
          .onClick(() => {
            this.showEdit = false;
          })
        Row().width(Space.s)
        Button(this.submitting ? '提交中…' : '提交', { type: ButtonType.Capsule, stateEffect: true })
          .layoutWeight(1)
          .controlSize(ControlSize.NORMAL)
          .fontWeight(Weight.medium)
          .fontColor(Theme.onEmphasize())
          .backgroundColor(Theme.sysEmphasize())
          .enabled(!this.submitting && this.editAgree)
          .onClick(() => {
            this.submitEdit();
          });
      }
      .width('100%')
      .margin({ top: Space.l })
    }
    .width('88%')
    .padding(Space.l)
    .borderRadius(Radius.xl)
    .backgroundColor(Theme.sysCard())
    .systemMaterial(Mat.sheet());
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Scroll() {
          Column() {
            // ⚠️ Blank 必须在 Scroll **内容里**，不能在 Scroll 外面
            //    （兄弟 Blank = 实体占位，内容永远进不了胶囊区域）
            Blank().height(this.barTotalH())

            this.searchCard()

            if (this.curWord.length > 0) {
              this.resultCard()
            }

            this.historyCard()
          }
          .width('100%')
          // ⚠️ 手机端必须给合法极大值，不能给 0（ArkUI maxWidth:0 = 上限为零，
          //    会把整棵 Column 压成 0 宽、卡片塌成竖条。见 commit e18b5db）
          .constraintSize({ maxWidth: Layout.isTablet() ? Layout.contentMaxWidth() : 100000 })
          .padding({
            left: Layout.screenMargin(),
            right: Layout.screenMargin(),
            bottom: Size.barClearanceMin,
          });
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .width('100%')
        .align(Alignment.Top);
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.sysPage());

      this.barContent();

      if (this.showEdit) {
        this.editPanel();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.sysPage());
  }
}