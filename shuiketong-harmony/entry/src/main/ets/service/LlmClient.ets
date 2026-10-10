import { http } from '@kit.NetworkKit';

/** 流式事件：正文增量 or 思考（reasoning）增量。 */
export class StreamEvent {
  static readonly KIND_DELTA = 0;
  static readonly KIND_REASONING = 1;

  kind: number = StreamEvent.KIND_DELTA;
  text: string = '';

  constructor(kind: number, text: string) {
    this.kind = kind;
    this.text = text;
  }
}

type EvCallback = (ev: StreamEvent) => void;
type ErrCallback = (err: Error) => void;
type DoneCallback = () => void;

interface ChatMessage {
  role: string;
  content: string;
}

interface ChatBody {
  model: string;
  stream: boolean;
  temperature: number;
  enable_thinking?: boolean;
  messages: ChatMessage[];
}

/** SSE 行缓冲解析器：把 chunk 流切成 data: 行。 */
class SseParser {
  private buf: string = '';

  feed(chunkText: string, onLine: (data: string) => void): void {
    this.buf += chunkText;
    for (; ;) {
      const idx = this.buf.indexOf('\n');
      if (idx < 0) {
        break;
      }
      const line = this.buf.substring(0, idx).replace(/\r$/, '');
      this.buf = this.buf.substring(idx + 1);
      if (line.startsWith('data:')) {
        onLine(line.substring(5).trim());
      }
    }
  }
}

/**
 * OpenAI 兼容 /v1/chat/completions 流式客户端（客户端直连，apikey 只在本机）。
 * reasoning 字段兼容 reasoning_content（DeepSeek/Qwen）与 reasoning（OpenRouter）。
 */
export class LlmClient {
  private baseUrl: string;
  private apiKey: string;
  private model: string;

  constructor(baseUrl: string, apiKey: string, model: string) {
    this.baseUrl = baseUrl.replace(/\/+$/, '');
    this.apiKey = apiKey;
    this.model = model;
  }

  streamChat(
    systemPrompt: string,
    userText: string,
    thinking: boolean,
    onEvent: EvCallback,
    onError: ErrCallback,
    onDone: DoneCallback
  ): void {
    // enable_thinking 是通义/Qwen 系私有字段：被服务端拒绝（4xx）时去掉该字段自动重试一次，
    // 否则用户只会看到一句莫名其妙的接口报错。
    this.send(systemPrompt, userText, thinking, true, onEvent, onError, onDone);
  }

  private send(
    systemPrompt: string, userText: string, thinking: boolean, allowRetry: boolean,
    onEvent: EvCallback, onError: ErrCallback, onDone: DoneCallback
  ): void {
    const msgs: ChatMessage[] = [
      { role: 'system', content: systemPrompt },
      { role: 'user', content: userText },
    ];
    const body: ChatBody = {
      model: this.model,
      stream: true,
      temperature: 0.2,
      messages: msgs,
    };
    if (thinking) {
      body.enable_thinking = true;   // Qwen3 系开关；DeepSeek-R1 默认输出思考
    }

    const httpRequest = http.createHttp();
    const parser = new SseParser();
    let done = false;
    // 边流边收：同时留一份原文，用于"服务没按 SSE 返回"时的兜底解析
    let rawAll = '';
    let emitted = false;

    const finish = () => {
      if (!done) {
        done = true;
        onDone();
      }
    };

    httpRequest.on('dataReceive', (chunk: ArrayBuffer | string) => {
      let text: string;
      if (typeof chunk === 'string') {
        text = chunk;
      } else {
        text = LlmClient.decode(chunk as ArrayBuffer);
      }
      if (rawAll.length < 400000) {
        rawAll += text;
      }
      parser.feed(text, (payload) => {
        if (payload === '[DONE]') {
          httpRequest.destroy();
          finish();
          return;
        }
        const ev = LlmClient.parseDelta(payload);
        if (ev != null) {
          emitted = true;
          onEvent(ev);
        }
      });
    });
    httpRequest.on('dataEnd', () => {
      if (!emitted) {
        const whole = LlmClient.parseWholeBody(rawAll);
        if (whole != null) {
          onEvent(whole);
        }
      }
      httpRequest.destroy();
      finish();
    });

    const hdr: Record<string, string> = {
      'Authorization': `Bearer ${this.apiKey}`,
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
      'Cache-Control': 'no-store',
    };
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: hdr,
      extraData: JSON.stringify(body),
      expectDataType: http.HttpDataType.STRING,
      readTimeout: thinking ? 180000 : 60000,
      connectTimeout: 10000,
    };

