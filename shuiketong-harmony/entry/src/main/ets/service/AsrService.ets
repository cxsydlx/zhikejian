import { audio } from '@kit.AudioKit';
import { common } from '@kit.AbilityKit';
import { webSocket, http } from '@kit.NetworkKit';
import { speechRecognizer } from '@kit.CoreSpeechKit';
import { AppState } from '../common/AppState';
import { CourseStore } from '../common/CourseStore';
import { LlmRunner } from './LlmRunner';
import { QuestionDetector } from './QuestionDetector';
import { TranscriptStore } from '../common/TranscriptStore';
import { SubjectLexicon } from '../common/SubjectLexicon';

const SAMPLE_RATE = 16000;
/** Core Speech Kit 硬约束：单次 writeAudio 仅支持 640(20ms) 或 1280(40ms) 字节 PCM */
const WRITE_CHUNK_BYTES = 1280;
/** 长语音单次识别时长上限（引擎按 vadEnd 自动断句，此值给到 8 小时封顶） */
const MAX_AUDIO_MS = 8 * 60 * 60 * 1000;
/** vadEnd：静音 1.5 秒引擎自动断句（句子主边界，isFinal 随之而来） */
const VAD_END_MS = 1500;
/** 兜底成句：仅防引擎 isFinal 事件丢失。阈值必须远大于 vadEnd，避免截断整句 */
const FINALIZE_AFTER_MS = 6000;

/**
 * 云端 ASR 握手帧。
 * ArkTS 不允许裸对象字面量（arkts-no-untyped-obj-literals），必须对应显式声明的类型；
 * hotwords 不设置时 JSON.stringify 会整键省略，不会发出 hotwords: undefined。
 */
class CloudHello {
  lang: string = 'zh';
  sample_rate: number = SAMPLE_RATE;
  token: string = '';
  hotwords: string[] = [];
}

/**
 * 语音识别服务：
 * - local  = 系统识别（Core Speech Kit，端侧离线引擎，模型由系统提供，无需打包）
 * - cloud  = 云端识别（voice.xsheep.cn WSS）
 * 两种模式运行中可互相降级：系统不可用 -> 云端；云端连续失败 -> 回退系统。
 */
export class AsrService {
  static detector: QuestionDetector = new QuestionDetector();

  private static engine: speechRecognizer.SpeechRecognitionEngine | null = null;
  private static sessionId: string = 'skt_' + Date.now();
  private static sessionActive: boolean = false;
  /**
   * 会话世代号：start / stop 时递增。
   * 引擎与云端 ASR 的回调都是异步的，cancel()/close() 不保证立刻静默，
   * 停止后仍可能有在途回调（识别结果、收尾、错误）。回调统一用 validXxx() 校验世代，
   * 旧世代的回调直接丢弃，从根上杜绝"点了停止还在出字"。
   */
  private static sessionGen: number = 0;
  private static activeGen: number = 0;
  private static capturer: audio.AudioCapturer | null = null;
  private static running: boolean = false;
  /** 当前采集循环喂给哪条链路（与用户设置 asrMode 解耦，降级时切换） */
  private static activeCloud: boolean = false;
  /** 当前是否走「通用 API 分段识别」链路（HTTP，与 cloud 的 WSS 流式不同） */
  private static activeApi: boolean = false;
  // ============ API 链路状态机（2026-10-02 重构：VAD 切分 + 发送流水线）============
  // ## 旧实现的致命缺陷
  // `if (攒够一段 && !apiBusy)` 才提交，但缓冲是**无条件**累积的 ——
  // 请求未返回期间音频继续往同一块缓冲里堆，于是下一段 = chunkSec + 等待耗时，
  // 网络越慢段越长，延迟滚雪球（12s → 15s → 20s…）。
  //
  // ## 新实现
  // 采集循环只管「按 VAD 切成段 → 入队」，`enqueueApiSegment()` 立即返回；
  // 发送端独立消费队列，最多 2 个在途请求。**采集永不等待网络**。
  // 并发返回顺序不保证，所以每个段带序号，按序号重排后才落字。
  private static apiPcmBuf: Uint8Array = new Uint8Array(0);
  /** 当前段已累积的毫秒数（按采集块计，VAD 判定用） */
  private static apiSegMs: number = 0;
  /** 当前段尾部**连续静音**的毫秒数 —— 达到阈值就切段 */
  private static apiSilMs: number = 0;
  /** 环境噪声底（16bit PCM 的 RMS），自适应慢跟随，用于动态推算静音阈值 */
  private static apiNoise: number = 200;
  /**
   * 当前段内是否出现过语音。
   *
   * ⚠️ 必须判：用户说完一句后长时间思考（或开头一直没开口）时，缓冲区会继续累积，
   *    静音攒到 `AppState.vadMinSegMs` 同样会触发切段 —— 于是发出去一段**纯静音**。
   *    而 whisper 对纯静音/低信噪比音频会**凭空编出文本**（"谢谢观看""请订阅"之类），
   *    这是它的已知缺陷。所以纯静音段一律丢弃，不提交。
   */
  private static apiHasVoice: boolean = false;
  /** 待发送队列 */
  private static apiQueue: Uint8Array[] = [];
  /** 在途请求数（达到 API_MAX_INFLIGHT 就排队等） */
  private static apiInFlight: number = 0;
  /** 段序号分配器 */
  private static apiSeqNext: number = 0;
  /** 下一个应该输出的段序号（小于它的都已落字） */
  private static apiSeqOut: number = 0;
  /** 已返回、但前面还有段落未补齐的文本（按 seq 暂存） */
  private static apiPending: Map<number, string> = new Map<number, string>();
  /** 采集块时长（`capturer.read` 每次取 100ms） */
  private static readonly API_TICK_MS: number = 100;
  /** 并发上限：2 个足够把网络往返藏在下一段录音里，再多会打爆配额 */
  private static readonly API_MAX_INFLIGHT: number = 2;
  // ---- VAD 的三个可调参数 ----
  // 【2026-10-02】原为这里的三个 `private static readonly` 常量，已提到
  // `AppState.vadMinRms / vadSilMs / vadMinSegMs` 并在设置页开放调节 ——
  // 安静教室与嘈杂宿舍的底噪差一个量级，出厂值不可能通吃，必须能现场调。
  // 采集循环每 100ms 现读现用，所以**保存后立即对进行中的录音生效**，
  // 不必重开录音（`asrApiChunkSec` 不同，它在 startApiUpstream 开头算一次，要重开才生效）。
  // 出厂默认值见 `AppState.VAD_*_DEFAULT`。
  private static sysFailCount: number = 0;
  private static cloudFailCount: number = 0;
  /** 成句去重：引擎 vadEnd 断句与停更兜底可能先后给出同一句 */
  private static lastFinalText: string = '';
  private static lastText: string = '';
  private static lastChangeAt: number = 0;
  /** PCM 累积缓冲（凑满 1280B 再写引擎） */
  private static pending: Uint8Array = new Uint8Array(0);
  private static cloudWs: webSocket.WebSocket | null = null;
  private static cloudConnected: boolean = false;
  // ---- 系统识别错误降噪 / 自愈 ----
  private static appCtx: common.UIAbilityContext | null = null;
  private static lastErrKey: string = '';
  private static lastErrAt: number = 0;
  private static foldedErrCount: number = 0;
  private static restartCooldownUntil: number = 0;
  private static restartAttempts: number = 0;
  /** 本次会话实际生效的科目（auto 在 start 时解析一次并冻结，中途不漂移） */
  private static subjectKey: string = SubjectLexicon.AUTO;

