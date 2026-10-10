import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { TranscriptBuffer } from '../service/TranscriptBuffer';
// 【2026-09-28】LiveViewService 的 import 已移除：实况窗场景未获开放，
// 应用侧不再发起任何实况窗调用（用户要求「无法使用就删除不要渲染」）。

/** 一条被检测出的问题；垂询后 answer/reasoning 流式填充。 */
export class QuestionItem {
  id: number = 0;
  text: string = '';
  ts: number = 0;
  reasoning: string = '';
  answer: string = '';
  answering: boolean = false;
  done: boolean = false;

  constructor(id: number, text: string, ts: number) {
    this.id = id;
    this.text = text;
    this.ts = ts;
  }
}

/** 一条已成句的转写历史（主页展示层，跨停止/重启保留）。 */
export class TranscriptLine {
  text: string = '';
  ts: number = 0;

  constructor(text: string, ts: number) {
    this.text = text;
    this.ts = ts;
  }
}

type QuestionListener = (items: QuestionItem[]) => void;

/** 全局状态单例：问题列表 + 转写历史 + 日志 + 配置持久化 + 变更通知。 */
export class AppState {
  static questions: QuestionItem[] = [];
  static transcriptLog: TranscriptLine[] = [];
  /** 转写变更计数，UI 轮询用 */
  static transcriptVersion: number = 0;
  static logs: string[] = [];
  private static nextId: number = 1;
  private static listeners: QuestionListener[] = [];
  private static prefs: preferences.Preferences | null = null;

  // ---- 配置（内存值，启动时从 preferences 加载） ----
  // ⚠️ 这里**不再预填任何服务器地址**（2026-09-28 用户明确要求：「wss 的网址别再填我的了」）。
  //    留空 → 用户在「设置」里自己填；`effectiveServerUrl()` 为空时返回空串，
  //    由调用方给出「未配置」提示，而不是偷偷回落到某个私人域名。
  static serverUrl: string = '';
  static llmBaseUrl: string = '';
  static llmModel: string = '';
  static llmApiKey: string = '';
  static asrMode: string = 'local';      // local | cloud | api
  static audioMode: string = 'mic';      // mic | system
  static offlineFallback: boolean = true;
  /** 云端 ASR 的 WSS 地址。默认留空，由用户自行填写。 */
  static cloudAsrUrl: string = '';
  // ---- ASR 通用 API 模式（OpenAI 兼容 /v1/audio/transcriptions） ----
  // 与 cloud（私有 WSS 流式协议）是两条不同链路：这走 HTTP 分段提交音频文件。
  static asrApiBaseUrl: string = '';
  static asrApiModel: string = 'whisper-1';
  static asrApiKey: string = '';
  /**
   * 词典服务地址（dictionary.xsheep.cn，2026-10-10 新增）。
   *
   * ⚠️ **留空，由用户在设置页填写** —— 与上面所有服务器地址保持一致
   *    （遵循 2026-09-28 用户明确要求：「wss 的网址别再填我的了」）。
   *    空值时 `DictionaryClient.lookup` 会提示"未配置词典服务器地址"，
   *    而**不是偷偷回落到某个域名**。
   *
   *    填写时只要填到域名即可（如 `https://dictionary.xsheep.cn`），
   *    `dictEndpoint()` 会补 `/api/v1/word`。
   */
  static dictBaseUrl: string = '';
  /**
   * API 链路的**兜底切段上限**（秒）。
   *
   * ⚠️ 语义于 2026-10-02 变更：切分主力改为「VAD 停顿检测」——
   *    说完一句停顿约 0.4s 就单独提交一段，出字延迟降到 1~3s。
   *    这个值只在说话人不间断（朗读 / 连续念）时才触发强制切一刀，
   *    所以从原来的 12s 降到 3s。
   */
  static asrApiChunkSec: number = 3;

