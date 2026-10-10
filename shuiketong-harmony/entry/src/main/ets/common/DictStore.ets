/**
 * 词典本地存储 —— 离线可查 + 用户改写留存。
 *
 * ## 抄谁
 * 骨架抄 `TranscriptStore.ets:63-91`（**有幂等 init()**，比 `CourseStore` 那版好
 * —— 词典页可能被 router 单独推入，不能靠「只调一次」保证）。
 *
 * ## 为什么分两层存（这是重点）
 * **preferences 撑不住内置词库**：
 *   · 单 value 推荐 ≤ 8MB，几万条词条 = 5-10MB JSON
 *   · 每次 `get()` 都是**全量反序列化** → 查一个词要先 parse 全部
 * ∴ 分成：
 *   · **查过/改过的词** → preferences（数量有限，仿 TranscriptStore 设上限）
 *   · **内置只读词库** → 走 rawfile + 首次读取后缓存进内存 Map
 *
 * ## 与服务端的分工
 * 用户改写**双写**：本地留一份（离线可见）+ 提交给服务端（公网可见、
 * 带CC BY-SA 4.0 授权留证）。本地这份没有授权约束，因为纯自己看。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DictEntry, DictResult } from '../service/DictionaryClient';

const TAG: string = 'DictStore';

/** 本地保留的词条上限（超出丢最旧的）—— 与 TranscriptStore 的做法一致 */
const MAX_LOCAL: number = 300;
/** 内置词库的版本号；rawfile 内容变更时 +1，客户端据此重新加载 */
const BUILTIN_VERSION: number = 1;

const K_ENTRIES: string = 'dictEntries';
const K_BUILTIN_VER: string = 'dictBuiltinVer';

/** 本地存的一条词（序列化形态）。
 *
 * ⚠️ **必须 `export`** —— `DictView` 要用 `{w: StoredWord}` 作为 ForEach 的
 * itemGenerator 类型参数。不export 时编译报
 *   "declares 'StoredWord' locally, but it is not exported"（10505001）。
 */
export class StoredWord {
  word: string = '';
  ipa: string = '';
  posZh: string = '';
  /** 英文义项释义（OEWN, CC BY 4.0），每条一行 */
  glosses: string[] = [];
  /**
   * 【2026-10-10 补】中文释义（ECDICT, MIT）。
   *
   * ⚠️ 服务端返回的是**带真换行的多行字符串**（如 "n. 电脑\n[计] 计算机"），
   * 离线显示时按 `\n` split 成多行。
   * 之前我漏了这个字段 —— 词典页只显示英文释义，中文完全没出现。
   */
  defZh: string = '';
  /** 考纲标签（中考/高考/四级/六级/考研/雅思/托福/GRE） */
  tags: string[] = [];
  /** 柯林斯星级 1-5，0 表示无 */
  collins: number = 0;
  source: string = '';
  /** 用户改写内容（若有） */
  userDef: string = '';
  userDefAt: number = 0;
  ts: number = 0;
}

export class DictStore {
  /** 内存镜像（页面直接读这个） */
  static entries: Map<string, StoredWord> = new Map();
  /** 内置词库（rawfile 懒加载，key 小写） */
  static builtin: Map<string, string> = new Map();
  static builtinLoaded: boolean = false;

  private static prefs: preferences.Preferences | null = null;
  private static listeners: Array<() => void> = [];

  /** 幂等 init —— 与 TranscriptStore 一致 */
  static async init(ctx: common.UIAbilityContext): Promise<void> {
    if (DictStore.prefs != null) {
      return;
    }
    try {
      // ⚠️ 全工程共用 'skt_prefs' 这一个实例（CourseStore/TranscriptStore/Theme 都用）
      DictStore.prefs = await preferences.getPreferences(ctx, 'skt_prefs');
      await DictStore.restore();
    } catch (e) {
      // prefs 拿不到不能静默 —— 静默 return 会让"存了但读不出来"
      hilog.error(0x0000, TAG, 'init failed: %{public}s', JSON.stringify(e));
    }
  }

  static onChange(cb: () => void): void {
    DictStore.listeners.push(cb);
  }