  static isRunning(): boolean {
    return AsrService.running;
  }

  /**
   * 当前是否走「非系统识别」的远程链路（云端 WSS 或通用 API）。
   * 系统识别的采集循环必须用它判断：只看 activeCloud 的话，
   * API 模式下 activeCloud=false 会让系统循环也启动、跟 API 循环抢同一个麦克风。
   */
  private static remoteLink(): boolean {
    return AsrService.activeCloud || AsrService.activeApi;
  }

  /**
   * 回调守卫（系统识别链路）：已停止 / 已切到任一远程链路（云端或 API）/ 旧世代 -> false。
   * 注意必须判 remoteLink() 而不是单看 activeCloud：API 模式下 activeCloud=false，
   * 只看它会让系统识别的回调以为"还在系统链路"从而继续写结果、继续重启会话。
   */
  private static validLoop(): boolean {
    return AsrService.running
      && !AsrService.remoteLink()
      && AsrService.sessionGen === AsrService.activeGen;
  }

  /** 回调守卫（云端链路）：已停止 / 已切回系统 / 旧世代 -> false */
  private static validCloud(): boolean {
    return AsrService.running
      && AsrService.activeCloud
      && AsrService.sessionGen === AsrService.activeGen;
  }

  static async start(ctx: common.UIAbilityContext): Promise<void> {
    if (AsrService.running) {
      return;
    }
    AsrService.running = true;
    AsrService.sessionGen += 1;                    // 开启新世代：作废上一次会话的在途回调
    AsrService.activeGen = AsrService.sessionGen;
    AsrService.sessionId = 'skt_' + Date.now();    // 换新会话号，不复用已取消的会话
    AsrService.appCtx = ctx;
    AsrService.sysFailCount = 0;
    AsrService.cloudFailCount = 0;
    AsrService.restartAttempts = 0;
    AsrService.lastErrKey = '';
    AsrService.lastFinalText = '';
    AsrService.lastText = '';
    AsrService.lastChangeAt = 0;
    AsrService.pending = new Uint8Array(0);
    AppState.partialText = '';
    AsrService.subjectKey = AsrService.resolveSubject();
    AsrService.activeCloud = AppState.asrMode === 'cloud';
    AsrService.activeApi = AppState.asrMode === 'api';
    await AsrService.startCapture(ctx, AsrService.activeCloud, AsrService.activeApi);
  }

  /**
   * 用于自动科目推断的课程名。优先级：
   *   ① 此刻正在上的课
   *   ② 今天接下来最近的一节
   *   ③ 今天已经上过的最近一节（补课 / 拖堂 / 课后自习）
   *   ④ 空串（今天完全没课）
   *
   * 【2026-09-30 搬到 `CourseStore.currentCourseName()` —— 这里改为转发】
   * 设置页刷新科目提示时要用**完全同一套**取课逻辑，否则两处会口径漂移
   * （曾出现"设置页说没匹配到、实际识别用的是物理词库"）。收敛到 CourseStore 后
   * 两边只有一份实现。
   */
  private static currentCourseName(now: number): string {
    return CourseStore.currentCourseName(now);
  }

  /**
   * 解析本次会话生效的科目：auto 时按课表当前课推断。
   * 只解析一次并冻结，避免中途下课导致词库漂移。
   *
   * 【2026-09-28 修正】当天完全没课时（周末 / 假期 / 临时加课），
   * 不再直接掉回"通用"，而是沿用**上一次成功推断出的科目**（`lastAutoSubject`）。
   * 因为「昨天在上高数、今天周末来图书馆自习」时，沿用高数词库明显比通用词库有用。
   * 只有从未成功推断过（首次使用）才回退通用。
   *
   * 【2026-09-30 修正】`lastAutoSubject` 从内存态搬到 `AppState`（落盘），
   * 应用重启后不再丢 —— 否则每天第一次冷启动若恰好没课，仍然会掉回通用。
   */
  private static resolveSubject(): string {
    if (AppState.subjectKey !== SubjectLexicon.AUTO) {
      return AppState.subjectKey;
    }
    const name = AsrService.currentCourseName(Date.now());
    if (name.length === 0) {
      if (AppState.lastAutoSubject.length > 0) {
        AppState.log(`科目词库: 自动（今天无课，沿用上次 ${SubjectLexicon.labelOf(AppState.lastAutoSubject)}）`);
        return AppState.lastAutoSubject;
      }
      AppState.log('科目词库: 自动（课表无课且无历史，回退通用）');
      return 'general';
    }
    const key = SubjectLexicon.guess(name);
    if (key !== 'general') {
      AppState.lastAutoSubject = key;
      AsrService.persistLastAuto(key);
    }
    AppState.log(`科目词库: 自动→${SubjectLexicon.labelOf(key)}（${name}）`);
    return key;
  }

