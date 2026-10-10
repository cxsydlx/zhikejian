/** 端侧规则问题检测器（与 Android 端 QuestionDetector.kt / 服务端 detector.py 同步）。 */
export class Detection {
  text: string = '';
  score: number = 0;
  isQuestion: boolean = false;
  duplicate: boolean = false;

  constructor(text: string, score: number, isQuestion: boolean, duplicate: boolean = false) {
    this.text = text;
    this.score = score;
    this.isQuestion = isQuestion;
    this.duplicate = duplicate;
  }
}

const STRONG_PATTERNS: string[] = [
  '吗', '呢', '？', '?',
  '为什么', '怎么', '怎样', '如何', '什么是', '是不是', '有没有',
  '要不要', '能不能', '可不可以', '请解释', '举个例子', '举例说明',
  '谁能', '哪位', '多少', '几个', '哪几种', '对不对', '指的是什么',
  // 课堂互动：找人 / 回答 / 点名
  '谁来', '谁来回答', '谁来说', '谁来说说', '谁愿意', '谁可以',
  '点名', '点个名', '请回答', '回答一下', '回答一下这个问题', '请哪位同学',
];

const CALLON_PATTERNS: string[] = [
  '你来回答', '你来答', '你来试试', '找个人', '找一个同学', '找一位', '找位同学',
  '这位同学', '那位同学', '请这位', '请那位', '举个手', '请举手', '举手回答',
  '说说你的', '谈谈你的', '你的理解', '你的看法',
];

const WEAK_PATTERNS: string[] = [
  '请说明', '讲一下', '说一下', '谈一谈', '区别在于', '对比一下',
  '总结一下', '也就是说', '意味着', '什么叫', '定义是',
];

const STRONG_SCORE = 0.5;
const CALLON_SCORE = 0.4;
const WEAK_SCORE = 0.2;
const THRESHOLD = 0.5;

export class QuestionDetector {
  private recent: Array<[number, string]> = [];
  private dedupeWindowMs: number = 30000;

  private static contains(text: string, p: string): boolean {
    return text.indexOf(p) >= 0;
  }

  static score(text: string): number {
    let s = 0;
    for (const p of STRONG_PATTERNS) {
      if (QuestionDetector.contains(text, p)) {
        s += STRONG_SCORE;
      }
    }
    for (const p of CALLON_PATTERNS) {
      if (QuestionDetector.contains(text, p)) {
        s += CALLON_SCORE;
      }
    }
    for (const p of WEAK_PATTERNS) {
      if (QuestionDetector.contains(text, p)) {
        s += WEAK_SCORE;
      }
    }
    return Math.min(s, 1.0);
  }

  private isDuplicate(t: string, now: number): boolean {
    while (this.recent.length > 0 && now - this.recent[0][0] > this.dedupeWindowMs) {
      this.recent.shift();
    }
    for (const pair of this.recent) {
      const prev: string = pair[1];
      if (QuestionDetector.similarity(prev, t) > 0.8) {
        return true;
      }
    }
    return false;
  }

  detect(text: string, now: number = Date.now()): Detection {
    const t = text.trim();
    if (t.length < 4) {
      return new Detection(t, 0, false);
    }
    let score = QuestionDetector.score(t);
    const duplicate = this.isDuplicate(t, now);
    const isQuestion = score >= THRESHOLD && !duplicate;
    if (isQuestion) {
      this.recent.push([now, t]);
    }
    return new Detection(t, score, isQuestion, duplicate);
  }

  /** 归一化相似度 = 1 - 编辑距离 / max(len)。 */
  static similarity(a: string, b: string): number {
    if (a === b) {
      return 1;
    }
    if (a.length === 0 || b.length === 0) {
      return 0;
    }
    return 1 - QuestionDetector.levenshtein(a, b) / Math.max(a.length, b.length);
  }

  private static levenshtein(a: string, b: string): number {
    const prev = new Array<number>(b.length + 1);
    const cur = new Array<number>(b.length + 1);
    for (let j = 0; j <= b.length; j++) {
      prev[j] = j;
    }
    for (let i = 1; i <= a.length; i++) {
      cur[0] = i;
      for (let j = 1; j <= b.length; j++) {
        const cost = a.charAt(i - 1) === b.charAt(j - 1) ? 0 : 1;
        cur[j] = Math.min(cur[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost);
      }
      for (let j = 0; j <= b.length; j++) {
        prev[j] = cur[j];
      }
    }
    return prev[b.length];
  }
}