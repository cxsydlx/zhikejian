/**
 * 词典后端客户端 —— 对接 dictionary.xsheep.cn
 *
 * ## 范式来源（照抄工程既有做法，不自创）
 * - **非流式请求**：`AsrService.submitApiChunk()`（797~863 行）的
 *   `http.createHttp()` + `expectDataType: STRING` + `then/catch` 都调 `destroy()`
 * - **base_url 规范化**：`LlmClient.endpoint()`（183~198 行）的容错思路 ——
 *   但**不抄**它写死的 `/chat/completions`，词典端点自己拼
 * - **端点拼接容错**：`AsrService.asrApiEndpoint()`（887~900 行）
 *
 * ## 不抄 LlmClient 的「兼容三件套」为什么
 * ① `enable_thinking` 是通义私有字段，词典 API 无关
 * ② SSE / 非 SSE 兜底 —— 查词是一次性请求，没有流
 * ③ 端点容错思路要留，但实现按词典的实际路径重写
 *
 * ## 服务地址
 * ⚠️ 遵循 `AppState.ets:49` 的既定规则「**不预填任何服务器地址**」——
 *    地址由用户在设置页手填，与 LLM/ASR 一致。所以这里读 `AppState.dictBaseUrl`，
 *    **不硬编码任何 URL**。
 */

import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppState } from '../common/AppState';

/** 单词的音标 + 词性 + 义项 */
export interface DictSense {
  rank: number;
  synset: string;
  gloss: string;
  examples: string[];
}

/** 双语例句（Tatoeba，CC-BY 2.0 FR） */
export interface DictExample {
  en: string;
  zh: string;
  /** ⚠️ CC-BY 2.0 FR 要求署名到句子作者 —— UI 必须展示，不可隐藏 */
  attribution: string;
}

export interface DictEntry {
  word: string;
  pos: string;
  posLabel: string;
  posLabelZh: string;
  ipa: string;
  ipaVariant: string;
  senses: DictSense[];
  /** 英文释义的来源署名（CC BY 4.0 双署名要求） */
  source: string;
  // ---- 2026-10-10 服务端 v1.1.0 新增 ----
  /** 中文释义（ECDICT，MIT）；⚠️ 含真换行符，按 `\n` split 成多行显示 */
  definitionZh: string;
  /** 考纲标签（中考/高考/四级/六级/考研/雅思/托福/GRE） */
  tags: string[];
  /** 柯林斯星级 1-5，0 表示无 */
  collins: number;
  /** 屈折变化（复数/过去式） */
  exchange: string;
}

/** 用户改写的释义（服务端已按 CC BY-SA 4.0 存证） */
export interface DictUserEdit {
  definition: string;
  note: string;
  submitter: string;
  createdAt: number;
  license: string;
}

export interface DictResult {
  ok: boolean;
  word: string;
  found: boolean;
  entry?: DictEntry;
  userEdit?: DictUserEdit;
  /** 该词条是否被用户改写过 —— 前端要显示「已修改」标记 */
  modified: boolean;
}

/** 服务端返回的原始 JSON（ArkTS 里 JSON.parse 给 Object，必须逐字段 typeof 收窄） */
class RawWordResp {
  ok: boolean = false;
  word: string = '';
  found: boolean = false;
  modified: boolean = false;
}

/**
 * 从服务端 base_url 拼出查词端点。
 *
 * 容错（照 `AsrService.asrApiEndpoint()` 的思路）：
 *   · 去掉尾部斜杠
 *   · 用户若填了完整路径 `/api/v1/word`，直接用
 *   · 否则补 `/api/v1`
 */
export function dictEndpoint(base: string): string {
  let b: string = base.trim().replace(/\/+$/, '');
  if (b.length === 0) {
    return '';
  }
  if (b.endsWith('/api/v1/word')) {
    return b;
  }
  if (b.endsWith('/api/v1')) {
    return b + '/word';
  }
  return b + '/api/v1/word';
}

/** 拼出发音端点 —— 服务端返回 WAV（espeak-ng 合成） */
export function dictAudioUrl(base: string, word: string, accent: string): string {
  const e = dictEndpoint(base);
  if (e.length === 0) {
    return '';
  }
  return e + '/' + encodeURIComponent(word) + '/audio?accent=' + accent;
}

export class DictionaryClient {
  private static readonly TAG: string = 'DictionaryClient';
  private static readonly TIMEOUT: number = 15000;