  /** 落盘"最近一次成功的自动推断"，失败静默（只是优化项，不该影响听课） */
  private static persistLastAuto(key: string): void {
    AppState.save('lastAutoSubject', key).catch(() => {
      // 忽略：prefs 未就绪或写入失败都不影响本次识别
    });
  }

  static stop(): void {
    const wasRunning = AsrService.running;
    // 关键：停止前把尚未成句的尾句收掉，否则最后一句直接丢失（问题检测也会漏）
    if (wasRunning && AsrService.lastText.length > 0) {
      AsrService.emitFinal(AsrService.lastText);
    }
    // 幂等：即使此前已因异常自停，也要把采集器 / 连接 / 会话收拾干净
    AsrService.running = false;
    AsrService.sessionGen += 1;   // 作废本次会话的所有在途回调（含云端残留帧 / API 在途响应）
    AsrService.activeCloud = false;
    AsrService.activeApi = false;
    AsrService.resetApiState();
    AsrService.closeCloud();
    AsrService.cancelSession();
    AsrService.releaseCapture();
    // 清残留状态：下一次启动从干净状态开始
    AsrService.lastText = '';
    AsrService.lastChangeAt = 0;
    AsrService.sysFailCount = 0;
    AsrService.cloudFailCount = 0;
    AppState.partialText = '';
  }

  /** 释放采集器：正常停止与异常自停共用，防止麦克风被长期占用。 */
  private static releaseCapture(): void {
    const c = AsrService.capturer;
    if (c != null) {
      AsrService.capturer = null;
      c.stop().then(() => c.release()).catch(() => {});
    }
    AsrService.pending = new Uint8Array(0);
    AppState.partialText = '';
  }

  // ---------- 采集 ----------

  private static async startCapture(
    ctx: common.UIAbilityContext,
    cloudMode: boolean,
    apiMode: boolean
  ): Promise<void> {
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
    };
    const capturerInfo: audio.AudioCapturerInfo = {
      source: audio.SourceType.SOURCE_TYPE_MIC,
      capturerFlags: 0,
    };
    const options: audio.AudioCapturerOptions = {
      streamInfo: streamInfo,
      capturerInfo: capturerInfo,
    };

    const capturer = await audio.createAudioCapturer(options);
    AsrService.capturer = capturer;
    await capturer.start();