  private static notify(): void {
    for (const cb of DictStore.listeners) {
      try {
        cb();
      } catch (e) {
        hilog.error(0x0000, TAG, 'listener threw: %{public}s', JSON.stringify(e));
      }
    }
  }

  private static async restore(): Promise<void> {
    const p: preferences.Preferences | null = DictStore.prefs;
    if (p == null) {
      return;
    }
    try {
      const raw: preferences.ValueType = await p.get(K_ENTRIES, '[]');
      if (typeof raw === 'string') {
        // ⚠️ 先接成 Object 再用 instanceof Array 收窄 —— 直接声明
        //    `Record<string, Object>` 会报 "Index signature for type 'string'
        //    is missing in type 'Object'"。
        const parsed: Object = JSON.parse(raw) as Object;
        if (parsed instanceof Array) {
          const items: Object[] = parsed as Object[];
          for (const it of items) {
            const w: StoredWord = DictStore.fromObj(it as Record<string, Object>);
            if (w.word.length > 0) {
              DictStore.entries.set(w.word, w);
            }
          }
        }
      }
      const ver: preferences.ValueType = await p.get(K_BUILTIN_VER, 0);
      if (typeof ver === 'number' && ver === BUILTIN_VERSION) {
        DictStore.builtinLoaded = true;
      }
      hilog.info(0x0000, TAG, 'restore: %{public}d local words', DictStore.entries.size);
    } catch (e) {
      // 损坏就当空，**绝不抛出**（抄 TranscriptStore.loadHistory 的兜底）
      hilog.error(0x0000, TAG, 'restore failed, treating as empty: %{public}s', JSON.stringify(e));
      DictStore.entries.clear();
    }
  }

  /** 存一条查过的词条 */
  static async saveResult(r: DictResult): Promise<void> {
    if (!r.found || r.word.length === 0) {
      return;
    }
    const w: StoredWord = new StoredWord();
    w.word = r.word;
    w.ts = Date.now();
    if (r.entry != null) {
      const e: DictEntry = r.entry as DictEntry;
      w.ipa = e.ipa;
      w.posZh = e.posLabelZh.length > 0 ? e.posLabelZh : e.posLabel;
      w.source = e.source;
      // ---- 中文释义 + 考纲标签 + 星级（2026-10-10 补）----
      w.defZh = e.definitionZh;
      w.tags = e.tags;
      w.collins = e.collins;
      for (const s of e.senses) {
        w.glosses.push(s.gloss);
      }
    }
    if (r.userEdit != null) {
      w.userDef = r.userEdit.definition;
      w.userDefAt = r.userEdit.createdAt;
    }
    DictStore.entries.set(w.word, w);
    DictStore.trim();
    DictStore.notify();
    await DictStore.persist();
  }

  /** 本地覆盖一条用户改写（离线也能看到） */
  static async saveUserEdit(word: string, definition: string): Promise<void> {
    const w: string = word.trim().toLowerCase();
    let item: StoredWord | undefined = DictStore.entries.get(w);
    if (item === undefined) {
      item = new StoredWord();
      item.word = w;
      item.ts = Date.now();
      DictStore.entries.set(w, item);
    }
    const cur: StoredWord = item as StoredWord;
    cur.userDef = definition;
    cur.userDefAt = Date.now();
    cur.ts = Date.now();
    DictStore.trim();
    DictStore.notify();
    await DictStore.persist();
  }

  static find(word: string): StoredWord | undefined {
    return DictStore.entries.get(word.trim().toLowerCase());
  }

  /** 最近查过的词（按时间倒序） */
  static recent(limit: number = 12): StoredWord[] {
    const arr: StoredWord[] = Array.from(DictStore.entries.values());
    arr.sort((a: StoredWord, b: StoredWord) => b.ts - a.ts);
    return arr.slice(0, limit);
  }

  static count(): number {
    return DictStore.entries.size;
  }

  static async clear(): Promise<void> {
    DictStore.entries.clear();
    DictStore.notify();
    await DictStore.persist();
  }

  // ---- 序列化 ----