    httpRequest.requestInStream(this.endpoint(), options)
      .then(() => {
        // 请求已发出；结果异步回调
      }).catch((e: Error) => {
        httpRequest.destroy();
        if (done) {
          return;
        }
        const msg = e == null ? '' : (e.message ?? '');
        // 私有字段被拒 → 去掉 enable_thinking 重试（requestInStream 非 2xx 走 reject）
        if (thinking && allowRetry && msg.indexOf('4') >= 0) {
          done = true;
          this.send(systemPrompt, userText, false, false, onEvent, onError, onDone);
          return;
        }
        done = true;
        onError(e);
      });
  }

  /**
   * 端点拼接容错：base_url 带 /v1 或不带都行，已经是完整端点也原样使用。
   *   https://h        → https://h/v1/chat/completions
   *   https://h/v1     → https://h/v1/chat/completions
   *   https://h/a/v1   → https://h/a/v1/chat/completions
   */
  private endpoint(): string {
    const b = this.baseUrl;
    if (b.endsWith('/chat/completions')) {
      return b;
    }
    if (/\/v\d+$/.test(b)) {
      return b + '/chat/completions';
    }
    return b + '/v1/chat/completions';
  }

  /** 非流式兜底：整段 JSON 里取正文（message.content / text / output_text） */
  private static parseWholeBody(raw: string): StreamEvent | null {
    const s = raw.trim();
    if (s.length === 0 || !s.startsWith('{')) {
      return null;
    }
    try {
      const obj: Record<string, Object> = JSON.parse(s) as Record<string, Object>;
      const choices = obj['choices'] as Array<Record<string, Object>>;
      if (choices != null && choices.length > 0) {
        const msg = choices[0]['message'] as Record<string, Object>;
        if (msg != null) {
          const c = LlmClient.strOr(msg, 'content', '');
          if (c.length > 0) {
            return new StreamEvent(StreamEvent.KIND_DELTA, c);
          }
        }
        const t = LlmClient.strOr(choices[0], 'text', '');
        if (t.length > 0) {
          return new StreamEvent(StreamEvent.KIND_DELTA, t);
        }
      }
      const ot = LlmClient.strOr(obj, 'output_text', '');
      if (ot.length > 0) {
        return new StreamEvent(StreamEvent.KIND_DELTA, ot);
      }
      const err = obj['error'] as Record<string, Object>;
      if (err != null) {
        const em = LlmClient.strOr(err, 'message', '');
        if (em.length > 0) {
          return new StreamEvent(StreamEvent.KIND_DELTA, `[接口错误] ${em}`);
        }
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  private static decode(buf: ArrayBuffer): string {
    const u8 = new Uint8Array(buf);
    let out = '';
    let i = 0;
    while (i < u8.length) {
      const b = u8[i];
      if (b < 0x80) {
        out += String.fromCharCode(b);
        i += 1;
      } else if (b < 0xe0) {
        out += String.fromCharCode(((b & 0x1f) << 6) | (u8[i + 1] & 0x3f));
        i += 2;
      } else if (b < 0xf0) {
        out += String.fromCharCode(((b & 0x0f) << 12) | ((u8[i + 1] & 0x3f) << 6) | (u8[i + 2] & 0x3f));
        i += 3;
      } else {
        const cp = ((b & 0x07) << 18) | ((u8[i + 1] & 0x3f) << 12) | ((u8[i + 2] & 0x3f) << 6) | (u8[i + 3] & 0x3f);
        const off = cp - 0x10000;
        out += String.fromCharCode(0xd800 + (off >> 10), 0xdc00 + (off & 0x3ff));
        i += 4;
      }
    }
    return out;
  }

  private static parseDelta(payload: string): StreamEvent | null {
    try {
      const obj: Record<string, Object> = JSON.parse(payload) as Record<string, Object>;
      const choices = obj['choices'] as Array<Record<string, Object>>;
      if (choices == null || choices.length === 0) {
        return null;
      }
      // 流式走 delta；有的服务在流里夹带整体 message（或最后一帧给完整文本）
      const delta = choices[0]['delta'] as Record<string, Object>;
      const msg = choices[0]['message'] as Record<string, Object>;
      const node = delta != null ? delta : msg;
      if (node == null) {
        const t = LlmClient.strOr(choices[0], 'text', '');
        return t.length > 0 ? new StreamEvent(StreamEvent.KIND_DELTA, t) : null;
      }
      const reasoning = LlmClient.strOr(node, 'reasoning_content', '')
        .length > 0 ? LlmClient.strOr(node, 'reasoning_content', '')
        : LlmClient.strOr(node, 'reasoning', '');
      if (reasoning.length > 0) {
        return new StreamEvent(StreamEvent.KIND_REASONING, reasoning);
      }
      const content = LlmClient.strOr(node, 'content', '');
      if (content.length > 0) {
        return new StreamEvent(StreamEvent.KIND_DELTA, content);
      }
      const t2 = LlmClient.strOr(choices[0], 'text', '');
      return t2.length > 0 ? new StreamEvent(StreamEvent.KIND_DELTA, t2) : null;
    } catch (e) {
      return null;
    }
  }

  private static strOr(obj: Record<string, Object>, key: string, fallback: string): string {
    const v = obj[key];
    return typeof v === 'string' ? v as string : fallback;
  }
}