  /**
   * 查词。
   *
   * @param word 单词（服务端只接受英文字母与连字符，这里也拦一道）
   * @param onOk 成功回调
   * @param onFail 失败回调（网络错误 / 服务端错误统一走这里）
   */
  static async lookup(word: string, onOk: (r: DictResult) => void,
    onFail: (msg: string) => void): Promise<void> {
    const w: string = word.trim().toLowerCase();
    if (w.length === 0) {
      onFail('请输入单词');
      return;
    }
    if (!DictionaryClient.validWord(w)) {
      onFail('只支持英文字母与连字符');
      return;
    }
    const base: string = AppState.dictBaseUrl;
    if (base.length === 0) {
      onFail('未配置词典服务器地址，请到「设置 - 词典」填写');
      return;
    }
    const url: string = dictEndpoint(base) + '?w=' + encodeURIComponent(w);
    DictionaryClient.get(url, w, onOk, onFail);
  }

  /**
   * 提交改写释义。
   *
   * ⚠️ **必须带 `licenseAgree: true`** —— 这是服务端设的合规闸门：
   *    用户提交的内容以 CC BY-SA 4.0 发布，服务端会记录时间戳与提交者标识
   *    作为「表明是否曾修改」的举证材料（CC BY-SA 4.0 第 3(a) 条）。
   *    UI 上必须让用户明确勾选同意，不能静默代填。
   */
  static async submitEdit(word: string, definition: string, note: string,
    submitter: string, licenseAgree: boolean,
    onOk: () => void, onFail: (msg: string) => void): Promise<void> {
    const base: string = AppState.dictBaseUrl;
    if (base.length === 0) {
      onFail('未配置词典服务器地址');
      return;
    }
    if (!licenseAgree) {
      onFail('请先同意授权条款');
      return;
    }
    const body: Record<string, Object> = {
      'word': word.trim().toLowerCase(),
      'definition': definition,
      'note': note,
      'submitter': submitter,
      'licenseAgree': true
    };
    const json: string = JSON.stringify(body);
    const req: http.HttpRequest = http.createHttp();
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.PUT,
      header: { 'Content-Type': 'application/json' },
      extraData: json,
      expectDataType: http.HttpDataType.STRING,
      readTimeout: DictionaryClient.TIMEOUT,
      connectTimeout: 8000,
    };
    req.request(dictEndpoint(base), options)
      .then((resp: http.HttpResponse) => {
        const code: number = resp.responseCode;
        const raw: string = typeof resp.result === 'string' ? resp.result as string : '';
        req.destroy();
        if (code === 200) {
          onOk();
        } else {
          onFail(DictionaryClient.errMsg(raw, code));
        }
      })
      .catch((e: BusinessError) => {
        req.destroy();
        hilog.error(0x0000, DictionaryClient.TAG, 'submitEdit failed: %{public}s', e.message);
        onFail('提交失败：' + (e.message ?? e));
      });
  }

  // ---- 内部 ----

  private static get(url: string, word: string,
    onOk: (r: DictResult) => void, onFail: (msg: string) => void): void {
    const req: http.HttpRequest = http.createHttp();
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.STRING,
      readTimeout: DictionaryClient.TIMEOUT,
      connectTimeout: 8000,
    };
    req.request(url, options)
      .then((resp: http.HttpResponse) => {
        const code: number = resp.responseCode;
        const raw: string = typeof resp.result === 'string' ? resp.result as string : '';
        req.destroy();
        if (code !== 200) {
          onFail(DictionaryClient.errMsg(raw, code));
          return;
        }
        try {
          onOk(DictionaryClient.parse(word, raw));
        } catch (e) {
          hilog.error(0x0000, DictionaryClient.TAG, 'parse failed: %{public}s', JSON.stringify(e));
          onFail('返回内容解析失败');
        }
      })
      .catch((e: BusinessError) => {
        req.destroy();
        hilog.error(0x0000, DictionaryClient.TAG, 'lookup failed: %{public}s', e.message);
        onFail('连不上词典服务：' + (e.message ?? e));
      });
  }

  /**
   * 解析服务端返回。
   *
   * ⚠️ ArkTS 的 `JSON.parse` 返回 `Object`，**必须逐字段 typeof 收窄**，
   *    直接当接口用会崩。参考 `CourseStore.str/num/boolOr` 的做法。
   */
  private static parse(word: string, raw: string): DictResult {
    const obj: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
    const r: DictResult = {
      ok: DictionaryClient.boolOf(obj['ok'], true),
      word: DictionaryClient.strOf(obj['word'], word),
      found: DictionaryClient.boolOf(obj['found'], false),
      modified: DictionaryClient.boolOf(obj['modified'], false),
    };
    // ⚠️ `Record<string, Object>` 只能用**索引**取值（`obj['x']`），不支持点号。
    const e: Record<string, Object> = obj['entry'] as Record<string, Object>;
    if (e != null) {
      r.entry = {
        word: DictionaryClient.strOf(e['word'], word),
        pos: DictionaryClient.strOf(e['pos'], ''),
        posLabel: DictionaryClient.strOf(e['posLabel'], ''),
        posLabelZh: DictionaryClient.strOf(e['posLabelZh'], ''),
        ipa: DictionaryClient.strOf(e['ipa'], ''),
        ipaVariant: DictionaryClient.strOf(e['ipaVariant'], ''),
        senses: DictionaryClient.sensesOf(e['senses']),
        source: DictionaryClient.strOf(e['source'], ''),
        // ---- 2026-10-10 中文释义与考纲标签（服务端 v1.1.0 新增）----
        definitionZh: DictionaryClient.strOf(e['definitionZh'], ''),
        tags: DictionaryClient.strArrayOf(e['tags']),
        collins: DictionaryClient.numOf(e['collins'], 0),
        exchange: DictionaryClient.strOf(e['exchange'], ''),
      };
    }
    const u: Record<string, Object> = obj['userEdit'] as Record<string, Object>;
    if (u != null) {
      r.userEdit = {
        definition: DictionaryClient.strOf(u['definition'], ''),
        note: DictionaryClient.strOf(u['note'], ''),
        submitter: DictionaryClient.strOf(u['submitter'], ''),
        createdAt: DictionaryClient.numOf(u['createdAt'], 0),
        license: DictionaryClient.strOf(u['license'], ''),
      };
    }
    return r;
  }

  private static sensesOf(v: Object): DictSense[] {
    const out: DictSense[] = [];
    if (!(v instanceof Array)) {
      return out;
    }
    const arr: Object[] = v as Object[];
    for (const it of arr) {
      const o: Record<string, Object> = it as Record<string, Object>;
      const s: DictSense = {
        rank: DictionaryClient.numOf(o['rank'], out.length + 1),
        synset: DictionaryClient.strOf(o['synset'], ''),
        gloss: DictionaryClient.strOf(o['gloss'], ''),
        examples: DictionaryClient.strArrayOf(o['examples']),
      };
      if (s.gloss.length > 0) {
        out.push(s);
      }
    }
    return out;
  }

  /**
 * 收窄取值工具。
 *
 * ⚠️ **参数类型必须是 `Object` 而不是 `Record<string, Object>`** ——
 *    这些函数接受的是「任意 JSON 值」（可能是 string / number / boolean / null），
 *    而 `Record<string, Object>` 是"键值对对象"类型。
 *    声明成 Record 后，`strOf(o.error, '')` 这类调用会报
 *    "Argument of type 'Object' is not assignable to parameter of type
 *      'Record<string, Object>'"（Object 只能赋给很少的类型）。
 *
 * 范式来源：`CourseStore.str/num/boolOr`。
 */
private static strOf(v: Object, def: string): string {
    return typeof v === 'string' ? v as string : def;
  }

  private static numOf(v: Object, def: number): number {
    return typeof v === 'number' ? v as number : def;
  }

  private static boolOf(v: Object, def: boolean): boolean {
    return typeof v === 'boolean' ? v as boolean : def;
  }

  /** 从数组里安全取字符串数组 */
  private static strArrayOf(v: Object): string[] {
    const out: string[] = [];
    if (v instanceof Array) {
      const arr: Object[] = v as Object[];
      for (const it of arr) {
        if (typeof it === 'string') {
          out.push(it as string);
        }
      }
    }
    return out;
  }

  /** 从错误响应里取出服务端给的错误文案 */
  private static errMsg(raw: string, code: number): string {
    try {
      const o: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      const m: string = DictionaryClient.strOf(o.error, '');
      if (m.length > 0) {
        return m;
      }
    } catch (e) {
      // 非 JSON 错误体，走下面兜底
    }
    return '服务返回 ' + code;
  }

  private static validWord(w: string): boolean {
    return /^[a-z][a-z \-]{0,40}$/.test(w);
  }
}