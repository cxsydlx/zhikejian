/** 最近 N 分钟转写环形缓冲（与 Android 端 TranscriptBuffer 语义一致）。 */
export class TranscriptItem {
  ts: number = 0;
  text: string = '';

  constructor(ts: number, text: string) {
    this.ts = ts;
    this.text = text;
  }
}

export class TranscriptBuffer {
  private items: TranscriptItem[] = [];
  private windowMs: number = 5 * 60 * 1000;

  add(text: string, ts: number = Date.now()): void {
    const t = text.trim();
    if (t.length === 0) {
      return;
    }
    this.items.push(new TranscriptItem(ts, t));
    this.trim(ts);
  }

  snapshot(now: number = Date.now()): string {
    this.trim(now);
    return this.items.map((it) => it.text).join('\n');
  }

  /**
   * 取 ts 之前 windowMs 毫秒内的转写，最多 maxChars 字。
   * 从最近的往回收（尾部优先），再按时间正序拼接——垂询时只发相关上下文。
   */
  windowBefore(ts: number, windowMs: number = 90000, maxChars: number = 600): string {
    const from = ts - windowMs;
    const picked: string[] = [];
    let total = 0;
    for (let i = this.items.length - 1; i >= 0; i--) {
      const it = this.items[i];
      if (it.ts > ts) {
        continue;
      }
      if (it.ts < from) {
        break;
      }
      if (total + it.text.length > maxChars) {
        break;
      }
      picked.unshift(it.text);
      total += it.text.length + 1;
    }
    return picked.join('\n');
  }

  clear(): void {
    this.items = [];
  }

  private trim(now: number): void {
    const edge = now - this.windowMs;
    while (this.items.length > 0 && this.items[0].ts < edge) {
      this.items.shift();
    }
  }
}