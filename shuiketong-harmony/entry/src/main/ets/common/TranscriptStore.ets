import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { LlmRunner } from '../service/LlmRunner';

/** 一条已成句的转写 */
export class TrLine {
  text: string = '';
  ts: number = 0;

  constructor(text: string, ts: number) {
    this.text = text;
    this.ts = ts;
  }
}

/** 一次转写会话（通常 = 一节课） */
export class TrSession {
  id: string = '';
  title: string = '';
  startMs: number = 0;
  endMs: number = 0;
  lines: TrLine[] = [];
  /** 「一键整理」结果（LLM 生成的结构化笔记） */
  summary: string = '';
  summaryAt: number = 0;

  constructor(id: string, title: string, startMs: number) {
    this.id = id;
    this.title = title;
    this.startMs = startMs;
  }

  plainText(): string {
    const out: string[] = [];
    for (const l of this.lines) {
      out.push(l.text);
    }
    return out.join('\n');
  }

  durationText(): string {
    const end = this.endMs > 0 ? this.endMs : Date.now();
    const m = Math.floor((end - this.startMs) / 60000);
    const mm = m < 0 ? 0 : m;
    return mm >= 60 ? `${Math.floor(mm / 60)} 小时 ${mm % 60} 分` : `${mm} 分钟`;
  }
}

const K_CURRENT = 'trCurrent';
const K_HISTORY = 'trHistory';
const MAX_SESSIONS = 50;
const MAX_LINES = 800;

/**
 * 转写本地存储（鸿蒙）—— 与安卓端 `util/TranscriptStore.kt` 同构。
 *
 * 设计要点：
 * - **按会话存**：每节课一份记录（startSession / endSession）；
 * - **实时落盘**：addLine 防抖写 preferences（1.5s），应用被杀也基本不丢；
 * - 当前会话与历史分开存：当前会话频繁写、历史会话只在归档/删除时写；
 * - 「一键整理」：整段转写交给 LLM 生成结构化笔记，结果写回该会话的 summary。
 */
export class TranscriptStore {

  static sessions: TrSession[] = [];
  static current: TrSession | null = null;
  static version: number = 0;

  private static prefs: preferences.Preferences | null = null;
  private static lastFlush: number = 0;
  private static listeners: Array<() => void> = [];

  static async init(ctx: common.UIAbilityContext): Promise<void> {
    if (TranscriptStore.prefs != null) {
      return;
    }
    TranscriptStore.prefs = await preferences.getPreferences(ctx, 'skt_prefs');
    await TranscriptStore.loadHistory();
    await TranscriptStore.loadCurrent();
  }

  static onChange(cb: () => void): void {
    TranscriptStore.listeners.push(cb);
  }

  private static notify(): void {
    TranscriptStore.version += 1;
    for (const cb of TranscriptStore.listeners) {
      cb();
    }
  }

  // ---------- 会话 ----------

  /** 开始一次转写会话（上一个未归档的先归档） */
  static startSession(title: string = ''): void {
    const c = TranscriptStore.current;
    if (c != null) {
      if (c.lines.length === 0) {
        TranscriptStore.current = null;
      } else {
        if (c.endMs === 0) {
          c.endMs = Date.now();
        }
        TranscriptStore.archive(c);
        TranscriptStore.current = null;
      }
    }
    const now = Date.now();
    const t = title.length > 0 ? title : TranscriptStore.defaultTitle(now);
    TranscriptStore.current = new TrSession(now.toString(), t, now);
    TranscriptStore.flushCurrent();
    TranscriptStore.notify();
  }

  /** 实时追加一行 */
  static addLine(text: string, ts: number = Date.now()): void {
    const t = text.trim();
    if (t.length === 0) {
      return;
    }
    let c = TranscriptStore.current;
    if (c == null) {
      TranscriptStore.startSession();
      c = TranscriptStore.current;
      if (c == null) {
        return;
      }
    }
    c.lines.push(new TrLine(t, ts));
    if (c.lines.length > MAX_LINES) {
      c.lines.shift();
    }
    const now = Date.now();
    if (now - TranscriptStore.lastFlush > 1500) {
      TranscriptStore.lastFlush = now;
      TranscriptStore.flushCurrent();
    }
    TranscriptStore.notify();
  }