    if (apiMode) {
      AsrService.startApiUpstream(ctx, capturer);
      return;
    }
    if (cloudMode) {
      AsrService.startCloudUpstream(ctx, capturer);
      return;
    }
    AsrService.startSystemAsr(ctx, capturer);
  }

  // ---------- 系统识别（Core Speech Kit） ----------

  private static startSystemAsr(ctx: common.UIAbilityContext, capturer: audio.AudioCapturer): void {
    const loop = async (): Promise<void> => {
      try {
        await AsrService.ensureEngine();
        AsrService.cancelSession();
        AsrService.startListening();
        AsrService.sysFailCount = 0;
        AsrService.pending = new Uint8Array(0);
        AppState.partialText = '';
        // 采集循环：read -> 累积 -> 按 1280B 切块 writeAudio（引擎硬约束）
        const readBytes = SAMPLE_RATE / 10 * 2; // 3200B ≈ 100ms
        while (AsrService.running && !AsrService.remoteLink()) {
          const buf = await capturer.read(readBytes, true);
          // 停止瞬间 await 中的 read 仍会返回最后一块音频：此处再校验一次，不再喂引擎，
          // 否则这一块会凑成新的一句，表现为"点了停止还在转写"
          if (!AsrService.validLoop()) {
            break;
          }
          AsrService.feedPcm(new Uint8Array(buf));
          AsrService.finalizeIfIdle();
        }
      } catch (e) {
        // 停止 / 降级过程中的 read 异常属于正常收尾，绝不能走"降级云端"分支，
        // 否则会把已停止的会话又拉起来（原来这里没有守卫，是停止后继续出字的元凶之一）
        if (!AsrService.validLoop()) {
          return;
        }
        const err = e as Error;
        AsrService.sysFailCount += 1;
        AsrService.cancelSession();
        if (AsrService.sysFailCount >= 2) {
          AppState.log('系统识别与云端均不可用，请检查设备语音服务或网络');
          AsrService.running = false;
          AsrService.sessionGen += 1;   // 彻底自停：作废在途回调并释放麦克风
          AsrService.releaseCapture();
          return;
        }
        AppState.log(`系统识别不可用（${err.message ?? err}），降级云端识别`);
        AsrService.degradeToCloud(ctx, capturer);
      }
    };
    loop();
  }

  private static async ensureEngine(): Promise<void> {
    if (AsrService.engine != null) {
      return;
    }
    const extraParams: Record<string, Object> = {
      'locate': 'CN',
      'recognizerMode': 'long',
    };
    const params: speechRecognizer.CreateEngineParams = {
      language: 'zh-CN',
      online: 1,
      extraParams: extraParams,
    };
    const eng = await speechRecognizer.createEngine(params);
    eng.setListener({
      onStart(sessionId: string, eventMessage: string) {},
      onEvent(sessionId: string, eventCode: number, eventMessage: string) {},
      onResult(sessionId: string, result: speechRecognizer.SpeechRecognitionResult) {
        if (!AsrService.validLoop()) {
          return;   // 停止后的在途识别结果：丢弃（这就是"停止后还在出字"的直接来源）
        }
        AsrService.restartAttempts = 0;   // 引擎还在出结果 = 健康，恢复计数清零
        const text = normalize(result.result);
        if (text.length === 0) {
          return;
        }
        AppState.partialText = SubjectLexicon.correct(text, AsrService.subjectKey);
        if (text !== AsrService.lastText) {
          AsrService.lastText = text;
          AsrService.lastChangeAt = Date.now();
        }
        // 关键：isFinal = 引擎判定的整句边界（VAD 断句后给出完整句）
        // 成句只认它，避免中途停顿把半句话当整句收走（截断的根源）
        if (result.isFinal) {
          AsrService.emitFinal(text);
        }
      },
      onComplete(sessionId: string, eventMessage: string) {
        if (!AsrService.validLoop()) {
          return;   // 停止后：不再收尾成句、不再自动续期会话
        }
        // 引擎单次识别结束：收掉尾句并自动续期，保证整节课连续识别不中断
        AsrService.sessionActive = false;
        if (AsrService.lastText.length > 0) {
          AsrService.emitFinal(AsrService.lastText);
        }
        if (AsrService.running && !AsrService.remoteLink()) {
          try {
            AsrService.startListening();
          } catch (e) {
            // 稍后由 finalizeIfIdle 循环的下一轮重试
          }
        }
      },
      onError(sessionId: string, errorCode: number, errorMessage: string) {
        // 会话已异常结束，允许后续重启
        AsrService.sessionActive = false;
        if (!AsrService.validLoop()) {
          return;   // 停止后引擎的报错属收尾噪声：不记日志、不重启、更不降级云端
        }
        // 1002200002 = 重复 startListening，属于自愈过程中的正常碰撞，静默
        if (errorCode === 1002200002) {
          return;
        }
        // 降噪：同一错误 10 秒内只记一条，重复次数折叠
        const key = `${errorCode}|${errorMessage}`;
        const now = Date.now();
        if (key === AsrService.lastErrKey && now - AsrService.lastErrAt < 10000) {
          AsrService.foldedErrCount += 1;
          return;
        }
        const folded = AsrService.foldedErrCount;
        AsrService.foldedErrCount = 0;
        AsrService.lastErrKey = key;
        AsrService.lastErrAt = now;
        AppState.log(`系统识别错误 ${errorCode}: ${errorMessage}${folded > 0 ? `（重复 ${folded} 次已折叠）` : ''}`);
        // 自愈：冷却 3 秒后重启会话；连续 5 次仍不行 -> 降级云端
        if (AsrService.running && !AsrService.remoteLink()) {
          if (now < AsrService.restartCooldownUntil) {
            return;
          }
          AsrService.restartCooldownUntil = now + 3000;
          AsrService.restartAttempts += 1;
          if (AsrService.restartAttempts >= 5) {
            AppState.log('系统识别持续异常，自动切换云端识别');
            const capturer = AsrService.capturer;
            if (AsrService.appCtx != null && capturer != null) {
              AsrService.degradeToCloud(AsrService.appCtx, capturer);
            }
            return;
          }
          const gen = AsrService.sessionGen;
          setTimeout(() => {
            // 世代校验：期间若已停止或重新启动，这个旧的重启动作必须作废
            if (AsrService.running && !AsrService.remoteLink()
              && AsrService.sessionGen === gen) {
              AsrService.cancelSession();
              try {
                AsrService.startListening();
              } catch (e) {
                // 重启失败留给下一轮 onError 处理
              }
            }
          }, 500);
        }
      },
    });
    AsrService.engine = eng;
  }

  private static startListening(): void {
    const eng = AsrService.engine;
    if (eng == null || AsrService.sessionActive) {
      return;
    }
    const extraParams: Record<string, Object> = {
      'recognitionMode': 0, // 0 = 麦克风实时识别
      'vadBegin': 500,
      'vadEnd': VAD_END_MS,
      'maxAudioDuration': MAX_AUDIO_MS,
    };
    const params: speechRecognizer.StartParams = {
      sessionId: AsrService.sessionId,
      audioInfo: {
        audioType: 'pcm',
        sampleRate: SAMPLE_RATE,
        soundChannel: 1,
        sampleBit: 16,
      },
      extraParams: extraParams,
    };
    eng.startListening(params);
    AsrService.sessionActive = true;
  }

  private static cancelSession(): void {
    const eng = AsrService.engine;
    if (eng != null && AsrService.sessionActive) {
      try {
        eng.cancel(AsrService.sessionId);
      } catch (e) {
        // 会话可能已结束
      }
    }
    AsrService.sessionActive = false;
  }

  /** PCM 累积缓冲切成 1280B 块喂引擎，余量留存到下一轮。 */
  private static feedPcm(chunk: Uint8Array): void {
    if (!AsrService.running) {
      AsrService.pending = new Uint8Array(0);
      return;   // 已停止：不再向引擎喂音频
    }
    if (!AsrService.sessionActive) {
      // 会话未激活（startListening 失败 / 正在重启）：此时 writeAudio 必然报
      // 1002200010 Write audio failed because the start listening is failed.
      // 直接丢弃音频，等会话恢复后再喂，避免错误刷屏并挤压自愈流程。
      return;
    }
    if (chunk.length > 0) {
      const merged = new Uint8Array(AsrService.pending.length + chunk.length);
      merged.set(AsrService.pending, 0);
      merged.set(chunk, AsrService.pending.length);
      AsrService.pending = merged;
    }
    const eng = AsrService.engine;
    while (eng != null && AsrService.pending.length >= WRITE_CHUNK_BYTES) {
      const piece = AsrService.pending.slice(0, WRITE_CHUNK_BYTES);
      eng.writeAudio(AsrService.sessionId, piece);
      AsrService.pending = AsrService.pending.slice(WRITE_CHUNK_BYTES);
    }
  }

  /** 兜底成句：正常断句由引擎 vadEnd/isFinal 完成；此计时器仅在引擎事件丢失时起作用。 */
  private static finalizeIfIdle(): void {
    const text = AsrService.lastText;
    if (text.length === 0 || AsrService.lastChangeAt === 0) {
      return;
    }
    if (Date.now() - AsrService.lastChangeAt > FINALIZE_AFTER_MS) {
      AsrService.emitFinal(text);
    }
  }

  private static emitFinal(text: string): void {
    AsrService.lastText = '';
    AsrService.lastChangeAt = 0;
    if (!AsrService.running) {
      AppState.partialText = '';
      return;   // 已停止：不再写入转写历史（stop() 内的收尾句在此之前调用，不受影响）
    }
    if (text === AsrService.lastFinalText) {
      AppState.partialText = '';
      return;
    }
    AsrService.lastFinalText = text;
    AppState.partialText = '';
    AsrService.onFinal(text);
  }

  /** 一句结束：入转写历史 + 写上下文缓冲 + 端侧检测 -> 问题列表。 */
  private static onFinal(raw: string): void {
    // 科目词汇纠正：落库 / 上下文 / 问题检测全部使用纠正后的文本
    const text = SubjectLexicon.correct(raw, AsrService.subjectKey);
    const now = Date.now();
    AppState.addTranscript(text, now);
      TranscriptStore.addLine(text, now);   // 本地保存：整段转写实时落盘（每节课一份记录）
    AppState.log(`成句: ${text}`);
    AppState.buffer.add(text, now);
    // 服务器模式下端侧只做断网兜底；本地模型 / 纯规则模式下端侧是主判定
    const mode = AppState.detectMode;
    if (!AppState.offlineFallback && mode === AppState.DETECT_SERVER) {
      return;
    }
    const hit = AsrService.detector.detect(text, now);
    if (hit.isQuestion) {
      AppState.log(`命中问题: ${hit.text}  conf=${hit.score.toFixed(2)}`);
      AppState.addQuestion(hit.text);
      return;
    }
    // 模糊区（0.25~0.5）交给检测模型复核：只在「本地模型」模式启用
    if (!hit.duplicate && hit.score >= 0.25 && hit.score < 0.5 &&
      mode === AppState.DETECT_LLM) {
      const ctx = AppState.buffer.windowBefore(now, 60000, 600);
      LlmRunner.classify(text, ctx, (yes: boolean) => {
        if (yes && AsrService.running) {
          AppState.log(`检测模型命中问题: ${text}`);
          AppState.addQuestion(text);
        }
      });
    }
  }

  // ---------- 通用 API 识别（OpenAI 兼容 /v1/audio/transcriptions） ----------

  /**
   * 「各家大模型 API」链路。
   *
   * 与 cloud（私有 WSS 流式）本质不同：OpenAI 兼容的语音识别是**HTTP 一次性上传整段音频**，
   * 拿不到真流式，那就把「切成段」和「送出去」两件事都做到最好：
   *
   *   ① **按停顿切**（VAD）：不再按固定时长硬切，「理论力学」不会被腰斩成「理论」「力学」。
   *      说完一句停顿约 0.4s 就提交，出字延迟从 12s 降到 1~3s。
   *   ② **发送流水线**：切好即入队，采集不等待网络；最多 2 个请求在途。
   *      修掉旧实现「等待期间音频继续堆积 → 下一段越来越长」的雪球效应。
   *
   * `asrApiChunkSec` 的语义随之改变：从「每段固定多长」变成「**兜底上限**」——
   * 只在说话人不间断时（朗读、连续念）才会触发强制切一刀。
   */
  private static startApiUpstream(
    ctx: common.UIAbilityContext,
    capturer: audio.AudioCapturer
  ): void {
    AsrService.activeApi = true;
    AsrService.activeCloud = false;   // 切链路时必须清掉另一条的标记（降级路径会先开 API）
    AsrService.resetApiState();
    AppState.log(`API 识别已启动（停顿即切段，兜底上限 ${AppState.asrApiChunkSec}s）`);

    const loop = async (): Promise<void> => {
      // 每块 100ms：16000 * 0.1 * 2 字节 = 3200
      const chunkBytes = SAMPLE_RATE / 10 * 2;
      const maxMs = AppState.asrApiChunkSec * 1000;
      while (AsrService.running && AsrService.activeApi) {
        try {
          const buf = await capturer.read(chunkBytes, true);
          if (!AsrService.validApi()) {
            return;   // 停止瞬间返回的最后一块音频：不再累积
          }
          const chunk = new Uint8Array(buf);
          AsrService.apiPcmBuf = AsrService.concatBytes(AsrService.apiPcmBuf, chunk);
          AsrService.apiSegMs += AsrService.API_TICK_MS;

          // ---- VAD：这块是语音还是静音 ----
          // 三个阈值都**每块现读** AppState —— 用户在设置页调完保存即对本次录音生效
          const rms = AsrService.rmsOf(chunk);
          const th = Math.max(AppState.vadMinRms, AsrService.apiNoise * 3);
          if (rms < th) {
            AsrService.apiSilMs += AsrService.API_TICK_MS;
            // 只在静音窗口更新噪声底：否则说话声会把底噪抬上去，阈值越来越高
            AsrService.apiNoise = AsrService.apiNoise * 0.9 + rms * 0.1;
          } else {
            AsrService.apiHasVoice = true;
            AsrService.apiSilMs = 0;
          }

          // ★ 必须要求「段内出现过语音」：纯静音段不发（见 apiHasVoice 注释）
          const hitSilence = AsrService.apiHasVoice
            && AsrService.apiSilMs >= AppState.vadSilMs
            && AsrService.apiSegMs >= AppState.vadMinSegMs;
          const hitMax = AsrService.apiSegMs >= maxMs;
          if (hitSilence || hitMax) {
            const seg = AsrService.apiPcmBuf;
            const hadVoice = AsrService.apiHasVoice;
            AsrService.apiPcmBuf = new Uint8Array(0);
            AsrService.apiSegMs = 0;
            AsrService.apiSilMs = 0;
            AsrService.apiHasVoice = false;
            if (hadVoice) {
              // ★ 入队即返回 —— 采集绝不等待网络，这是修掉"越等越长"的关键
              AsrService.enqueueApiSegment(seg);
            }
          }
        } catch (e) {
          if (!AsrService.validApi()) {
            return;
          }
          const err = e as Error;
          AppState.log(`采集异常: ${err.message ?? err}`);
          AsrService.running = false;
          return;
        }
      }
      // 循环退出前，把尾段也提交掉（否则最后一句话会丢）。同样要求段内有语音。
      if (AsrService.apiPcmBuf.length > SAMPLE_RATE && AsrService.apiHasVoice) {
        const tail = AsrService.apiPcmBuf;
        AsrService.apiPcmBuf = new Uint8Array(0);
        AsrService.enqueueApiSegment(tail);
      }
    };
    loop();
  }

  /** 重置 API 链路全部状态（start / stop 各调一次，保证跨会话不串味） */
  private static resetApiState(): void {
    AsrService.apiPcmBuf = new Uint8Array(0);
    AsrService.apiSegMs = 0;
    AsrService.apiSilMs = 0;
    AsrService.apiNoise = 200;
    AsrService.apiHasVoice = false;
    AsrService.apiQueue = [];
    AsrService.apiInFlight = 0;
    AsrService.apiSeqNext = 0;
    AsrService.apiSeqOut = 0;
    AsrService.apiPending = new Map<number, string>();
  }

  /**
   * 一段 16bit 小端 PCM 的均方根（0~32767）。
   * 每 4 个采样点抽 1 个 —— 100ms@16k 有 1600 点，抽 400 个足够判定语音/静音，省 CPU。
   */
  private static rmsOf(pcm: Uint8Array): number {
    let sum = 0;
    let cnt = 0;
    for (let i = 0; i + 1 < pcm.length; i += 8) {
      let s = (pcm[i + 1] << 8) | pcm[i];
      if (s >= 32768) {
        s -= 65536;                       // 无符号 → 有符号
      }
      sum += s * s;
      cnt += 1;
    }
    return cnt === 0 ? 0 : Math.sqrt(sum / cnt);
  }

  /** 切好一段就丢进队列，立刻返回（调用方是采集循环，绝不能阻塞它） */
  private static enqueueApiSegment(pcm: Uint8Array): void {
    if (pcm.length < SAMPLE_RATE) {
      return;   // 不足 0.5 秒的碎片忽略：省一次往返，也避免噪音触发空识别
    }
    AsrService.apiQueue.push(pcm);
    AsrService.drainApiQueue();
  }

  /** 消费队列：在途数没到上限就继续发 */
  private static drainApiQueue(): void {
    while (AsrService.apiQueue.length > 0
      && AsrService.apiInFlight < AsrService.API_MAX_INFLIGHT
      && AsrService.validApi()) {
      const pcm = AsrService.apiQueue.shift();
      if (pcm === undefined) {
        break;
      }
      AsrService.submitApiChunk(pcm);
    }
  }

  /**
   * 按序号落字。
   *
   * 并发 2 时两个请求的返回顺序**没有任何保证**，直接 emit 会让文字前后颠倒。
   * 这里先把结果按 seq 存起来，只有轮到「下一个该输出的序号」才真正落字，
   * 顺带把已经就绪的后续段一并补齐。
   */
  private static deliverInOrder(seq: number, text: string): void {
    AsrService.apiPending.set(seq, text);
    while (AsrService.apiPending.has(AsrService.apiSeqOut)) {
      const t = AsrService.apiPending.get(AsrService.apiSeqOut);
      AsrService.apiPending.delete(AsrService.apiSeqOut);
      AsrService.apiSeqOut += 1;
      if (t !== undefined && t.length > 0 && AsrService.validApi()) {
        AsrService.emitFinal(t);
        AppState.partialText = '';
      }
    }
  }

  /** 世代校验：API 链路专用 */
  private static validApi(): boolean {
    return AsrService.running && AsrService.activeApi && AsrService.activeGen === AsrService.sessionGen;
  }

  private static concatBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
    const out = new Uint8Array(a.length + b.length);
    out.set(a, 0);
    out.set(b, a.length);
    return out;
  }

  /** 把 16k/16bit/单声道 PCM 包成 WAV（加 44 字节头） */
  private static pcmToWav(pcm: Uint8Array): Uint8Array {
    const dataLen = pcm.length;
    const out = new Uint8Array(44 + dataLen);
    const dv = new DataView(out.buffer);
    const writeStr = (off: number, s: string): void => {
      for (let i = 0; i < s.length; i++) {
        out[off + i] = s.charCodeAt(i);
      }
    };
    writeStr(0, 'RIFF');
    dv.setUint32(4, 36 + dataLen, true);
    writeStr(8, 'WAVE');
    writeStr(12, 'fmt ');
    dv.setUint32(16, 16, true);            // fmt chunk 长度
    dv.setUint16(20, 1, true);             // PCM
    dv.setUint16(22, 1, true);             // 单声道
    dv.setUint32(24, SAMPLE_RATE, true);   // 采样率
    dv.setUint32(28, SAMPLE_RATE * 2, true); // 字节率 = 采样率 * 声道 * 位深/8
    dv.setUint16(32, 2, true);             // 块对齐
    dv.setUint16(34, 16, true);            // 位深
    writeStr(36, 'data');
    dv.setUint32(40, dataLen, true);
    out.set(pcm, 44);
    return out;
  }

  /**
   * 提交一段音频给 API 识别（multipart/form-data）。
   *
   * 调用方是 `drainApiQueue()`，入队长度与在途数已在那里校验过，这里只管发。
   * 请求结束（成功或失败）时扣减在途数并回冲队列 —— 流水线靠这一环自驱。
   */
  private static submitApiChunk(pcm: Uint8Array): void {
    if (!AsrService.validApi()) {
      return;
    }
    const seq = AsrService.apiSeqNext;
    AsrService.apiSeqNext += 1;
    AsrService.apiInFlight += 1;
    const wav = AsrService.pcmToWav(pcm);
    const boundary = '----sktBoundary' + Date.now().toString(16);

    // 手动拼 multipart body（鸿蒙 http 的 extraData 支持 ArrayBuffer）
    const parts: string[] = [];
    parts.push(`--${boundary}\r\n`);
    parts.push(`Content-Disposition: form-data; name="file"; filename="chunk.wav"\r\n`);
    parts.push(`Content-Type: audio/wav\r\n\r\n`);
    const head = new Uint8Array(AsrService.asciiBytes(parts.join('')));
    const midStr = `\r\n--${boundary}\r\n`
      + `Content-Disposition: form-data; name="model"\r\n\r\n${AppState.asrApiModel}\r\n`
      + `--${boundary}\r\n`
      + `Content-Disposition: form-data; name="language"\r\n\r\nzh\r\n`
      + `--${boundary}--\r\n`;
    const tail = new Uint8Array(AsrService.asciiBytes(midStr));

    const body = new Uint8Array(head.length + wav.length + tail.length);
    body.set(head, 0);
    body.set(wav, head.length);
    body.set(tail, head.length + wav.length);

    const hdr: Record<string, string> = {
      'Content-Type': `multipart/form-data; boundary=${boundary}`,
      'Authorization': `Bearer ${AppState.asrApiKey}`,
    };
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: hdr,
      extraData: body.buffer,
      expectDataType: http.HttpDataType.STRING,
      readTimeout: 60000,
      connectTimeout: 20000,
    };
    const req = http.createHttp();
    req.request(AsrService.asrApiEndpoint(), options)
      .then((resp: http.HttpResponse) => {
        req.destroy();
        AsrService.apiInFlight -= 1;
        if (resp.responseCode !== 200) {
          if (AsrService.validApi()) {
            AppState.log(`API 识别失败 HTTP ${resp.responseCode}: ${String(resp.result).substring(0, 200)}`);
          }
          // ★ 失败也必须推进序号（交空串）：否则后面的段永远等不到自己的轮次，整条流水线卡死
          AsrService.deliverInOrder(seq, '');
          AsrService.drainApiQueue();
          return;
        }
        AsrService.deliverInOrder(seq, AsrService.pickText(String(resp.result)));
        AsrService.drainApiQueue();
      })
      .catch((e: Error) => {
        req.destroy();
        AsrService.apiInFlight -= 1;
        if (AsrService.validApi()) {
          AppState.log(`API 识别异常: ${e.message ?? e}`);
        }
        AsrService.deliverInOrder(seq, '');
        AsrService.drainApiQueue();
      });
  }

  /** 从响应里取识别文本：兼容 {text} 与 {choices[0].message.content} 两种常见形状 */
  private static pickText(raw: string): string {
    try {
      const o: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      const t = o['text'];
      if (typeof t === 'string' && t.length > 0) {
        return t;
      }
      const msg = o['message'];
      if (typeof msg === 'string' && msg.length > 0) {
        return msg;
      }
    } catch (e) {
      // 非 JSON：有些服务直接返回纯文本
      const s = raw.trim();
      if (s.length > 0 && s.indexOf('{') !== 0) {
        return s;
      }
    }
    return '';
  }

  /** 拼 endpoint：base_url 已规范化（不含 /v1），补 /v1/audio/transcriptions */
  private static asrApiEndpoint(): string {
    let u = AppState.asrApiBaseUrl.trim().replace(/\/+$/, '');
    if (u.length === 0) {
      return u;
    }
    if (/\/audio\/transcriptions$/i.test(u)) {
      return u;   // 已是完整端点
    }
    if (/\/v[1-9]\/?$/i.test(u)) {
      return u.replace(/\/+$/, '') + '/audio/transcriptions';
    }
    return u + '/v1/audio/transcriptions';
  }

  /** 字符串转 ASCII 字节（multipart 头都是 ASCII，避免 TextEncoder 兼容问题） */
  private static asciiBytes(s: string): Uint8Array {
    const out = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) {
      out[i] = s.charCodeAt(i) & 0xFF;
    }
    return out;
  }

  // ---------- 云端 ASR（voice.xsheep.cn） ----------

  private static startCloudUpstream(
    ctx: common.UIAbilityContext,
    capturer: audio.AudioCapturer
  ): void {
    AsrService.activeCloud = true;
    AsrService.activeApi = false;   // 切链路时必须清掉另一条的标记
    const ws = webSocket.createWebSocket();
    AsrService.cloudWs = ws;
    AsrService.cloudConnected = false;

    ws.on('open', () => {
      if (!AsrService.validCloud()) {
        try {
          ws.close();   // 已停止 / 已换链路：连接建立即关闭，不握手不上行
        } catch (e) {
          // ignore
        }
        return;
      }
      // 握手 JSON 先行（服务端要求首帧为 JSON 文本）
      // 握手带上科目热词（服务端支持热词增强时直接提升识别率）
      const hw = SubjectLexicon.hotwords(AsrService.subjectKey);
      const hello = new CloudHello();
      if (hw.length > 0) {
        hello.hotwords = hw;
      }
      ws.send(JSON.stringify(hello));
      AsrService.cloudConnected = true;
      AsrService.cloudFailCount = 0;
      AppState.log('云端 ASR 已连接');
    });
    ws.on('message', (_err: Error, value: string | ArrayBuffer) => {
      if (typeof value !== 'string') {
        return;
      }
      if (!AsrService.validCloud()) {
        return;   // 停止后（或已切回系统识别）服务端残留帧：丢弃，不回写部分结果
      }
      try {
        const o: Record<string, Object> = JSON.parse(value) as Record<string, Object>;
        const type = typeof o['type'] === 'string' ? o['type'] as string : '';
        const text = typeof o['text'] === 'string' ? o['text'] as string : '';
        if (type === 'partial' && text.length > 0) {
          AppState.partialText = SubjectLexicon.correct(text, AsrService.subjectKey);
        } else if (type === 'final' && text.length > 0) {
          AsrService.emitFinal(text);
        } else if (type === 'error') {
          const msg = typeof o['msg'] === 'string' ? o['msg'] as string : 'unknown';
          AppState.log(`云端 ASR 错误: ${msg}`);
        }
      } catch (e) {
        // 非 JSON 帧忽略
      }
    });
    ws.on('error', (err: Error) => {
      AppState.log(`云端 ASR 连接失败: ${err.message ?? err}`);
      AsrService.handleCloudFailure(ctx, capturer);
    });
    ws.on('close', () => {
      AsrService.cloudConnected = false;
      if (AsrService.running && AsrService.activeCloud) {
        AsrService.handleCloudFailure(ctx, capturer);
      }
    });

    ws.connect(AppState.cloudAsrUrl)
      .then(() => {
        // open 事件里握手
      })
      .catch((e: Error) => {
        AppState.log(`云端 ASR 连接失败: ${e.message ?? e}`);
        AsrService.handleCloudFailure(ctx, capturer);
      });

    // 采集循环：PCM16 原样上行
    const loop = async (): Promise<void> => {
      const chunkBytes = SAMPLE_RATE / 10 * 2;
      while (AsrService.running && AsrService.activeCloud) {
        try {
          const buf = await capturer.read(chunkBytes, true);
          if (!AsrService.validCloud()) {
            return;   // 停止瞬间返回的最后一块音频：不再上行
          }
          if (!AsrService.cloudConnected) {
            continue; // 握手完成前丢弃音频
          }
          ws.send(buf);
        } catch (e) {
          if (!AsrService.validCloud()) {
            return;   // 停止 / 切换链路导致的 read 异常：正常收尾，不记日志不降级
          }
          const err = e as Error;
          AppState.log(`采集异常: ${err.message ?? err}`);
          AsrService.running = false;
          return;
        }
      }
    };
    loop();
  }

  private static closeCloud(): void {
    const ws = AsrService.cloudWs;
    if (ws != null) {
      AsrService.cloudWs = null;
      AsrService.cloudConnected = false;
      try {
        ws.close();
      } catch (e) {
        // ignore
      }
    }
  }

  /** 云端连续失败 2 次 -> 回退系统识别；系统也连续失败 2 次则整体停止。 */
  private static handleCloudFailure(ctx: common.UIAbilityContext, capturer: audio.AudioCapturer): void {
    if (!AsrService.running || !AsrService.activeCloud) {
      return;
    }
    AsrService.cloudFailCount += 1;
    if (AsrService.cloudFailCount < 2) {
      AppState.log('云端 ASR 暂不可用，将继续尝试…');
      return;
    }
    if (AsrService.sysFailCount >= 2) {
      AppState.log('系统识别与云端均不可用，请检查设备语音服务或网络');
      AsrService.running = false;
      AsrService.sessionGen += 1;   // 彻底自停：作废在途回调并释放麦克风
      AsrService.releaseCapture();
      return;
    }
    AppState.log('云端识别连续失败，回退系统识别');
    AsrService.closeCloud();
    AsrService.activeCloud = false;
    AsrService.activeApi = false;   // 明确清掉 API 标记，系统链路守卫才能放行
    AsrService.startSystemAsr(ctx, capturer);
  }

  /**
   * 系统识别失败时降级（不改用户设置，仅本会话生效）。
   * - API 模式：已配置通用 API 时回退到 API 链路（同为远程，且用户已填好凭证）；
   *   未配置则回退私有云端 WSS。
   * - 其余情况回退云端 WSS。
   */
  private static degradeToCloud(ctx: common.UIAbilityContext, capturer: audio.AudioCapturer): void {
    AsrService.closeCloud();
    AsrService.cloudFailCount = 0;
    if (AppState.asrMode === 'api' && AppState.asrApiBaseUrl.trim().length > 0) {
      AppState.log('系统识别不可用，回退通用 API 识别');
      AsrService.startApiUpstream(ctx, capturer);
      return;
    }
    AsrService.startCloudUpstream(ctx, capturer);
  }
}

function normalize(raw: string): string {
  const t = raw.trim();
  if (t.length === 0) {
    return '';
  }
  let cjk = 0;
  for (let i = 0; i < t.length; i++) {
    const c = t.charCodeAt(i);
    if (c >= 0x4e00 && c <= 0x9fff) {
      cjk += 1;
    }
  }
  if (cjk * 2 > t.length) {
    return t.replace(/\s+/g, '');
  }
  return t;
}