  // ---- API 链路的 VAD 切分参数 ----------------------------------------------
  // 【2026-10-02】原为 `AsrService` 顶部的三个 `private static readonly` 常量，
  // 现提到此处并在设置页开放调节（现场环境的底噪差异很大，出厂值不可能通吃）。
  //
  // ⚠️ 只作用于「大模型 API」这条 HTTP 分段链路。
  //    系统识别走引擎自带的 vadEnd，私有云 WSS 由服务端断句 —— 都不读这三个值。
  //
  // ⚠️ 三个字段的初值必须与下面三个 `*_DEFAULT` 一致（改一个记得改另一个）。

  /** 出厂默认值，设置页「恢复默认」按这三项复原。 */
  static readonly VAD_MIN_RMS_DEFAULT: number = 420;
  static readonly VAD_SIL_MS_DEFAULT: number = 400;
  static readonly VAD_MIN_SEG_MS_DEFAULT: number = 800;

  /**
   * 静音判定下限（16bit PCM 的 RMS）。
   *
   * ⚠️ 它是阈值的**地板**，不是阈值本身 —— 实际判定用
   *    `max(本值, 自适应噪声底 × 3)`，噪声底慢跟随环境（且**只在静音窗口更新**，
   *    否则说话声会把底噪抬上去，阈值越来越高、越切越碎）。
   * 调大 = 更抗噪，代价是小声说话有被当静音切掉的风险；
   * 调小 = 更灵敏，代价是呼吸声 / 键盘声会被当语音，切出碎片段。
   */
  static vadMinRms: number = 420;

  /**
   * 尾部**连续静音**持续这么久就认为「一句说完」（ms）。
   * 中文自然停顿约 200~400ms，出厂值取在停顿区间的上沿：
   * 要停满一次完整换气才切，避免在词间换气处误切。调小更跟手、但更容易把长句切碎。
   */
  static vadSilMs: number = 400;

  /** 一段至少要累积这么久才允许因静音切出（ms）—— 防止噪音切出一堆碎片段。 */
  static vadMinSegMs: number = 800;

  // ---- 问题检测（与「大语言模型」分开配置；可共用也可单独一套模型） ----
  static readonly DETECT_SERVER: string = 'server';   // 服务器检测
  static readonly DETECT_LLM: string = 'llm';         // 客户端模型检测（规则快筛 + 模型复核模糊区）
  static readonly DETECT_RULE: string = 'rule';       // 仅端侧规则
  static detectMode: string = AppState.DETECT_SERVER;
  static detectShared: boolean = true;                // true=与大语言模型同一套；false=用 detect* 这套
  static detectBaseUrl: string = '';
  static detectModel: string = '';
  static detectApiKey: string = '';
  /** 当前科目（SubjectLexicon key；auto = 按课表推断，general = 只做通用纠正） */
  static subjectKey: string = 'auto';
  /**
   * 最近一次 auto 成功推断出的科目 key（跨会话持久化）。
   *
   * 【2026-09-30 新增 · 从 AsrService 内存态搬上来】
   * 原来只在 `AsrService.lastAutoSubject` 里存一个进程内变量，应用重启就丢，
   * 于是「今天没课 → 冷启动 → 掉回通用」。改成落盘后：
   *   · 设置页在无课时能显示「沿用上次：大学物理」而不是「没有匹配到专业科目」；
   *   · 听课开始时的科目解析也能直接用，不必再维护一份内存副本。
   */
  static lastAutoSubject: string = '';

  // ---- 运行态 ----
  static partialText: string = '';
  static lastError: string = '';
  static buffer: TranscriptBuffer = new TranscriptBuffer();