  private static trim(): void {
    if (DictStore.entries.size <= MAX_LOCAL) {
      return;
    }
    const arr: StoredWord[] = Array.from(DictStore.entries.values());
    arr.sort((a: StoredWord, b: StoredWord) => b.ts - a.ts);
    // 超上限的尾部丢掉，但**用户改写过的永远保留**（那是用户自己的劳动成果）
    const keep: StoredWord[] = arr.filter((w: StoredWord) => w.userDef.length > 0);
    const rest: StoredWord[] = arr.filter((w: StoredWord) => w.userDef.length === 0);
    const room: number = MAX_LOCAL - keep.length;
    DictStore.entries.clear();
    for (const w of keep) {
      DictStore.entries.set(w.word, w);
    }
    for (let i: number = 0; i < rest.length && i < room; i++) {
      DictStore.entries.set(rest[i].word, rest[i]);
    }
  }

  private static async persist(): Promise<void> {
    const p: preferences.Preferences | null = DictStore.prefs;
    if (p == null) {
      hilog.error(0x0000, TAG, 'persist skipped: prefs is null');
      return;
    }
    try {
      const arr: Array<Record<string, Object>> = [];
      for (const w of DictStore.entries.values()) {
        arr.push(DictStore.toObj(w));
      }
      await p.put(K_ENTRIES, JSON.stringify(arr));
      await p.put(K_BUILTIN_VER, BUILTIN_VERSION);
      await p.flush();
    } catch (e) {
      hilog.error(0x0000, TAG, 'persist failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
 * 从 `Object`里安全取字符串数组。
 *
 * ⚠️ 必须**先接成 `Object` 再用 `instanceof Array` 收窄** ——
 *    直接声明 `Record<string, Object>` 会报
 *    "Index signature for type 'string' is missing in type 'Object'"。
 */
private static strArrInto(v: Object, out: string[]): void {
    if (!(v instanceof Array)) {
      return;
    }
    const items: Object[] = v as Object[];
    for (const it of items) {
      if (typeof it === 'string') {
        out.push(it as string);
      }
    }
  }

  private static toObj(w: StoredWord): Record<string, Object> {
    const o: Record<string, Object> = {};
    o['word'] = w.word;
    o['ipa'] = w.ipa;
    o['posZh'] = w.posZh;
    o['glosses'] = w.glosses;
    // ---- 中文释义等（2026-10-10 补）----
    o['defZh'] = w.defZh;
    o['tags'] = w.tags;
    o['collins'] = w.collins;
    o['source'] = w.source;
    o['userDef'] = w.userDef;
    o['userDefAt'] = w.userDefAt;
    o['ts'] = w.ts;
    return o;
  }

  private static fromObj(o: Record<string, Object>): StoredWord {
    const w: StoredWord = new StoredWord();
    if (typeof o['word'] === 'string') {
      w.word = o['word'] as string;
    }
    if (typeof o['ipa'] === 'string') {
      w.ipa = o['ipa'] as string;
    }
    if (typeof o['posZh'] === 'string') {
      w.posZh = o['posZh'] as string;
    }
    if (typeof o['defZh'] === 'string') {
      w.defZh = o['defZh'] as string;
    }
    if (typeof o['collins'] === 'number') {
      w.collins = o['collins'] as number;
    }
    if (typeof o['source'] === 'string') {
      w.source = o['source'] as string;
    }
    if (typeof o['userDef'] === 'string') {
      w.userDef = o['userDef'] as string;
    }
    if (typeof o['userDefAt'] === 'number') {
      w.userDefAt = o['userDefAt'] as number;
    }
    if (typeof o['ts'] === 'number') {
      w.ts = o['ts'] as number;
    }
    // `o['tags']` 也是 Object，先接再 instanceof 收窄（与 glosses 同理）
    DictStore.strArrInto(o['tags'], w.tags);
    // ⚠️ `o['glosses']` 的静态类型是 `Object`，不能直接赋给
    //    `Record<string, Object>`（Record 需要 string 索引签名）。
    //    正确做法：先接成 `Object`，再用 `instanceof Array` 收窄。
    const g: Object = o['glosses'];
    if (g instanceof Array) {
      const items: Object[] = g as Object[];
      for (const it of items) {
        if (typeof it === 'string') {
          w.glosses.push(it as string);
        }
      }
    }
    return w;
  }
}