  static endSession(): void {
    const c = TranscriptStore.current;
    if (c == null) {
      return;
    }
    c.endMs = Date.now();
    if (c.lines.length > 0) {
      TranscriptStore.archive(c);
    }
    TranscriptStore.current = null;
    TranscriptStore.flushCurrent();
    TranscriptStore.saveHistory();
    TranscriptStore.notify();
  }

  /** 历史会话（新的在前） */
  static list(): TrSession[] {
    const out = TranscriptStore.sessions.slice();
    out.sort((a: TrSession, b: TrSession) => b.startMs - a.startMs);
    return out;
  }

  static delete(id: string): void {
    TranscriptStore.sessions = TranscriptStore.sessions.filter((s: TrSession) => s.id !== id);
    TranscriptStore.saveHistory();
    TranscriptStore.notify();
  }

  static clearAll(): void {
    TranscriptStore.sessions = [];
    TranscriptStore.current = null;
    TranscriptStore.saveHistory();
    TranscriptStore.saveCurrent();
    TranscriptStore.notify();
  }

  /**
   * 从外部（碰一碰分享 / 导出文件）导入一份转写记录，存为**新增的历史记录**。
   *
   * 与 startSession/endSession 的区别：这里不碰 current（不影响正在进行的转写），
   * 直接构造一条已归档会话塞进 sessions。id 用时间戳 + 随机尾，避免与既有 id 撞车
   * （连续导入两份时 startMs 可能一样）。
   *
   * @returns 新记录的 id；存储未就绪（prefs 为 null）时返回 ''
   */
  static async importSession(title: string, startMs: number, endMs: number,
    lines: string[], summary: string): Promise<string> {
    if (TranscriptStore.prefs == null) {
      return '';
    }
    const now = Date.now();
    const start = startMs > 0 ? startMs : now;
    const id = `${start}_${Math.floor(Math.random() * 100000)}`;
    const t = title.length > 0 ? title : TranscriptStore.defaultTitle(start);
    const s = new TrSession(id, t, start);
    s.endMs = endMs > start ? endMs : start;
    s.summary = summary;
    s.summaryAt = summary.length > 0 ? now : 0;
    for (const one of lines) {
      const tx = one.trim();
      if (tx.length > 0) {
        s.lines.push(new TrLine(tx, start));
      }
    }
    if (s.lines.length === 0 && s.summary.length === 0) {
      return '';
    }
    TranscriptStore.archive(s);
    TranscriptStore.notify();
    return id;
  }

  // ---------- 一键整理 ----------

  /**
   * 用 LLM 把某次转写整理成结构化笔记。
   * @param id 会话 id；空串 = 当前正在记录的会话
   */
  static async summarize(id: string, onDelta: (s: string) => void, onDone: (err: string) => void): Promise<void> {
    const s = id.length === 0 ? TranscriptStore.current : TranscriptStore.find(id);
    if (s == null) {
      onDone('找不到该转写记录');
      return;
    }
    let text = s.plainText().trim();
    if (text.length === 0) {
      onDone('这次转写还没有内容');
      return;
    }
    if (text.length > 12000) {
      text = text.substring(text.length - 12000);
    }
    const sys = '你是知课笺的课堂笔记助手。用户会给你一段课堂语音转写（含口语、重复、识别噪声）。'
      + '请把它整理成**结构化课堂笔记**，要求：\n'
      + '1. 用 Markdown 分点，按知识点/主题分段，给每段加小标题；\n'
      + '2. 去掉口语与重复，把老师的话改写成书面表达；\n'
      + '3. 保留关键定义、公式、结论、例子，标注【重点】；\n'
      + '4. 若老师提出过问题，单列一节「课堂问答」；\n'
      + '5. 最后用 2-3 句总结这节课讲了什么。\n'
      + '只输出整理后的笔记，不要解释你的做法。';
    const user = '以下是课堂转写原文（可能不完整）：\n---\n' + text + '\n---';

    LlmRunner.complete(sys, user, onDelta, (err: string, full: string) => {
      if (err.length === 0 && full.length > 0) {
        s.summary = full;
        s.summaryAt = Date.now();
        TranscriptStore.persistOne(s);
        TranscriptStore.notify();
      }
      onDone(err);
    });
  }

  // ---------- 内部 ----------

  static find(id: string): TrSession | null {
    if (TranscriptStore.current != null && TranscriptStore.current!.id === id) {
      return TranscriptStore.current;
    }
    for (const s of TranscriptStore.sessions) {
      if (s.id === id) {
        return s;
      }
    }
    return null;
  }