  static async init(ctx: common.UIAbilityContext): Promise<void> {
    const p = await preferences.getPreferences(ctx, 'skt_prefs');
    AppState.prefs = p;
    AppState.serverUrl = (await p.get('serverUrl', AppState.serverUrl)) as string;
    AppState.llmBaseUrl = (await p.get('llmBaseUrl', '')) as string;
    AppState.dictBaseUrl = (await p.get('dictBaseUrl', '')) as string;
    AppState.llmModel = (await p.get('llmModel', '')) as string;
    AppState.llmApiKey = (await p.get('llmApiKey', '')) as string;
    AppState.asrMode = (await p.get('asrMode', 'local')) as string;
    AppState.audioMode = (await p.get('audioMode', 'mic')) as string;
    AppState.offlineFallback = (await p.get('offlineFallback', true)) as boolean;
    AppState.cloudAsrUrl = (await p.get('cloudAsrUrl', AppState.cloudAsrUrl)) as string;
    AppState.asrApiBaseUrl = (await p.get('asrApiBaseUrl', '')) as string;
    AppState.asrApiModel = (await p.get('asrApiModel', 'whisper-1')) as string;
    AppState.asrApiKey = (await p.get('asrApiKey', '')) as string;
    AppState.asrApiChunkSec = (await p.get('asrApiChunkSec', 3)) as number;
    AppState.vadMinRms = (await p.get('vadMinRms', AppState.VAD_MIN_RMS_DEFAULT)) as number;
    AppState.vadSilMs = (await p.get('vadSilMs', AppState.VAD_SIL_MS_DEFAULT)) as number;
    AppState.vadMinSegMs = (await p.get('vadMinSegMs', AppState.VAD_MIN_SEG_MS_DEFAULT)) as number;
    AppState.subjectKey = (await p.get('subjectKey', 'auto')) as string;
    AppState.lastAutoSubject = (await p.get('lastAutoSubject', '')) as string;
    AppState.detectMode = (await p.get('detectMode', AppState.DETECT_SERVER)) as string;
    AppState.detectShared = (await p.get('detectShared', true)) as boolean;
    AppState.detectBaseUrl = (await p.get('detectBaseUrl', '')) as string;
    AppState.detectModel = (await p.get('detectModel', '')) as string;
    AppState.detectApiKey = (await p.get('detectApiKey', '')) as string;
    await AppState.restoreTranscript();
    await AppState.restoreQuestions();
  }

  static async save(key: string, value: preferences.ValueType): Promise<void> {
    if (AppState.prefs == null) {
      return;
    }
    await AppState.prefs.put(key, value);
    await AppState.prefs.flush();
  }

  // ---- 问题列表 ----
  static onQuestionsChanged(cb: QuestionListener): void {
    AppState.listeners.push(cb);
    cb(AppState.questions);
  }

  private static notify(): void {
    for (const cb of AppState.listeners) {
      cb(AppState.questions);
    }
  }

  /** 30 秒窗口内文本高度相似的问题视为重复。 */
  static addQuestion(text: string): QuestionItem | null {
    const t = text.trim();
    if (t.length < 4) {
      return null;
    }
    const now = Date.now();
    const dup = AppState.questions.some((q) => {
      const fresh = now - q.ts < 30000;
      return fresh && (q.text === t || q.text.includes(t) || t.includes(q.text));
    });
    if (dup) {
      return null;
    }
    const item = new QuestionItem(AppState.nextId, t, now);
    AppState.nextId += 1;
    AppState.questions.push(item);
    if (AppState.questions.length > 50) {
      AppState.questions.shift();
    }
    AppState.persistQuestions();
    AppState.notify();
    // 【2026-09-28 移除】原 `LiveViewService.onQuestion(t)` 调用已删。
    // 实况窗场景未获官方开放（已被驳回），用户要求不再渲染任何实况窗内容。
    return item;
  }

  static updateQuestion(id: number, fn: (q: QuestionItem) => void): void {
    for (const q of AppState.questions) {
      if (q.id === id) {
        fn(q);
        break;
      }
    }
    AppState.notify();
  }

  static findQuestion(id: number): QuestionItem | null {
    for (const q of AppState.questions) {
      if (q.id === id) {
        return q;
      }
    }
    return null;
  }

