import { AppState, QuestionItem } from '../common/AppState';
import { LlmClient, StreamEvent } from './LlmClient';
import { TranscriptBuffer } from './TranscriptBuffer';

/**
 * 垂询执行器：点「垂询」-> 组装「问题前 90 秒相关上下文(600字) + 提示词」-> 流式问答。
 * 结果写回 AppState.questions；同一时间只跑一道题。
 */
export class LlmRunner {
  private static runningId: number = -1;
  private static busy: boolean = false;

  static isBusy(): boolean {
    return LlmRunner.busy;
  }

  static ask(questionId: number, question: string, contextText: string, thinking: boolean): void {
    if (LlmRunner.busy) {
      return;
    }
    const base = AppState.llmBaseUrl.trim();
    const key = AppState.llmApiKey.trim();
    const model = AppState.llmModel.trim();
    if (base.length === 0 || key.length === 0 || model.length === 0) {
      AppState.updateQuestion(questionId, (q: QuestionItem) => {
        q.answer = '请先在「设置」里填好大语言模型的 base_url / api_key / model。';
        q.done = true;
      });
      return;
    }

    LlmRunner.busy = true;
    LlmRunner.runningId = questionId;
    AppState.updateQuestion(questionId, (q: QuestionItem) => {
      q.reasoning = '';
      q.answer = '';
      q.answering = true;
      q.done = false;
    });

    const ctx = contextText.trim();
    const sysPrompt =
      '你是知课笺助手：用户正在上课/开会，系统从语音转写中检测到老师提出的问题或点名互动' +
      '（例如「谁来回答」「这位同学你来回答一下」「点个名」）。' +
      '转写上下文可能包含口语和识别噪声，请结合上下文判断老师的真实问题。' +
      '如果是点名/找人回答场景，基于上下文推断老师此刻想考察的内容，' +
      '给出一个学生视角可直接说出口的回答。' +
      '用中文回答：先给结论/答案，再给简要解释；选择题明确给选项；保持简洁可直接朗读。';
    const userPrompt = ctx.length > 0
      ? `以下是问题出现前的课堂转写上下文：\n---\n${ctx}\n---\n\n老师的提问/点名：${question}`
      : question;

    const client = new LlmClient(base, key, model);
    client.streamChat(
      sysPrompt,
      userPrompt,
      thinking,
      (ev: StreamEvent) => {
        if (ev.kind === StreamEvent.KIND_DELTA) {
          AppState.updateQuestion(questionId, (q: QuestionItem) => {
            q.answer += ev.text;
          });
        } else {
          AppState.updateQuestion(questionId, (q: QuestionItem) => {
            q.reasoning += ev.text;
          });
        }
      },
      (err: Error) => {
        LlmRunner.busy = false;
        AppState.updateQuestion(questionId, (q: QuestionItem) => {
          q.answer += `\n[错误] ${err.message ?? '未知'}`;
          q.answering = false;
          q.done = true;
        });
      },
      () => {
        LlmRunner.busy = false;
        AppState.updateQuestion(questionId, (q: QuestionItem) => {
          q.answering = false;
          q.done = true;
        });
      }
    );
  }

  /**
   * 通用补全（「一键整理」这类整段文本任务用）—— 与 ask 相互独立，不占用答题状态。
   * @param onDone (err, 完整文本)；err 为空串表示成功
   */
  static complete(sysPrompt: string, userPrompt: string,
                  onDelta: (s: string) => void,
                  onDone: (err: string, full: string) => void): void {
    const base = AppState.llmBaseUrl.trim();
    const key = AppState.llmApiKey.trim();
    const model = AppState.llmModel.trim();
    if (base.length === 0 || key.length === 0 || model.length === 0) {
      onDone('请先在「设置」里填好大语言模型的 base_url / api_key / model', '');
      return;
    }
    let full = '';
    const client = new LlmClient(base, key, model);
    client.streamChat(
      sysPrompt,
      userPrompt,
      false,
      (ev: StreamEvent) => {
        if (ev.kind === StreamEvent.KIND_DELTA) {
          full += ev.text;
          onDelta(ev.text);
        }
      },
      (err: Error) => {
        onDone(err.message ?? '未知错误', full);
      },
      () => {
        onDone('', full);
      }
    );
  }