  private static archive(s: TrSession): void {
    TranscriptStore.sessions.unshift(s);
    while (TranscriptStore.sessions.length > MAX_SESSIONS) {
      TranscriptStore.sessions.pop();
    }
    TranscriptStore.saveHistory();
  }

  private static persistOne(s: TrSession): void {
    if (TranscriptStore.current != null && TranscriptStore.current!.id === s.id) {
      TranscriptStore.flushCurrent();
    } else {
      TranscriptStore.saveHistory();
    }
  }

  private static async saveCurrent(): Promise<void> {
    const p = TranscriptStore.prefs;
    if (p == null) {
      return;
    }
    const c = TranscriptStore.current;
    const raw = c == null ? '' : JSON.stringify(TranscriptStore.toObj(c, true));
    await p.put(K_CURRENT, raw);
    await p.flush();
  }

  private static flushCurrent(): void {
    TranscriptStore.saveCurrent();
  }

  private static async saveHistory(): Promise<void> {
    const p = TranscriptStore.prefs;
    if (p == null) {
      return;
    }
    const arr: Array<Record<string, Object>> = [];
    for (const s of TranscriptStore.sessions) {
      arr.push(TranscriptStore.toObj(s, true));
    }
    await p.put(K_HISTORY, JSON.stringify(arr));
    await p.flush();
  }

  private static async loadHistory(): Promise<void> {
    const p = TranscriptStore.prefs;
    if (p == null) {
      return;
    }
    try {
      const raw = (await p.get(K_HISTORY, '[]')) as string;
      const arr = JSON.parse(raw) as Array<Record<string, Object>>;
      const out: TrSession[] = [];
      for (const o of arr) {
        out.push(TranscriptStore.fromObj(o));
      }
      TranscriptStore.sessions = out;
    } catch (e) {
      TranscriptStore.sessions = [];
    }
  }

  private static async loadCurrent(): Promise<void> {
    const p = TranscriptStore.prefs;
    if (p == null) {
      return;
    }
    try {
      const raw = (await p.get(K_CURRENT, '')) as string;
      if (raw.length === 0) {
        return;
      }
      TranscriptStore.current = TranscriptStore.fromObj(JSON.parse(raw) as Record<string, Object>);
      TranscriptStore.notify();
    } catch (e) {
      TranscriptStore.current = null;
    }
  }

  private static toObj(s: TrSession, withLines: boolean): Record<string, Object> {
    const lines: Array<Record<string, Object>> = [];
    if (withLines) {
      for (const l of s.lines) {
        lines.push({ 't': l.text, 'ts': l.ts } as Record<string, Object>);
      }
    }
    return {
      'id': s.id, 'title': s.title, 'startMs': s.startMs, 'endMs': s.endMs,
      'summary': s.summary, 'summaryAt': s.summaryAt, 'lines': lines,
    } as Record<string, Object>;
  }

  private static fromObj(o: Record<string, Object>): TrSession {
    const id = typeof o['id'] === 'string' ? o['id'] as string : '';
    const title = typeof o['title'] === 'string' ? o['title'] as string : '';
    const startMs = typeof o['startMs'] === 'number' ? o['startMs'] as number : 0;
    const s = new TrSession(id, title, startMs);
    s.endMs = typeof o['endMs'] === 'number' ? o['endMs'] as number : 0;
    s.summary = typeof o['summary'] === 'string' ? o['summary'] as string : '';
    s.summaryAt = typeof o['summaryAt'] === 'number' ? o['summaryAt'] as number : 0;
    const ra = o['lines'];
    if (ra != null) {
      const arr = ra as Array<Record<string, Object>>;
      for (const lo of arr) {
        const t = typeof lo['t'] === 'string' ? lo['t'] as string : '';
        const ts = typeof lo['ts'] === 'number' ? lo['ts'] as number : 0;
        if (t.length > 0) {
          s.lines.push(new TrLine(t, ts));
        }
      }
    }
    return s;
  }

  private static defaultTitle(now: number): string {
    const d = new Date(now);
    const mm = (d.getMonth() + 1).toString().padStart(2, '0');
    const dd = d.getDate().toString().padStart(2, '0');
    const hh = d.getHours().toString().padStart(2, '0');
    const mi = d.getMinutes().toString().padStart(2, '0');
    return `转写记录 ${mm}-${dd} ${hh}:${mi}`;
  }
}