  /**
   * 落盘值为空时返回空串（不再回落到硬编码域名）。
   * 调用方拿到空串应提示「请先在设置里填写服务器地址」，而不是静默连到别人的服务器。
   */
  static effectiveServerUrl(): string {
    const u = AppState.serverUrl.trim();
    if (u.indexOf('192.168.1.100') >= 0) {
      return '';
    }
    return u;
  }

  static clearQuestions(): void {
    AppState.questions = [];
    AppState.persistQuestions();
    AppState.notify();
  }

  // ---- 转写历史（跨停止/重启保留） ----

  static addTranscript(text: string, ts: number): void {
    const t = text.trim();
    if (t.length === 0) {
      return;
    }
    AppState.transcriptLog.push(new TranscriptLine(t, ts));
    if (AppState.transcriptLog.length > 300) {
      AppState.transcriptLog.shift();
    }
    AppState.persistTranscript();
    AppState.transcriptVersion += 1;
  }

  static clearTranscript(): void {
    AppState.transcriptLog = [];
    AppState.transcriptVersion += 1;
    AppState.persistTranscript();
  }

  private static async persistTranscript(): Promise<void> {
    if (AppState.prefs == null) {
      return;
    }
    const arr: Array<Record<string, Object>> = [];
    for (const l of AppState.transcriptLog) {
      const o: Record<string, Object> = { 't': l.text, 'ts': l.ts };
      arr.push(o);
    }
    await AppState.save('transcriptJson', JSON.stringify(arr));
  }

  private static async restoreTranscript(): Promise<void> {
    if (AppState.prefs == null) {
      return;
    }
    try {
      const raw = (await AppState.prefs.get('transcriptJson', '[]')) as string;
      const arr = JSON.parse(raw) as Array<Record<string, Object>>;
      const lines: TranscriptLine[] = [];
      for (const o of arr) {
        const t = typeof o['t'] === 'string' ? o['t'] as string : '';
        const ts = typeof o['ts'] === 'number' ? o['ts'] as number : 0;
        if (t.length > 0) {
          lines.push(new TranscriptLine(t, ts));
        }
      }
      AppState.transcriptLog = lines;
      AppState.transcriptVersion += 1;
    } catch (e) {
      // 损坏则忽略，从空白开始
    }
  }

  private static async persistQuestions(): Promise<void> {
    if (AppState.prefs == null) {
      return;
    }
    const arr: Array<Record<string, Object>> = [];
    for (const q of AppState.questions) {
      const o: Record<string, Object> = { 'id': q.id, 't': q.text, 'ts': q.ts };
      arr.push(o);
    }
    await AppState.save('questionsJson', JSON.stringify(arr));
  }

  private static async restoreQuestions(): Promise<void> {
    if (AppState.prefs == null) {
      return;
    }
    try {
      const raw = (await AppState.prefs.get('questionsJson', '[]')) as string;
      const arr = JSON.parse(raw) as Array<Record<string, Object>>;
      let maxId = 0;
      const items: QuestionItem[] = [];
      for (const o of arr) {
        const id = typeof o['id'] === 'number' ? o['id'] as number : 0;
        const t = typeof o['t'] === 'string' ? o['t'] as string : '';
        const ts = typeof o['ts'] === 'number' ? o['ts'] as number : 0;
        if (t.length > 0 && id > 0) {
          items.push(new QuestionItem(id, t, ts));
          if (id > maxId) {
            maxId = id;
          }
        }
      }
      AppState.questions = items;
      AppState.nextId = maxId + 1;
    } catch (e) {
      // 损坏则忽略
    }
  }

  // ---- 日志 ----
  static log(line: string): void {
    const t = new Date();
    const hh = t.getHours().toString().padStart(2, '0');
    const mm = t.getMinutes().toString().padStart(2, '0');
    const ss = t.getSeconds().toString().padStart(2, '0');
    AppState.logs.push(`${hh}:${mm}:${ss}  ${line}`);
    if (AppState.logs.length > 200) {
      AppState.logs.shift();
    }
  }

  static logText(): string {
    return AppState.logs.join('\n');
  }
}