  /** 取一套连接参数：shared = 与答题共用；false = 检测专用 */
  private static configFor(shared: boolean): string[] {
    return shared
      ? [AppState.llmBaseUrl.trim(), AppState.llmApiKey.trim(), AppState.llmModel.trim()]
      : [AppState.detectBaseUrl.trim(), AppState.detectApiKey.trim(), AppState.detectModel.trim()];
  }

  /** 检测通道是否配置完整 */
  static detectReady(): boolean {
    const c = LlmRunner.configFor(AppState.detectShared);
    return c[0].length > 0 && c[1].length > 0 && c[2].length > 0;
  }

  /** 检测判定节流：同一时刻只跑一个（模糊区可能连着来好几句），否则请求堆积 */
  private static classifyBusy: boolean = false;
  private static lastClassifyText: string = '';

  /**
   * 问题检测用判定：判断一句转写是不是「老师向学生提出的问题或点名互动」。
   * 走检测专用配置（可与答题模型不同），结果通过回调给出。
   */
  static classify(text: string, contextText: string, onResult: (yes: boolean) => void): void {
    if (LlmRunner.classifyBusy || text === LlmRunner.lastClassifyText) {
      return;   // 已在判定中 / 同一句已判过：丢弃，不排队
    }
    const c = LlmRunner.configFor(AppState.detectShared);
    if (c[0].length === 0 || c[1].length === 0 || c[2].length === 0) {
      AppState.log('检测模型未配置，跳过 LLM 复核');
      onResult(false);
      return;
    }
    const sys =
      '你是课堂语音转写的问题判定器。判断给定内容是否是「老师向学生提出的问题或点名互动」' +
      '（提问、追问、找人回答、点名都算；学生自语、陈述句、老师自问自答、口头禅不算）。' +
      '只回答 YES 或 NO，不要任何其他内容。';
    const user = contextText.trim().length > 0
      ? `上下文：\n---\n${contextText}\n---\n\n待判定：${text}`
      : `待判定：${text}`;
    LlmRunner.classifyBusy = true;
    LlmRunner.lastClassifyText = text;
    let full = '';
    const client = new LlmClient(c[0], c[1], c[2]);
    client.streamChat(
      sys,
      user,
      false,
      (ev: StreamEvent) => {
        if (ev.kind === StreamEvent.KIND_DELTA) {
          full += ev.text;
        }
      },
      (err: Error) => {
        LlmRunner.classifyBusy = false;
        AppState.log(`检测模型失败: ${err.message ?? '未知'}`);
        onResult(false);
      },
      () => {
        LlmRunner.classifyBusy = false;
        const yes = LlmRunner.parseYesNo(full);
        AppState.log(`检测模型判定: ${yes ? '是问题' : '非问题'}（${text}）`);
        onResult(yes);
      }
    );
  }

  /**
   * 解析模型的 YES/NO。
   * 中文模型经常回「是的」「是问题」「否」「不是」而不是字面的 YES/NO，
   * 直接 contains('YES') 会大量误判 —— 这里按"否定优先 + 多写法兼容"处理。
   */
  private static parseYesNo(raw: string): boolean {
    const t = raw.trim().toUpperCase();
    if (t.length === 0) {
      return false;
    }
    const negative: string[] = ['不是问题', '不属于', '不算', '非问题', '并非', '不是', 'NO', '否'];
    const positive: string[] = ['是问题', '属于问题', 'YES', '是', '正确', '对'];
    for (const k of negative) {
      if (t.indexOf(k) >= 0) {
        return false;
      }
    }
    for (const k of positive) {
      if (t.indexOf(k) >= 0) {
        return true;
      }
    }
    return t.startsWith('1') || t.startsWith('Y');
  }

  /** 便捷：从问题自动取相关上下文再垂询。 */
  static askFromItem(item: QuestionItem, thinking: boolean): void {
    const ctx = AppState.buffer.windowBefore(item.ts, 90000, 600);
    LlmRunner.ask(item.id, item.text, ctx, thinking);
  }
}