import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppState } from '../common/AppState';
import { CourseStore } from '../common/CourseStore';
import { Sections, SectionSlot } from '../common/SectionTimes';
import { ClassReminder } from '../service/ClassReminder';
import { ShareService } from '../service/ShareService';
import { SubjectLexicon } from '../common/SubjectLexicon';
import { Theme } from '../common/Theme';
import { ScheduleExportService } from '../service/ScheduleExportService';
import { Mat } from '../common/Material';
import { WindowInsets } from '../common/WindowInsets';
import { FontSize, Weight, Space, Radius, Size, Motion, Layout } from '../common/DesignToken';

/**
 * 设置页（原「课表设置」+ 原「设置」合并而成）。
 *
 * 合并方案：本页同时充当
 *   ① 底部导航第三个 Tab（fromTab = true，画自己的标题栏 + 可切换分区）；
 *   ② 独立路由页（fromTab = false，画返回箭头）。
 * 在 Tab 里点进来时默认落在「语音识别」，从课表页/听课页推路由进来时用 params.sec 指定分区
 * （课表页推 sec=1 落在「课表设置」，听课页推 sec=0 落在「语音识别」）。
 *
 * 关键实现约束（本项目踩过多次的坑）：
 *  · ArkUI 只观察「渲染中读取过」的状态 —— 只写不读的字段（this.x += 1）不会触发重绘；
 *  · **带参数的 @Builder 是按值传参**，传动态值（选中态、计数值）进去不会刷新。
 *    所以本页所有选项行一律内联渲染；确实要抽的（如 sideTitle / stepBtn）
 *    只传**静态值**，动态值在 Builder 内部直接读 this.xxx。
 *
 * 视觉度量（圆角 / 字号 / 间距 / 热区 / 动效）一律引用 common/DesignToken，
 * 本文件不再写死数值字面量。
 */

// 【2026-09-28 删除】原 `BG_PRESETS`（背景色预设）已随该功能搬到配色页。
const SHAPES: string[] = ['圆角矩形', '胶囊', '圆形'];
const SHAPE_VALUES: string[] = ['rounded', 'capsule', 'circle'];
const FIRST_COL_TEXT: string[] = ['开课日', '周一', '周日'];
const FIRST_COL_VALUES: string[] = ['open', 'monday', 'sunday'];
const WD: string[] = ['', '一', '二', '三', '四', '五', '六', '日'];
const SLOT_ROW1: string[] = ['最上', '上', '偏上', '居中', '课名下'];
const SLOT_V1: string[] = ['topLeft', 'topCenter', 'topRight', 'center', 'nameBelow'];
const SLOT_ROW2: string[] = ['偏下', '下', '最下', '隐藏'];
const SLOT_V2: string[] = ['bottomLeft', 'bottomCenter', 'bottomRight', 'hidden'];
/**
 * 第二行的**补位版**：末尾加一个空串占位。
 *
 * 【2026-09-28】用户要求「补空占位」—— 第一行 5 个、第二行 4 个，
 * 两边都用 `layoutWeight(1)` 平分容器宽度 → 第二行每格比第一行宽 25%，
 * 纵向看列线全是歪的。补一个占位格后两行都是 5 格，列线对齐。
 * 渲染时空串走"不可见占位"分支（保留 layoutWeight 但不画背景/文字）。
 */
const SLOT_ROW2_PAD: string[] = ['偏下', '下', '最下', '隐藏', ''];
/** 与 `SLOT_ROW2_PAD` 一一对应的取值（占位项给空串） */
const SLOT_V2_PAD: string[] = ['bottomLeft', 'bottomCenter', 'bottomRight', 'hidden', ''];


/** 分区标题（左右两侧） —— 只传静态字符串 */
const SEC_TITLES: string[] = ['语音识别', '课表设置', '词典'];
/** 语音识别模式：显示名 / 取值 / 说明 */
const ASR_LABELS: string[] = ['系统识别', '自建云端', '大模型 API'];
const ASR_VALUES: string[] = ['local', 'cloud', 'api'];
const ASR_DESCS: string[] = [
  '鸿蒙端侧引擎，零流量零加载',
  '自建 WSS 流式服务，实时出字',
  '任何 OpenAI 兼容的语音识别接口',
];

/**
 * VAD 灵敏度档位 —— 把用户看不懂的 RMS 阈值翻译成人类语言。
 *
 * `VAD_GEAR_RMS` 与 `VAD_GEAR_LABELS` 一一对应。
 * ⚠️「标准」档的值必须等于 `AppState.VAD_MIN_RMS_DEFAULT`，否则「恢复默认」后的
 *    档位显示会跟真实值对不上（`gearOfRms()` 会兜住不越界，但会显示成别的档）。
 * 数值本身的含义（地板值 / 自适应噪声底）见 `AppState.vadMinRms` 注释。
 */
const VAD_GEAR_LABELS: string[] = ['抗噪', '标准', '灵敏'];
const VAD_GEAR_RMS: number[] = [600, 420, 260];

/**
 * 由 RMS 阈值反查档位索引。
 * 用「最接近」而非「精确相等」—— 用户存过旧值、或以后调了档位取值，都不会算出越界索引。
 */
function gearOfRms(rms: number): number {
  let best = 0;
  let diff = Math.abs(VAD_GEAR_RMS[0] - rms);
  for (let i = 1; i < VAD_GEAR_RMS.length; i++) {
    const d = Math.abs(VAD_GEAR_RMS[i] - rms);
    if (d < diff) {
      diff = d;
      best = i;
    }
  }
  return best;
}

/** base_url 规范化结果 */
class BaseUrlNorm {
  url: string = '';
  note: string = '';
}

/**
 * 防止 base_url 与完整 endpoint 混淆：
 * 剥掉 /chat/completions 等端点后缀、剥掉 /vN 版本段（客户端会自动拼 /v1/...）、
 * 补 https:// 前缀、去 query/# 与尾部斜杠。返回修正后的 url 与修正说明。
 */
function normalizeBaseUrl(raw: string): BaseUrlNorm {
  const res = new BaseUrlNorm();
  let u = raw.trim();
  if (u.length === 0) {
    return res;
  }
  const notes: string[] = [];
  if (!/^https?:\/\//i.test(u) && !/^wss?:\/\//i.test(u)) {
    u = 'https://' + u;
    notes.push('补全 https:// 前缀');
  }
  const cut = u.search(/[?#]/);
  if (cut >= 0) {
    u = u.substring(0, cut);
    notes.push('去掉 ?/# 及之后内容');
  }
  u = u.replace(/\/+$/, '');
  const endpoints: string[] = [
    '/chat/completions', '/completions', '/embeddings', '/models', '/responses', '/moderations',
    '/audio/transcriptions', '/audio/speech',
  ];
  for (const ep of endpoints) {
    const idx = u.toLowerCase().indexOf(ep);
    if (idx > 0) {
      u = u.substring(0, idx);
      notes.push(`去掉端点后缀 ${ep}`);
      break;
    }
  }
  u = u.replace(/\/+$/, '');
  const vm = u.match(/\/v[1-9]$/i);
  if (vm != null && vm.length > 0) {
    u = u.substring(0, u.length - vm[0].length);
    notes.push(`去掉版本段 ${vm[0]}`);
  }
  u = u.replace(/\/+$/, '');
  res.url = u;
  res.note = notes.join('；');
  return res;
}

@Entry
@Component
export struct Settings {
  // ---- 主题镜像：ArkUI 只观察「渲染中读取过」的状态；配色变化必须镜像成 @State 才会重绘 ----
  @State tc: string = Theme.themeColor();
  @State tacc: string = Theme.accentColor();
  @State tsoft: string = Theme.softColor();
  @State tpage: string = Theme.pageColor();
  @State ton: string = Theme.onTheme();
  @State tmain: string = Theme.textMain();
  @State tsub: string = Theme.textSub();

  /** 当前分区：0=语音识别 1=课表设置 */
  @State sec: number = 0;
  /** 是否作为底部 Tab 展示（true 时画顶部标题栏，false 时画返回箭头） */
  private fromTab: boolean = false;

  // ================= 一、语音识别 =================

  /** local | cloud | api */
  @State asrMode: string = 'local';
  @State asrBaseHint: string = '';
  @State asrApiBaseUrl: string = '';
  /** 词典服务器地址（2026-10-10 新增，对应 dictionary.xsheep.cn） */
  @State dictBaseUrl: string = '';
  @State asrApiModel: string = 'whisper-1';
  @State asrApiKey: string = '';
  @State asrApiChunkSec: number = 3;
  // ---- VAD 切分参数（只作用于「大模型 API」链路，见 AppState 注释）----
  /** 灵敏度档位**索引**（对应 VAD_GEAR_LABELS / VAD_GEAR_RMS），不是 RMS 值本身 */
  @State vadGear: number = 1;
  /** 尾部静音多久算一句说完（ms） */
  @State vadSilMs: number = 400;
  /** 一段最短多长才允许切（ms） */
  @State vadMinSegMs: number = 800;
  @State cloudAsrUrl: string = '';
  @State subjectKey: string = SubjectLexicon.AUTO;
  @State subjectLabel: string = SubjectLexicon.labelOfChoice(SubjectLexicon.AUTO);
  @State subjectHint: string = '';
  @State subjectPickerShow: boolean = false;

  /** 语音识别 / 大语言模型是否已修改（决定是否显示「保存」按钮） */
  @State asrDirty: boolean = false;
  @State asrSaved: boolean = false;

  // ================= 二、课表设置 =================

  @State name: string = '';
  @State openDate: string = '';
  @State totalWeeks: number = 16;
  @State weekOverride: number = 0;
  @State sectionsToShow: number = 14;
  @State cellHeight: number = 58;
  @State colWidth: number = 0;          // 0 = 自适应屏宽；>0 固定列宽（可左右滑）
  @State nameSlot: string = 'center';
  @State locationSlot: string = 'bottomLeft';
  @State teacherSlot: string = 'bottomRight';
  @State cornerRadius: number = 12;
  @State shape: string = 'rounded';
  @State firstColMode: string = 'open';
  @State showSaturday: boolean = true;
  @State showSunday: boolean = true;
  @State showNonCurrentWeek: boolean = true;
  @State showTeacher: boolean = true;
  @State showLocation: boolean = true;
  @State showGrid: boolean = true;
  @State bgColor: string = '#F6F3EF';
  @State textScale: number = 100;
  @State blockOpacity: number = 100;
  @State reminderEnabled: boolean = true;
  @State leadMinutes: number = 15;
  @State showTimes: boolean = false;
  @State openWeekdayText: string = '周一';
  // 自定义日期选择层（不依赖系统 DatePickerDialog，避免「点了确定没回调」）
  @State showDatePick: boolean = false;
  @State pickY: number = 2026;
  @State pickM: number = 9;
  @State pickD: number = 14;
  // 节假日（停课日）
  @State holidays: string[] = [];
  @State showHoliday: boolean = false;
  @State pickForHoliday: boolean = false;
  // 碰一碰分享状态
  @State shareOn: boolean = false;
  // 导出成功浮层（2026-10-07 接入 ill_export_done）
  // 原先导出成功只弹一个 toast —— 文件名长、路径信息多，2.6 秒就读完了，
  // 用户来不及确认"到底存到哪了"。改成带插图的小浮层，文件名完整可读。
  @State showExportDone: boolean = false;
  @State exportDoneMsg: string = '';
  @State shareStatus: string = '';

  // ================= 大语言模型（转写笔记 / 答题整理） =================

  @State llmBaseUrl: string = '';
  @State llmModel: string = '';
  @State llmApiKey: string = '';
  @State llmBaseHint: string = '';
  @State dictUrlHint: string = '';

  private syncTheme(): void {
    this.tc = Theme.themeColor();
    this.tacc = Theme.accentColor();
    this.tsoft = Theme.softColor();
    this.tpage = Theme.pageColor();
    this.ton = Theme.onTheme();
    this.tmain = Theme.textMain();
    this.tsub = Theme.textSub();
  }

  aboutToAppear(): void {
    // 首帧就确定屏幕形态，否则边距会出现「16 → 32」跳变
    Layout.init();
    Theme.onChange(() => {
      this.syncTheme();
    });
    this.syncTheme();

    const p = router.getParams() as Record<string, Object> | null;
    if (p != null) {
      const f = p['fromTab'];
      this.fromTab = typeof f === 'boolean' ? f as boolean : false;
      const s = p['sec'];
      if (typeof s === 'number') {
        this.sec = s as number;
      }
    }

    this.loadAsr();
    this.loadSchedule();
    this.loadLlm();
  }

  // ---------- 语音识别 ----------

  private loadAsr(): void {
    this.asrMode = AppState.asrMode;
    this.cloudAsrUrl = AppState.cloudAsrUrl;
    this.asrApiBaseUrl = AppState.asrApiBaseUrl;
    this.dictBaseUrl = AppState.dictBaseUrl;
    this.asrApiModel = AppState.asrApiModel;
    this.asrApiKey = AppState.asrApiKey;
    this.asrApiChunkSec = AppState.asrApiChunkSec;
    this.vadGear = gearOfRms(AppState.vadMinRms);
    this.vadSilMs = AppState.vadSilMs;
    this.vadMinSegMs = AppState.vadMinSegMs;
    this.subjectKey = AppState.subjectKey;
    this.refreshSubject();
    this.updateAsrBaseHint();
  }

  /** base_url 实时校验提示（API 模式） */
  private updateAsrBaseHint(): void {
    const raw = this.asrApiBaseUrl.trim();
    if (raw.length === 0) {
      this.asrBaseHint = '';
      return;
    }
    const n = normalizeBaseUrl(raw);
    if (n.note.length > 0) {
      this.asrBaseHint = `⚠ 保存时将自动修正为：${n.url}（${n.note}）`;
    } else {
      this.asrBaseHint = `✓ 格式正确（实际请求 ${n.url}/v1/audio/transcriptions）`;
    }
  }

  /**
   * 刷新科目行：显示设置值 + 此刻实际生效的科目、词库规模、匹配依据。
   *
   * 【2026-09-30 重写 · 修「没有匹配到专业科目」】
   *
   * ## 原来的三个问题（用户反馈「为什么没有匹配到专业科目」）
   * ① **一步就掉通用**：`ongoing()` 返回 null 时立刻判「没有匹配到」，
   *    完全不看「今天上过什么」「上次用过什么」。周末、假期、课后自习
   *    这些**最常见的使用场景**全都显示「没匹配到」。
   * ② **看不出为什么**：既不知道对不对，也不知道是哪门课推出来的。
   * ③ **0 条**：通用科目自带 fixes 为空，但实际每条都跑 17 条通用纠正。
   *
   * ## 现在的取值链（依次尝试，命中即停）
   *   ① 用户手动选的科目            → 「已选：高等数学 · 36 术语 / 35 纠错」
   *   ② 此刻正在上的课              → 「此刻生效：大学物理 · 命中关键词『理论力学』」
   *   ③ 今天接下来/刚上过的课        → 「接下来：计算机网络 · 命中关键词『网络』」
   *   ④ 最近一次自动推断出的科目      → 「沿用上次：高等数学（今天课表无匹配）」
   *   ⑤ 都没有                      → 「课表里没有可识别的科目，先用通用纠错（17 条）」
   */
  private refreshSubject(): void {
    this.subjectLabel = SubjectLexicon.labelOfChoice(this.subjectKey);
    const common = SubjectLexicon.commonFixCount();

    // ① 手动指定：不需要推断，直接报生效科目
    if (this.subjectKey !== SubjectLexicon.AUTO) {
      const hw = SubjectLexicon.hotwords(this.subjectKey).length;
      const fx = SubjectLexicon.fixCount(this.subjectKey);
      this.subjectHint = `已选：${SubjectLexicon.labelOf(this.subjectKey)} · ${hw} 术语 / ${fx} 纠错`;
      return;
    }

    // ②③ 按课表推断（复用 AsrService 同一套取课逻辑，避免两处口径不一致）
    const now = Date.now();
    const name = CourseStore.currentCourseName(now);
    if (name.length > 0) {
      const g = SubjectLexicon.guessDetail(name);
      const hw = SubjectLexicon.hotwords(g.key).length;
      const fx = SubjectLexicon.fixCount(g.key);
      if (g.key === 'general') {
        // 有课但课表里这个词认不出 —— 也要如实说，并说明退回通用
        this.subjectHint = `课程「${name}」未命中词库，先用通用纠错（${common} 条）`;
      } else {
        const when = CourseStore.ongoing(now) != null ? '此刻生效' : '接下来';
        this.subjectHint =
          `${when}：${SubjectLexicon.labelOf(g.key)} · 命中「${g.hit}」· ${hw} 术语 / ${fx} 纠错`;
      }
      return;
    }

    // ④ 今天完全没课：沿用上次成功推断的科目
    const last = AppState.lastAutoSubject;
    if (last.length > 0 && last !== 'general') {
      const hw = SubjectLexicon.hotwords(last).length;
      const fx = SubjectLexicon.fixCount(last);
      this.subjectHint =
        `沿用上次：${SubjectLexicon.labelOf(last)}（今天课表无匹配）· ${hw} 术语 / ${fx} 纠错`;
      return;
    }

    // ⑤ 全新用户 / 从没推出来过
    this.subjectHint = `课表里没有可识别的科目，先用通用纠错（${common} 条）`;
  }

  private async saveAsr(): Promise<void> {
    AppState.asrMode = this.asrMode;
    // 不再回落硬编码域名：用户没填就保持空，由启动链路给出「未配置」提示。
    AppState.cloudAsrUrl = this.cloudAsrUrl.trim();
    const n = normalizeBaseUrl(this.asrApiBaseUrl);
    AppState.asrApiBaseUrl = n.url;
    this.asrApiBaseUrl = n.url;
    AppState.asrApiModel = this.asrApiModel.trim().length === 0 ? 'whisper-1' : this.asrApiModel.trim();
    this.asrApiModel = AppState.asrApiModel;
    AppState.asrApiKey = this.asrApiKey.trim();
    AppState.asrApiChunkSec = this.asrApiChunkSec;
    // 档位索引 → RMS 阈值（存的是数值，不存索引：以后调档位取值不会让旧存档错位）
    AppState.vadMinRms = VAD_GEAR_RMS[this.vadGear];
    AppState.vadSilMs = this.vadSilMs;
    AppState.vadMinSegMs = this.vadMinSegMs;
    AppState.subjectKey = this.subjectKey;

    await AppState.save('asrMode', AppState.asrMode);
    await AppState.save('cloudAsrUrl', AppState.cloudAsrUrl);
    await AppState.save('asrApiBaseUrl', AppState.asrApiBaseUrl);
    await AppState.save('asrApiModel', AppState.asrApiModel);
    await AppState.save('asrApiKey', AppState.asrApiKey);
    await AppState.save('asrApiChunkSec', AppState.asrApiChunkSec);
    await AppState.save('vadMinRms', AppState.vadMinRms);
    await AppState.save('vadSilMs', AppState.vadSilMs);
    await AppState.save('vadMinSegMs', AppState.vadMinSegMs);
    await AppState.save('subjectKey', AppState.subjectKey);

    AppState.log(`ASR 配置已保存：模式=${this.asrMode}`);
    this.asrSaved = true;
    this.asrDirty = false;
    setTimeout(() => {
      this.asrSaved = false;
    }, 2600);
  }

  // ---------- 大语言模型 ----------

  private loadLlm(): void {
    this.llmBaseUrl = AppState.llmBaseUrl;
    this.llmModel = AppState.llmModel;
    this.llmApiKey = AppState.llmApiKey;
    this.updateLlmBaseHint();
  }

  private updateLlmBaseHint(): void {
    const raw = this.llmBaseUrl.trim();
    if (raw.length === 0) {
      this.llmBaseHint = '';
      return;
    }
    const n = normalizeBaseUrl(raw);
    this.llmBaseHint = n.note.length > 0
      ? `⚠ 保存时将自动修正为：${n.url}（${n.note}）`
      : `✓ 格式正确（实际请求 ${n.url}/v1/chat/completions）`;
  }

  private async saveLlm(): Promise<void> {
    const n = normalizeBaseUrl(this.llmBaseUrl);
    AppState.llmBaseUrl = n.url;
    this.llmBaseUrl = n.url;
    AppState.llmModel = this.llmModel.trim();
    AppState.llmApiKey = this.llmApiKey.trim();
    await AppState.save('llmBaseUrl', AppState.llmBaseUrl);
    await AppState.save('llmModel', AppState.llmModel);
    await AppState.save('llmApiKey', AppState.llmApiKey);
    this.asrSaved = true;
    this.asrDirty = false;
    setTimeout(() => {
      this.asrSaved = false;
    }, 2600);
  }

  // ---------- 词典设置 ----------

  /**
   * 词典服务器地址的规范化。
   *
   * ⚠️ 与 `normalizeBaseUrl()` 的区别：那个会**剥离** `/v1` 这类已知端点后缀
   *    （因为 LLM 客户端自己会补 `/v1/chat/completions`）。
   *    词典端点由 `DictionaryClient.dictEndpoint()` 自己补 `/api/v1/word`，
   *    所以这里只做最小处理：补 `https://`、去尾部斜杠、**去掉可能误填的
   *    `/api/v1/word` 后缀**（免得拼成 `.../api/v1/word/api/v1/word`）。
   */
  private normalizeDictUrl(raw: string): string {
    let u: string = raw.trim();
    if (u.length === 0) {
      return '';
    }
    if (!/^https?:\/\//i.test(u)) {
      u = 'https://' + u;
    }
    u = u.replace(/\/+$/, '');
    u = u.replace(/\/api\/v1\/word$/i, '');
    return u;
  }

  private async saveDictUrl(): Promise<void> {
    const n: string = this.normalizeDictUrl(this.dictBaseUrl);
    AppState.dictBaseUrl = n;
    this.dictBaseUrl = n;
    await AppState.save('dictBaseUrl', n);
    this.dictUrlHint = n.length === 0
      ? '未配置，词典页会提示先填写地址'
      : `✓ 实际请求 ${n}/api/v1/word?w=hello`;
  }

  // ---------- 课表设置 ----------

  /** 从 CourseStore / ClassReminder 拉取当前配置到页面状态 */
  private loadSchedule(): void {
    const s = CourseStore.semester;
    this.name = s.name;
    this.openDate = s.openDate;
    this.totalWeeks = s.totalWeeks;
    this.weekOverride = s.weekOverride;
    this.sectionsToShow = s.sectionsToShow;
    this.cellHeight = s.cellHeight;
    this.colWidth = s.colWidth;
    this.nameSlot = s.nameSlot;
    this.locationSlot = s.locationSlot;
    this.teacherSlot = s.teacherSlot;
    this.cornerRadius = s.cornerRadius;
    this.shape = s.shape;
    this.firstColMode = s.firstColMode;
    this.showSaturday = s.showSaturday;
    this.showSunday = s.showSunday;
    this.showNonCurrentWeek = s.showNonCurrentWeek;
    this.showTeacher = s.showTeacher;
    this.showLocation = s.showLocation;
    this.showGrid = s.showGrid;
    this.bgColor = s.bgColor;
    this.textScale = s.textScale;
    this.blockOpacity = s.blockOpacity;
    this.reminderEnabled = ClassReminder.enabled;
    this.leadMinutes = ClassReminder.leadMinutes;
    this.openWeekdayText = `周${WD[CourseStore.openWeekday()]}`;
    this.holidays = s.holidays.slice();
  }

  /** 写回并持久化 */
  private async push(): Promise<void> {
    const s = CourseStore.semester;
    s.name = this.name;
    s.openDate = this.openDate;
    s.totalWeeks = this.totalWeeks;
    s.weekOverride = this.weekOverride;
    s.sectionsToShow = this.sectionsToShow;
    s.cellHeight = this.cellHeight;
    s.colWidth = this.colWidth;
    s.nameSlot = this.nameSlot;
    s.locationSlot = this.locationSlot;
    s.teacherSlot = this.teacherSlot;
    s.cornerRadius = this.cornerRadius;
    s.shape = this.shape;
    s.firstColMode = this.firstColMode;
    s.showSaturday = this.showSaturday;
    s.showSunday = this.showSunday;
    s.showNonCurrentWeek = this.showNonCurrentWeek;
    s.showTeacher = this.showTeacher;
    s.showLocation = this.showLocation;
    s.showGrid = this.showGrid;
    s.bgColor = this.bgColor;
    s.textScale = this.textScale;
    s.blockOpacity = this.blockOpacity;
    ClassReminder.enabled = this.reminderEnabled;
    ClassReminder.leadMinutes = this.leadMinutes;
    ClassReminder.setEnabled(this.reminderEnabled);
    await ClassReminder.saveCfg();
    await CourseStore.saveConfig();
  }

  private weekLabel(): string {
    const w = CourseStore.effectiveWeek(Date.now());
    if (w === 0) {
      return '未开学';
    }
    if (w < 0) {
      return '已结课';
    }
    return `第 ${w} 周`;
  }

  /** 打开自定义日期选择层 */
  private openDatePick(): void {
    const cur = this.openDate;
    let d = cur.length > 0 ? new Date(cur.replace(/-/g, '/')) : new Date();
    if (isNaN(d.getTime())) {
      d = new Date();
    }
    this.pickY = d.getFullYear();
    this.pickM = d.getMonth() + 1;
    this.pickD = d.getDate();
    this.showDatePick = true;
  }

  private pickValid(): boolean {
    const d = new Date(this.pickY, this.pickM - 1, this.pickD);
    return d.getFullYear() === this.pickY && d.getMonth() + 1 === this.pickM && d.getDate() === this.pickD;
  }

  private pickWeekday(): number {
    const d = new Date(this.pickY, this.pickM - 1, this.pickD);
    const js = d.getDay();
    return js === 0 ? 7 : js;
  }

  private pickPreview(): string {
    if (!this.pickValid()) {
      return '该日期不存在，请调整';
    }
    return `该日期是 周${WD[this.pickWeekday()]} —— 课表第一列会是「周${WD[this.pickWeekday()]}」`;
  }

  /** 快捷：0=今天 1=本周一 2=下周一 */
  private applyQuick(idx: number): void {
    const now = new Date();
    let target = now;
    if (idx === 1 || idx === 2) {
      const js = now.getDay();
      const back = js === 0 ? 6 : js - 1;
      target = new Date(now.getFullYear(), now.getMonth(), now.getDate() - back + (idx === 2 ? 7 : 0));
    }
    this.pickY = target.getFullYear();
    this.pickM = target.getMonth() + 1;
    this.pickD = target.getDate();
  }

  private applyDate(): void {
    if (!this.pickValid()) {
      return;
    }
    const mm = this.pickM.toString().padStart(2, '0');
    const dd = this.pickD.toString().padStart(2, '0');
    const ds = `${this.pickY}-${mm}-${dd}`;
    if (this.pickForHoliday) {
      CourseStore.addHoliday(ds).then(() => {
        this.holidays = CourseStore.semester.holidays.slice();
      });
      this.pickForHoliday = false;
      this.showDatePick = false;
      return;
    }
    this.openDate = ds;
    this.openWeekdayText = `周${WD[this.pickWeekday()]}`;
    this.showDatePick = false;
    this.push();
  }

  private confirmClear(): void {
    AlertDialog.show({
      title: '清空课表',
      message: '将删除本机保存的全部课程（不影响教务系统），确定吗？',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '清空',
        fontColor: Theme.danger(),
        action: () => {
          CourseStore.clearAll();
          ClassReminder.refresh();
        },
      },
    });
  }

  // ---------- 碰一碰分享 ----------

  /**
   * 碰一碰监听在**页面可见时**才注册，隐藏即注销。
   * 理由：① 避免用户不在设置页时误碰触发分享；② 重复注册会导致一次碰触多次回调；
   *      ③ 从后台切回前台时要重新注册，所以放在 onPageShow 而不是 aboutToAppear。
   */
  onPageShow(): void {
    this.enableKnock();
  }

  onPageHide(): void {
    ShareService.unregisterKnock();
    this.shareOn = false;
    this.shareStatus = '';
  }

  private enableKnock(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    ShareService.registerKnock(ctx, (text: string) => {
      this.shareStatus = text;
    }).then((ok: boolean) => {
      this.shareOn = ok;
    });
  }

  private pokeShare(): void {
    if (CourseStore.courses.length === 0) {
      promptAction.showToast({ message: '课表是空的，先添加课程再分享', duration: 2000 });
      return;
    }
    if (!this.shareOn) {
      this.enableKnock();
    }
    promptAction.showToast({
      message: `已就绪：把两台设备的顶部碰一下即可发送「${CourseStore.semester.name}」`,
      duration: 3000,
    });
  }

  // ---------- 课表导出 ----------

  private async exportSchedule(kind: string): Promise<void> {
    if (CourseStore.courses.length === 0) {
      promptAction.showToast({ message: '课表是空的，没有可导出的内容', duration: 2000 });
      return;
    }
    try {
      const msg = await ScheduleExportService.export(kind);
      // 【2026-10-07】'已取消' 是用户主动取消，不是成功 —— 仍走 toast，
      // 弹「导出完成」浮层会误导。
      if (msg === '已取消') {
        promptAction.showToast({ message: msg, duration: 2000 });
        return;
      }
      this.exportDoneMsg = msg;
      this.showExportDone = true;
    } catch (e) {
      const err = e as BusinessError;
      promptAction.showToast({ message: `导出失败：${err.message ?? err}`, duration: 3000 });
    }
  }

  /**
   * 导出完成浮层 —— 复用周选择器那套「蒙层 + sheet 材质」结构（`Mat.sheet()`）。
   *
   * 【2026-10-07 接入 ill_export_done】原先只有 toast，而导出返回的消息里带完整文件名
   * （`知课笺-2026春-1012-1530.png`），2.6 秒的 toast 根本读不完。
   * ⚠️ 官方 `AlertDialog` 只有 title/message/按钮，**放不了插图**，所以走自定义浮层。
   */
  @Builder
  exportDonePanel() {
    Column() {
      Column() {
        Image($r('app.media.ill_export_done'))
          .width(Size.statusIll * 1.6)
          .height(Size.statusIll * 1.6)
          .objectFit(ImageFit.Contain)
          .margin({ bottom: Space.m })
        Text('导出完成')
          .fontSize(FontSize.subtitleM)
          .fontWeight(Weight.bold)
          .fontColor(Theme.sysTextMain())
        Text(this.exportDoneMsg)
          .fontSize(FontSize.bodyS)
          .fontColor(Theme.sysTextSub())
          .textAlign(TextAlign.Center)
          .lineHeight(FontSize.bodyS * 1.4)
          .margin({ top: Space.s })
        Text('文件已保存到系统「文件」应用，可在「我的 - 下载」中查看。')
          .fontSize(FontSize.captionL)
          .fontColor(Theme.sysTextSub())
          .textAlign(TextAlign.Center)
          .lineHeight(FontSize.captionL * 1.4)
          .margin({ top: Space.xs })
      }
      .width('100%')
      .padding(Space.l)
      .borderRadius(Radius.l)
      .backgroundColor(Theme.innerBase())
      .systemMaterial(Mat.tile());

      Button('知道了', { type: ButtonType.Capsule, stateEffect: true })
        .width('100%')
        .margin({ top: Space.l })
        .controlSize(ControlSize.NORMAL)
        .fontWeight(Weight.medium)
        .fontColor(Theme.onEmphasize())
        .backgroundColor(Theme.sysEmphasize())
        .systemMaterial(Mat.button())
        .onClick(() => {
          this.showExportDone = false;
        });
    }
    .width('80%')
    .padding(Space.l)
    .borderRadius(Radius.xl)
    .backgroundColor(Theme.sysCard())
    .systemMaterial(Mat.sheet());
  }

  // ================= 小组件 =================

  /**
   * 步进按钮（只传静态符号，动态部分在内部读状态）。
   *
   * 【2026-09-28 第二十次修正 · 改用官方 Button 组件】
   * 原来用 `Text` **冒充**按钮：只有 `.onClick`，没有按下反馈、没有按钮语义。
   * 改成官方 `Button`：
   *   · `ButtonType.Normal` —— 矩形按钮（步进键是"方键"，不是胶囊；圆角由 `borderRadius` 控制）
   *   · `controlSize(ControlSize.NORMAL)` —— 官方标准档（走系统字号）
   *   · `role(ButtonRole.NORMAL)` + `stateEffect` —— 官方按下态反馈、无障碍语义
   * ⚠️ 【2026-09-28 第二十八次修正】底色从 `idleColor()`（跟色系的暖褐）改为
   * `Theme.sysFill()`（系统中性填充）；字色用 `Theme.sysEmphasize()` 蓝。
   */
  @Builder
  stepBtn(text: string, tap: () => void) {
    Button(text, { type: ButtonType.Normal, stateEffect: true })
      .controlSize(ControlSize.NORMAL)
      .role(ButtonRole.NORMAL)
      .fontColor(Theme.sysEmphasize())
      .width(40)
      .height(Size.touchTarget)
      .backgroundColor(Theme.sysFill())
      .systemMaterial(Mat.tile())
      .borderRadius(Radius.s)
      .onClick(tap);
  }

  /**
   * 分区标题 —— 分**两个层级**（2026-09-28 第二十五次修正）。
   *
   * ## 用户要求（原话）
   * > 「保留标题，但是要用特殊的排版来强调它们是一级标题还是二级标题。」
   * > 选定方向：**字号 + 字重 + 颜色 三重区分**
   *
   * ## 两级规格
   * | 级别 | 字号 | 字重 | 颜色 | 用途 |
   * |---|---|---|---|---|
   * | 一级 (`level=1`) | `subtitleM`(16) | **Bold** | **主题色** `tc` | 大分区（如「课表数据」「管理」这类独立成块的） |
   * | 二级 (`level=2`) | `bodyS`(12) | Medium | 次文字色 | 分区内的小标题（如「科目词库」「大语言模型」这类在一块里的） |
   *
   * 三重差异同时起作用，即使色弱用户也能靠字号/字重分辨层级 —— 只靠颜色是不合格的分级。
   *
   * ⚠️ `level` 有默认值 2（保持现有调用点行为不变）。
   *    本项目 ArkTS 对**带参 @Builder** 有按值传参限制，但这里传的是**静态字面量**，
   *    不涉及动态状态，所以是安全的（动态值才不能传）。
   */
  @Builder
  secTitle(title: string, level: number = 2) {
    Text(title)
      .fontSize(level === 1 ? FontSize.subtitleM : FontSize.bodyS)
      .fontWeight(level === 1 ? Weight.bold : Weight.medium)
      .fontColor(level === 1 ? this.tc : Theme.sysTextSub())
      .width('100%')
      .padding({
        left: Space.xs,
        right: Space.xs,
        top: level === 1 ? Space.xl : Space.l,
        bottom: Space.s,
      });
  }

  /**
   * 列表项之间的灰色分隔线（华为应用市场 / 系统设置样式）。
   *
   * ## 用户要求（原话）
   * > 「不一定非得把它包起来，我们可以用一条灰色的横线给它分割开来」
   * > 「分隔线是浅灰色，但是它的背景是深灰色，然后它的卡片是纯白色。
   * >   如果你切换成了深色模式的话，那你就能看到它的卡片是浅黑色，但是它的背景变成了深黑色。」
   *
   * ## 为什么不用 `Divider` 组件
   * `Divider` 会独占一行、参与 Column 布局，在「行与行之间」的场景会额外撑高。
   * 这里要的是**贴着上一行底部的一条线**，所以用 `Row` + `height(Size.divider)`
   * （与课表页 `CourseTableView` 的 GRID_LINE 网格线是同一个做法）。
   *
   * ## 颜色走系统资源
   * `Theme.sysSeparator()` = `ohos_id_color_list_separator`，
   * 浅色模式浅灰、深色模式自动换成深色模式的分隔线色 —— 不用手写两份。
   *
   * ## ⚠️ 用 `padding` 而不是 `margin` 做左缩进
   * `margin` 会**加在尺寸之外**，在 `width('100%')` 的行上会让它溢出容器右边；
   * `padding` 才是把线往里收。这是本工程反复踩过的坑（见课程块色带溢出那次）。
   *
   * ## 两个变体
   * · `listSeparator()`       —— 左缩进 `Space.m`，与列表项文本对齐（默认用这个）
   * · `listSeparatorFull()`   —— 通栏，用于分组与分组之间
   *
   * 注：不写成带默认参数的单个 @Builder —— 本项目 ArkTS 对带参 @Builder 有
   *     按值传参的限制，两个无参变体更稳妥。
   */
  @Builder
  listSeparator() {
    Row()
      .width('100%')
      .height(Size.divider)
      .backgroundColor(Theme.sysSeparator())
      .padding({ left: Space.m });
  }

  /** 通栏分隔线（分组之间用，左侧不缩进） */
  @Builder
  listSeparatorFull() {
    Row()
      .width('100%')
      .height(Size.divider)
      .backgroundColor(Theme.sysSeparator());
  }

  /** 取某个槽位的当前值 */
  private slotOf(name: string): string {
    if (name === 'name') {
      return this.nameSlot;
    }
    if (name === 'location') {
      return this.locationSlot;
    }
    return this.teacherSlot;
  }

  private setSlot(name: string, v: string): void {
    if (name === 'name') {
      this.nameSlot = v;
    } else if (name === 'location') {
      this.locationSlot = v;
    } else {
      this.teacherSlot = v;
    }
    this.push();
  }

  /**
   * 位置选择：标签在上，9 个槽位分两行（5 + 4，第二行末尾补空位对齐）。
   * 参数只传**静态标识**（标签 + 槽位名），动态值在内部读 @State ——
   * 带参 @Builder 是按值传参，传动态值的话选中态不会刷新。
   *
   * 【2026-09-28 第二十八次修正 · 配色与对齐】
   * · 选中：`Theme.sysEmphasize()`（系统强调色蓝）实底 + `Theme.onEmphasize()` 反白字
   *   —— 原来用 `this.tc` 主题色，截图里是橙红，不合用户"全部改成蓝色"的口径。
   * · 未选中：`Theme.sysFill()` 中性填充 + `Theme.sysFillInk()` 次文字色
   *   —— 原来是 `Theme.idleColor()`，跟着四套色系走，浅色系下是一块脏黄。
   * · 第二行补一个空占位格（`SLOT_ROW2_PAD`），两行列线对齐。
   */
  @Builder
  slotSetting(label: string, slotName: string) {
    Column() {
      Text(label)
        .fontSize(FontSize.subtitleM)
        .fontColor(Theme.sysTextMain())
        .width('100%');
      Row() {
        ForEach(SLOT_ROW1, (opt: string, idx: number) => {
          Text(opt)
            .fontSize(FontSize.bodyS)
            .fontColor(SLOT_V1[idx] === this.slotOf(slotName) ? Theme.onEmphasize() : Theme.sysFillInk())
            .textAlign(TextAlign.Center)
            .constraintSize({ minHeight: Size.listSingle })
            .layoutWeight(1)
            .margin({ left: idx === 0 ? Space.none : Space.xs })
            .borderRadius(Radius.s)
            .backgroundColor(SLOT_V1[idx] === this.slotOf(slotName) ? Theme.sysEmphasize() : Theme.sysFill())
            .onClick(() => {
              this.setSlot(slotName, SLOT_V1[idx]);
            });
        }, (opt: string) => `slot1-${slotName}-${opt}`);
      }
      .width('100%')
      .margin({ top: Space.s });

      Row() {
        ForEach(SLOT_ROW2_PAD, (opt: string, idx: number) => {
          if (opt.length === 0) {
            // 补位格：只占宽度，不画任何东西
            Row().layoutWeight(1).margin({ left: Space.xs });
          } else {
            Text(opt)
              .fontSize(FontSize.bodyS)
              .fontColor(SLOT_V2_PAD[idx] === this.slotOf(slotName) ? Theme.onEmphasize() : Theme.sysFillInk())
              .textAlign(TextAlign.Center)
              .constraintSize({ minHeight: Size.listSingle })
              .layoutWeight(1)
              .margin({ left: idx === 0 ? Space.none : Space.xs })
              .borderRadius(Radius.s)
              .backgroundColor(SLOT_V2_PAD[idx] === this.slotOf(slotName) ? Theme.sysEmphasize() : Theme.sysFill())
              .onClick(() => {
                this.setSlot(slotName, SLOT_V2_PAD[idx]);
              });
          }
        }, (opt: string, idx: number) => `slot2-${slotName}-${idx}`);
      }
      .width('100%')
      .margin({ top: Space.xsPlus });
    }
    .width('100%')
    .padding({ top: Space.m, bottom: Space.l });
  }

  // ================= 顶层 =================

  /**
   * 顶栏（**自绘，已从 HDS 回退**）：Tab 形态只画标题；独立路由形态带返回键。
   *
   * Tab 内页不能套 `HdsNavigation`（真机白屏，详见 CourseTableView.barContent 注释）。
   * 本页既是 Tab 内页又是独立路由页，统一走自绘：`if (!this.fromTab)` 出返回键。
   * 沉浸光感由 `Mat.bar()`（含 `lightEffect`）提供。
   *
   * 边距例外：顶栏是主题色满铺横条，用 Space.l 而非 Layout.screenMargin()。
   */
  /**
   * 顶栏（自绘，非 HDS —— Tab 内页不能套 HdsNavigation）。
   *
   * ## 【2026-09-28 第十二次修正 · 改为悬浮圆角胶囊】
   * 用户反馈：「听课、设置页你把胶囊的底色调没了，但是最顶上的听课还有设置，
   * 这些胶囊你都没有设置，**它还是作为两个不同的容器**。」
   *
   * → 原状：一条满宽实色条（`backgroundColor(this.tpage)`，不透明），
   *   与下方卡片是两套容器；且是 Column 的**兄弟节点**，内容永远不会从它下方经过。
   * → 改法：与课表页顶栏胶囊同一套玻璃语言：
   *   外层留白 + 内层圆角胶囊 + `Mat.floatGlass()`（含投影）+ 均匀薄雾 + 上缘高光；
   *   并在 `build()` 里改成 Stack 浮层，滚动内容顶部让出 `barTotalH()`。
   *
   * ⚠️ 圆角开在内层（外层留白会被算进圆角范围）；薄雾层高度给确定值不写 `'100%'`。
   */
  @Builder
  barContent() {
    // ---- 外层：四周留白，让胶囊脱离屏幕边缘 ----
    Row() {
      this.barCapsule()
    }
    .width('100%')
    .padding({
      // fromTab 时左侧本来就窄（继承 Main 的 Tab 布局）；否则用常规边距 - 6
      left: this.fromTab ? (Layout.screenMargin() - 6) : (Space.m - 2),
      right: Layout.screenMargin() - 6,
      top: Space.s + WindowInsets.statusBarVp(),
      bottom: Space.none,
    })
  }

  /** 顶栏胶囊本体（设置页） */
  @Builder
  barCapsule() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ---- 薄雾层（垫在内容下面，高度必须给确定值）----
      // 【2026-09-28 第十五次修正】薄雾收敛回低值 —— 底色已改用 soft 微染（见外层），
      // 这里再叠 0.20 近白会把刚拉出来的底色冲淡回去。薄雾只负责表面反光。
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

      // ---- 内容 ----
      // 【2026-09-28 第二十一次修正 · 前景色改系统资源值以启用 colorInvert】
      //   同听课页：`colorInvert` 只认 `$r('sys.color.*')`，硬编码的 `this.tmain` 不触发。
      //   返回箭头与标题都走 `ohos_id_color_text_primary`。
      Row() {
        if (!this.fromTab) {
          Text('\u2039')
            .fontSize(FontSize.titleM)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .constraintSize({ minHeight: Size.touchTarget, minWidth: Size.touchTarget })
            .textAlign(TextAlign.Center)
            .onClick(() => {
              router.back();
            });
        }
        Text('设置')
          .fontSize(FontSize.titleM)
          .fontWeight(Weight.bold)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .layoutWeight(1)
          .padding({ left: Space.none });
        // 分区切换（语音识别 / 课表设置）—— 收进胶囊最右侧
        this.segButtons();
      }
      .width('100%')
      .height(this.barCapsuleH())
      // 【2026-09-28 第十六次修正】左右 padding Space.l(16) → Space.s(8)：
      //   胶囊内高收到 64 后（原 72），16 的水平留白在视觉上过宽、胶囊显得"胖"。
      //   统一成与课表页胶囊相同的 Space.s。
      .padding({
        left: this.fromTab ? Space.s : Space.none,
        right: Space.s,
      })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .borderRadius(Radius.xl)
    // 【2026-09-28 第十六次修正 · 上一轮把透明性改没了，这里补回】
    //   第十五轮为了"让底色看得见"，写成了 `mix(softColor, #FFF, 0.25)` ——
    //   **alpha 是 100%**，等于一块实色板，沉浸材质完全透不出来。
    //   用户回图：「为什么你的胶囊都不透明了」—— 判断完全正确。
    //
    //   正解是**两个维度分开调**：
    //     · 色相/亮度 → 参照 `softColor`（保证在浅页面上读得出边界）
    //     · 不透明度 → 必须**留出透明度**（材质才有的透）
    //   即：`alphaOf( mix(softColor, #FFF, 0.25), 0.45 )`
    //   而不是在 tpage(近乎白) 与 实色 之间二选一。
    .backgroundColor(Theme.floatGlassBase())
    .systemMaterial(Mat.floatGlass())
    .border({
      width: { top: 1, bottom: Size.divider },
      color: {
        top: Theme.glassHighlight(),
        // 【2026-09-28 第二十二次修正 · 下缘改中性灰分隔线】
        //   用户要求「容器和容器之间用一条灰色横线隔离」→ 特指顶栏胶囊下方。
        //   中性灰、不跟主题色走，三页统一（课表/听课/设置同一处改法）。
        bottom: Theme.alphaOf('#B3B3B3', 0.50),
      },
    })
  }

  /**
   * 顶栏胶囊内高（设置页）。
   *
   * 【2026-09-28 第十六次修正 · 三页统一为 64】
   * 用户反馈「第三个胶囊大小和前两个不一样」—— 查实三页**三个值**
   * （课表 64 / 听课 80 / 设置 72）。以课表页为准统一成 64。
   * ⚠️ 内容行高 = 64 - 12*2 = 40vp，胶囊内要正好一行标题 + 两枚按钮，不能再塞东西。
   */
  private barCapsuleH(): number {
    return Size.touchTarget + Space.s * 2;
  }

  /**
   * 顶栏胶囊**总占位高度** —— 滚动内容需要让出的顶部空间。
   * ⚠️ 必须精确：少算 → 第一张卡被胶囊盖住；多算 → 顶部凭空多一段空白。
   *
   * 【2026-09-28 第十五次修正】下侧余量 `Space.s`(8) → `Space.l`(16)。
   * 用户回图显示「鸿蒙端侧引擎」那张卡的上沿与胶囊下沿贴死/轻微重叠。
   * 几何上 `barContent` 的胶囊底边在 `statusBar + Space.s + 胶囊高`，
   * 而这里给的是 `+ Space.s`，扣掉胶囊自带 border 后几乎为零 —— 太紧。
   * 拉开到 16 让首屏内容与胶囊之间有一道可读的呼吸缝。
   */
  private barTotalH(): number {
    return WindowInsets.statusBarVp() + Space.s + this.barCapsuleH() + Space.l;
  }

  /**
   * 分区切换按钮（语音识别 / 课表设置）—— **收进顶栏胶囊最右侧**。
   *
   * ## 【2026-09-28 第十三次修正】
   * 用户要求：「设置页的语音识别和课表设置一起放到胶囊里。放到胶囊的最右侧。」
   * → 原来是一条**独立满宽的分段条**（`segBar()`，在胶囊下方占一整行）。
   *   现改为两枚紧凑胶囊按钮，挂在顶栏胶囊 `Row` 的末尾
   *   （标题 `layoutWeight(1)` 把它们顶到最右）。
   *
   * ## 与原 `segBar()` 的区别
   * · 不再 `width('100%')`、不再 `layoutWeight(1)`（那是"平分整行"的做法）
   * · 不再自己带 `screenMargin` / `contentMaxWidth`（位置由胶囊决定）
   * · 横向 padding 收窄（Space.m），字号用 captionL，整体压到能塞进胶囊
   *
   * ## 选中态配色（沿用 segBar 的历史结论，别改回去）
   * 选中 = 主题色实底 + `ton` 字色 + **不挂材质**（挂材质会被雾面冲淡成"粉白"，
   * 导致"选中的比没选中的还浅"）；未选中 = `idleColor` 底 + `idleInk` 字 + 薄玻璃。
   *
   * 【2026-09-28 第二十次修正 · 改用官方 Button 组件】
   * 原来用 `Text` **冒充**按钮（只有 `.onClick`，无按下反馈/按钮语义）。
   * 改成官方 `Button`：
   *   · `ButtonType.Capsule` —— 胶囊形（原来手写 `borderRadius(Radius.full)` 就是在模拟它）
   *   · `controlSize(SMALL)` —— 官方小号档，正好能塞进顶栏胶囊
   *   · `role` + `stateEffect` —— 官方按下反馈 + 无障碍语义
   * ⚠️ 高度不再手写 `touchTarget*0.62`，交给官方 SMALL 档；仅在必要时用 `height`
   *    微调到能塞进顶栏胶囊（顶栏内高 64 - 上下 12 padding = 40 可用）。
   */
  @Builder
  segButtons() {
    Row() {
      ForEach(SEC_TITLES, (t: string, i: number) => {
        Button(t, { type: ButtonType.Capsule, stateEffect: true })
          .controlSize(ControlSize.SMALL)
          .role(ButtonRole.NORMAL)
          .fontWeight(i === this.sec ? Weight.medium : Weight.regular)
          .fontColor(i === this.sec ? Theme.onEmphasize() : Theme.sysFillInk())
          .height(Size.touchTarget * 0.62)
          .padding({ left: Space.m, right: Space.m })
          .margin({ left: i === 0 ? Space.none : Space.xs })
          .backgroundColor(i === this.sec ? Theme.sysEmphasize() : Theme.sysFill())
          .systemMaterial(i === this.sec ? undefined : Mat.tile())
          .onClick(() => {
            this.sec = i;
          });
      }, (t: string) => `sec-${t}`);
    }
    .alignItems(VerticalAlign.Center)
  }

  // ================= 一、语音识别 =================

  /**
   * 词典设置分区（2026-10-10 新增）。
   *
   * ⚠️ **独立成一个分段**，不塞进「语音识别」里 —— 词典与语音无关，
   *    混在一起会让用户以为查词要走 ASR 链路。
   */
  @Builder
  dictSection() {
    Column() {
      this.secTitle('词典服务', 1);
      Column() {
        Text('服务器地址')
          .fontSize(FontSize.subtitleM)
          .fontColor(Theme.sysTextMain())
        // ⚠️ 地址**留空由用户填**（遵循 2026-09-28 用户明确要求：
        //    「wss 的网址别再填我的了」）。空值时词典页会提示"未配置"，
        //    而**不是偷偷回落到某个域名**。
        this.field('如 https://dictionary.xsheep.cn', this.dictBaseUrl, false, (v: string) => {
          this.dictBaseUrl = v;
          this.dictUrlHint = '';
        });
        Text(this.dictUrlHint.length > 0 ? this.dictUrlHint
          : '填到域名即可，程序会自动补 /api/v1/word')
          .fontSize(FontSize.captionL)
          .fontColor(Theme.sysTextSub())
          .width('100%')
          .margin({ top: Space.xs })
          .lineHeight(FontSize.captionL * 1.4);
        Button('保存地址', { type: ButtonType.Normal, stateEffect: true })
          .width('100%')
          .height(Size.touchTarget)
          .margin({ top: Space.m })
          .fontSize(FontSize.subtitleM)
          .fontWeight(Weight.medium)
          .fontColor(Theme.onEmphasize())
          .backgroundColor(Theme.sysEmphasize())
          .onClick(() => {
            this.saveDictUrl();
          });
      }
      .width('100%')
      .padding(Space.l)
      .margin({ top: Space.none })
      .borderRadius(Radius.l)
      .backgroundColor(Theme.sysCard())
      .alignItems(HorizontalAlign.Start);

      this.secTitle('关于数据来源', 2);
      Column() {
        Text('英文释义：Open English WordNet（CC BY 4.0，派生自 Princeton WordNet），未作修改。')
          .fontSize(FontSize.bodyS)
          .fontColor(Theme.sysTextSub())
          .width('100%')
          .lineHeight(FontSize.bodyS * 1.5)
        Text('中文释义：ECDICT（MIT）。音标已规范化为 IPA。')
          .fontSize(FontSize.bodyS)
          .fontColor(Theme.sysTextSub())
          .width('100%')
          .lineHeight(FontSize.bodyS * 1.5)
          .margin({ top: Space.s })
        Text('双语例句：Tatoeba（CC BY 2.0 FR），每条标注作者。')
          .fontSize(FontSize.bodyS)
          .fontColor(Theme.sysTextSub())
          .width('100%')
          .lineHeight(FontSize.bodyS * 1.5)
          .margin({ top: Space.s })
        Text('发音：服务端 espeak-ng 合成，非第三方录音。')
          .fontSize(FontSize.bodyS)
          .fontColor(Theme.sysTextSub())
          .width('100%')
          .lineHeight(FontSize.bodyS * 1.5)
          .margin({ top: Space.s })
      }
      .width('100%')
      .padding(Space.l)
      .margin({ top: Space.m })
      .borderRadius(Radius.l)
      .backgroundColor(Theme.sysCard())
      .alignItems(HorizontalAlign.Start);
    }
    .width('100%')
  }

  @Builder
  asrSection() {
    Column() {
      // ---- 识别方式 ----
      // 一级标题：语音识别大区的首标题（16vp / Bold / 主题色）
      this.secTitle('识别方式', 1);
      Column() {
        // ======================================================================
        // 【2026-09-28 第十四次修正 · 选中态改「深色胶囊 + 白字」】
        //
        // ## 用户要求（原话）
        // > 「识别方式 选项。选中 - 深色胶囊 + 白字；未选中 - 灰底深字（保持现状）」
        // > 用户另外说「我想要的是跟课表里面一样的效果」——
        // > ⚠️ 但课表课程块实际是**浅底 + 深字**（`CourseColor.bg`/`fg`），
        // >    与"深色胶囊 + 白字"相反。此处**以用户最新那句明确指令为准**
        // >    （深底白字），把"跟课表一样"理解为"对比要像课表那样鲜明"，不是照抄浅底。
        //
        // ## 改动
        // · 选中：`this.tc` 主题色**实底** + 主文 `this.ton`（onTheme，反白）
        //          + 副文 `this.ton` 降不透明度（副文不能和主文同重，否则糊成一片）
        //          + 右侧圆点也用 `this.ton`
        // · 未选中：`idleColor()` 灰底 + `tmain` 深字 + `tsub` 副文 + `idleInk` 圆点（原样）
        //
        // ## ⚠️ 为什么不挂材质
        // 选中态是"我要这块显眼"，挂材质会被系统雾面冲淡、跟着背景跑
        // → 产生"选中的比没选中的还浅"（本工程已有血案，见 segButtons 注释）。
        // ======================================================================
        ForEach(ASR_LABELS, (lb: string, i: number) => {
          Column() {
            Row() {
              Column() {
                Text(lb)
                  .fontSize(FontSize.subtitleM)
                  .fontColor(ASR_VALUES[i] === this.asrMode ? Theme.onEmphasize() : Theme.sysFillInk());
                Text(ASR_DESCS[i])
                  .fontSize(FontSize.bodyS)
                  // 选中：白字降到 0.9（副文不能和主文同重，但也不能太淡 —— 0.78 时发灰看不清）
                  // 未选中：单独用次级文字色，和主文拉开层次
                  .fontColor(ASR_VALUES[i] === this.asrMode ? Theme.onEmphasize() : Theme.sysTextSub())
                  .opacity(ASR_VALUES[i] === this.asrMode ? 0.9 : 1)
                  .margin({ top: Space.textGap });
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1);

              Text('●')
                .fontSize(FontSize.bodyM)
                // 选中：深底上的圆点用反色；未选中：中性填充上的次文字色
                .fontColor(ASR_VALUES[i] === this.asrMode ? Theme.onEmphasize() : Theme.sysFillInk());
            }
            .width('100%');
          }
          .width('100%')
          // 列表项：双行、有右侧指示元素 → 官方 72
          .constraintSize({ minHeight: Size.listDoubleWithIcon })
          .justifyContent(FlexAlign.Center)
          .padding(Space.m)
          .borderRadius(Radius.m)
          .margin({ top: Space.s })
          // 选中 = 系统强调色蓝实底；未选中 = 系统中性填充
          .backgroundColor(ASR_VALUES[i] === this.asrMode ? Theme.sysEmphasize() : Theme.sysFill())
          .onClick(() => {
            this.asrMode = ASR_VALUES[i];
            this.asrDirty = true;
          });
        }, (lb: string) => `asr-${lb}`);

        if (this.asrMode === 'cloud') {
          this.secTitle('自建云端服务地址');
          // 输入框占位符不再填私人域名，只给格式示范。
          this.field('wss://你的域名/asr', this.cloudAsrUrl, false, (v: string) => {
            this.cloudAsrUrl = v;
            this.asrDirty = true;
          });
          Text('需自备服务端。本仓库提供一份可直接交付给 AI 的搭建提示词，'
            + '生成的服务端实现了本应用使用的流式协议（首帧 JSON 握手 → PCM 上行 → partial/final 回帧）。')
            .fontSize(FontSize.bodyS)
            .fontColor(Theme.sysTextSub())
            .width('100%')
            .lineHeight(FontSize.bodyS * 1.4)
            .margin({ top: Space.xsPlus });
        }

        if (this.asrMode === 'api') {
          this.secTitle('大模型 API（OpenAI 兼容 · 语音转文字）');
          this.field('base_url（如 https://api.openai.com）', this.asrApiBaseUrl, false,
            (v: string) => {
              this.asrApiBaseUrl = v;
              this.asrDirty = true;
              this.updateAsrBaseHint();
            });
          Text(this.asrBaseHint)
            .fontSize(FontSize.bodyS)
            .fontColor(this.asrBaseHint.startsWith('⚠') ? Theme.warn() : Theme.success())
            .width('100%')
            .lineHeight(FontSize.bodyS * 1.4)
            .margin({ top: Space.xs });
          this.field('模型名（如 whisper-1 / gpt-4o-transcribe）', this.asrApiModel, false,
            (v: string) => {
              this.asrApiModel = v;
              this.asrDirty = true;
            });
          this.field('api_key（只存本机）', this.asrApiKey, true, (v: string) => {
            this.asrApiKey = v;
            this.asrDirty = true;
          });

          Row() {
            Text('兜底切段上限').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
            Text(`${this.asrApiChunkSec} 秒`)
              .fontSize(FontSize.bodyM)
              .fontColor(Theme.sysTextSub())
              .margin({ right: Space.m });
            this.stepBtn('－', () => {
              const n = this.asrApiChunkSec - 1;
              this.asrApiChunkSec = n < 2 ? 2 : n;
              this.asrDirty = true;
            });
            Row().width(Space.s);
            this.stepBtn('＋', () => {
              const n = this.asrApiChunkSec + 1;
              this.asrApiChunkSec = n > 8 ? 8 : n;
              this.asrDirty = true;
            });
          }
          .width('100%')
          .constraintSize({ minHeight: Size.listDoubleWithIcon });

          // ---- 切分灵敏度（VAD）----
          // 【2026-10-02】原先是 `AsrService` 顶部的三个硬编码常量，现开放到这里：
          // 安静教室和嘈杂宿舍的底噪差一个量级，出厂值不可能两边都合适，必须能现场调。
          this.secTitle('切分灵敏度');

          Row() {
            Text('说话声识别').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain());
            Row() {
              ForEach(VAD_GEAR_LABELS, (opt: string, idx: number) => {
                Text(opt)
                  .fontSize(FontSize.subtitleS)
                  .fontColor(idx === this.vadGear ? Theme.onEmphasize() : Theme.sysFillInk())
                  .textAlign(TextAlign.Center)
                  .padding({ left: Space.m, right: Space.m, top: Space.xs, bottom: Space.xs })
                  .margin({ left: idx === 0 ? Space.none : Space.xsPlus })
                  .borderRadius(Radius.full)
                  .backgroundColor(idx === this.vadGear ? Theme.sysEmphasize() : Theme.sysFill())
                  .onClick(() => {
                    if (idx === this.vadGear) {
                      return;
                    }
                    // 【2026-10-07】选中态过渡：底色 + 字色一起 150ms 渐变。
                    //
                    // 原先设想的是「水滴脱离—融合」的 gooey 效果，最终**没做**，原因是：
                    //   ArkUI 没有 `filter:url()` / `contrast()`，Web 上一句 CSS 是 GPU 免费后处理，
                    //   翻译成原生只剩 Canvas 逐帧自绘 metaball 一条路（60~100 行 + 每次点击逐帧重绘），
                    //   而收益只是三枚胶囊上的一点拉丝，代价与收益不成比例。
                    //   真要做必须先满足「融合层内只能放不透明实色」这条铁律，否则 alpha
                    //   会被阈值吃干净、根本不会融合（Web 版就是这么翻车的：水洼从头到尾隐形）。
                    //
                    // 曲线与底栏选中态统一用 `Motion.curveStandard`，两处是同一套视觉语言。
                    animateTo({ duration: 150, curve: Motion.curveStandard }, () => {
                      this.vadGear = idx;
                    });
                    this.asrDirty = true;
                  });
              }, (opt: string) => `vg-${opt}`);
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.End);
          }
          .width('100%')
          .constraintSize({ minHeight: Size.listSingleWithIcon });

          Row() {
            Text('静音判句').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
            Text(`${this.vadSilMs} ms`)
              .fontSize(FontSize.bodyM)
              .fontColor(Theme.sysTextSub())
              .margin({ right: Space.m });
            this.stepBtn('－', () => {
              const n = this.vadSilMs - 50;
              this.vadSilMs = n < 200 ? 200 : n;
              this.asrDirty = true;
            });
            Row().width(Space.s);
            this.stepBtn('＋', () => {
              const n = this.vadSilMs + 50;
              this.vadSilMs = n > 1000 ? 1000 : n;
              this.asrDirty = true;
            });
          }
          .width('100%')
          .constraintSize({ minHeight: Size.listDoubleWithIcon });

          Row() {
            Text('最短段长').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
            Text(`${this.vadMinSegMs} ms`)
              .fontSize(FontSize.bodyM)
              .fontColor(Theme.sysTextSub())
              .margin({ right: Space.m });
            this.stepBtn('－', () => {
              const n = this.vadMinSegMs - 100;
              this.vadMinSegMs = n < 400 ? 400 : n;
              this.asrDirty = true;
            });
            Row().width(Space.s);
            this.stepBtn('＋', () => {
              const n = this.vadMinSegMs + 100;
              this.vadMinSegMs = n > 2000 ? 2000 : n;
              this.asrDirty = true;
            });
          }
          .width('100%')
          .constraintSize({ minHeight: Size.listDoubleWithIcon });

          // 只恢复「切分灵敏度」这一组（不动上面的兜底切段上限）——
          // 按钮就贴在这一组正下方，位置本身限定了作用范围。
          Row() {
            Button('恢复默认', { type: ButtonType.Capsule, stateEffect: true })
              .controlSize(ControlSize.SMALL)
              .role(ButtonRole.NORMAL)
              .fontColor(Theme.sysEmphasize())
              .backgroundColor(Theme.sysFill())
              .systemMaterial(Mat.tile())
              .onClick(() => {
                this.vadGear = gearOfRms(AppState.VAD_MIN_RMS_DEFAULT);
                this.vadSilMs = AppState.VAD_SIL_MS_DEFAULT;
                this.vadMinSegMs = AppState.VAD_MIN_SEG_MS_DEFAULT;
                this.asrDirty = true;
              });
          }
          .width('100%')
          .justifyContent(FlexAlign.End)
          .margin({ top: Space.s });

          Text('说明：OpenAI 兼容的语音识别接口是一次性上传整段音频，没有流式返回。'
            + '所以这里按「说完一句、停顿一下」切段 —— 通常 1~3 秒出字，'
            + '而且不会把一句话从中间切断；上面的「兜底切段上限」只在连续说不停时才强制切一刀。'
            + '「说话声识别」调高更抗噪（背景吵时用），调低更灵敏（轻声说话时用）；'
            + '「静音判句」是你停顿多久算一句说完，「最短段长」防止切得太碎。')
            .fontSize(FontSize.bodyS)
            .fontColor(Theme.sysTextSub())
            .width('100%')
            .lineHeight(FontSize.bodyS * 1.4)
            .margin({ top: Space.xs });
        }
      }
      .width('100%')
      .padding(Space.l)
      .margin({ top: Space.none })
      .borderRadius(Radius.l)
      .backgroundColor(Theme.sysCard())
      .alignItems(HorizontalAlign.Start);

      // ---- 科目词库 ----
      this.secTitle('科目词库（提升识别准确率）');
      Column() {
        Row() {
          Text(this.subjectLabel)
            .fontSize(FontSize.subtitleM)
            .fontColor(this.tacc)
            .layoutWeight(1);
          Text(this.subjectPickerShow ? '▲' : '▼')
            .fontSize(FontSize.bodyS)
            .fontColor(Theme.sysTextSub());
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingle })
        .padding(Space.m)
        .borderRadius(Radius.m)
        .backgroundColor(Theme.sysFill())
        .systemMaterial(Mat.tile())
        .onClick(() => {
          this.subjectPickerShow = !this.subjectPickerShow;
        });

        if (this.subjectPickerShow) {
          Column() {
            ForEach(SubjectLexicon.choiceKeys(), (k: string) => {
              Row() {
                Text(SubjectLexicon.labelOfChoice(k))
                  .fontSize(FontSize.subtitleM)
                  .fontColor(k === this.subjectKey ? this.tacc : Theme.sysTextMain())
                  .layoutWeight(1);
                if (k === this.subjectKey) {
                  Text('●').fontSize(FontSize.bodyS).fontColor(this.tacc);
                }
              }
              .width('100%')
              .constraintSize({ minHeight: Size.listSingle })
              .padding({ left: Space.m, right: Space.m, top: Space.s, bottom: Space.s })
              .borderRadius(Radius.s)
              .backgroundColor(k === this.subjectKey ? Theme.tintColor(0.88) : Theme.sysFill())
              .systemMaterial(Mat.tile())
              // 【2026-09-28 用户反馈「这几个块都连在一起」】
              // 原实现：选项之间**没有任何间距**，只有 Radius.s 圆角紧贴圆角
              // → 视觉上是一整块连体色块，读不出"这是 5 个可选项"。
              // 修法：每项留出 Space.xsPlus 的下间距（最后一个不留，避免底部多一截空隙）。
              .margin({ bottom: k === SubjectLexicon.choiceKeys()[SubjectLexicon.choiceKeys().length - 1]
                ? Space.none
                : Space.xsPlus })
              .onClick(() => {
                this.subjectKey = k;
                this.subjectPickerShow = false;
                this.asrDirty = true;
                this.refreshSubject();
              });
            }, (k: string) => k);
          }
          .width('100%')
          .margin({ top: Space.s })
          .padding(Space.s)
          // 外层容器加深一档：让"选项块之间的缝"和"容器底"拉开对比，
          // 缝隙才看得出来（原来缝里透出的是同色，等于没缝）。
          .borderRadius(Radius.m)
          .backgroundColor(Theme.sysFill());
        }

        Text(this.subjectHint)
          .fontSize(FontSize.bodyS)
          .fontColor(Theme.sysTextSub())
          .width('100%')
          .lineHeight(FontSize.bodyS * 1.4)
          .margin({ top: Space.xsPlus });
      }
      .width('100%')
      .padding(Space.l)
      .margin({ top: Space.none })
      .borderRadius(Radius.l)
      .backgroundColor(Theme.sysCard())
      .alignItems(HorizontalAlign.Start);

      // ---- 大语言模型 ----
      this.secTitle('大语言模型（答题与笔记整理，api_key 只在本机）');
      Column() {
        this.field('base_url（如 https://api.langlangy.cn）', this.llmBaseUrl, false, (v: string) => {
          this.llmBaseUrl = v;
          this.asrDirty = true;
          this.updateLlmBaseHint();
        });
        Text(this.llmBaseHint)
          .fontSize(FontSize.bodyS)
          .fontColor(this.llmBaseHint.startsWith('⚠') ? Theme.warn() : Theme.success())
          .width('100%')
          .lineHeight(FontSize.bodyS * 1.4)
          .margin({ top: Space.xs });
        this.field('模型名（如 gpt-5.6-luna-free）', this.llmModel, false, (v: string) => {
          this.llmModel = v;
          this.asrDirty = true;
        });
        this.field('api_key（只存本机）', this.llmApiKey, true, (v: string) => {
          this.llmApiKey = v;
          this.asrDirty = true;
        });
      }
      .width('100%')
      .padding(Space.l)
      .margin({ top: Space.none })
      .borderRadius(Radius.l)
      .backgroundColor(Theme.sysCard())
      .alignItems(HorizontalAlign.Start);

      if (this.asrDirty || this.asrSaved) {
        Row() {
          if (this.asrSaved) {
            Text('已保存，下次开始听课生效')
              .fontSize(FontSize.bodyS)
              .fontColor(Theme.success())
              .layoutWeight(1);
          } else {
            Text('有未保存的改动')
              .fontSize(FontSize.bodyS)
              .fontColor(Theme.warn())
              .layoutWeight(1);
          }
          Text('保存')
            .fontSize(FontSize.subtitleS)
            .fontWeight(Weight.medium)
            .fontColor(Theme.onEmphasize())
            .textAlign(TextAlign.Center)
            .padding({ left: Space.xxl, right: Space.xxl, top: Space.xs, bottom: Space.xs })
            .borderRadius(Radius.full)
            .backgroundColor(Theme.sysEmphasize())
            .systemMaterial(Mat.button())
            .onClick(() => {
              this.saveAsr();
              this.saveLlm();
              promptAction.showToast({ message: '已保存', duration: 1600 });
            });
        }
        .width('100%')
        .margin({ top: Space.l })
        .alignItems(VerticalAlign.Center);
      }
    }
    .width('100%');
    // 左右边距已由 build() 的居中容器统一给（screenMargin + contentMaxWidth），
    // 这里不再重复加 padding —— 否则平板下会变成 32(容器) + 32(自身) = 64。
  }

  // ================= 二、课表设置 =================

  @Builder
  scheduleSection() {
    Column() {
      // ===== 课表名称 =====
      Column() {
        Text('课表名称')
          .fontSize(FontSize.bodyS)
          .fontColor(Theme.sysTextSub())
          .width('100%')
          .margin({ bottom: Space.s });
        TextInput({ text: this.name, placeholder: '例如：石家庄铁道大学' })
          .fontSize(FontSize.subtitleM)
          .height(Size.touchTarget)
          .width('100%')
          .fontColor(Theme.sysTextMain())
          .placeholderColor(Theme.sysTextWeak())
          .backgroundColor(Theme.sysFill())
          .borderRadius(Radius.m)
          .onChange((v: string) => {
            this.name = v;
          })
          .onSubmit(() => {
            this.push();
          })
          .onBlur(() => {
            this.push();
          });
      }
      .width('100%')
      .padding(Space.l)
      .margin({ top: Space.m })
      .borderRadius(Radius.l)
      .backgroundColor(Theme.sysCard())
      .alignItems(HorizontalAlign.Start);

      // ===== 课表数据 =====
      // 一级标题：课表设置大区的首标题（16vp / Bold / 主题色）
      this.secTitle('课表数据', 1);
      Column() {
        Row() {
          Text('开学时间').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
          Text(this.openDate.length > 0 ? this.openDate : '点击选择')
            .fontSize(FontSize.subtitleM)
            .fontColor(this.openDate.length > 0 ? this.tc : Theme.sysTextWeak());
          Text('\u203A').fontSize(FontSize.subtitleL).fontColor(Theme.hairline()).margin({ left: Space.xs });
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon })
        .onClick(() => {
          this.openDatePick();
        });

        this.listSeparator();

        Row() {
          Text('开课日星期').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
          Text(this.openWeekdayText).fontSize(FontSize.subtitleM).fontColor(Theme.sysTextSub());
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon });

        this.listSeparator();

        Row() {
          Text('第一列').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain());
          Row() {
            ForEach(FIRST_COL_TEXT, (opt: string, idx: number) => {
              Text(opt)
                .fontSize(FontSize.subtitleS)
                .fontColor(FIRST_COL_VALUES[idx] === this.firstColMode ? Theme.onEmphasize() : Theme.sysFillInk())
                .textAlign(TextAlign.Center)
                .padding({ left: Space.m, right: Space.m, top: Space.xs, bottom: Space.xs })
                .margin({ left: idx === 0 ? Space.none : Space.xsPlus })
                .borderRadius(Radius.full)
                .backgroundColor(FIRST_COL_VALUES[idx] === this.firstColMode ? Theme.sysEmphasize() : Theme.sysFill())
                .onClick(() => {
                  this.firstColMode = FIRST_COL_VALUES[idx];
                  this.push();
                });
            }, (opt: string) => `fc-${opt}`);
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.End);
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon });

        Row() {
          Text('当前周').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
          Text(this.weekLabel())
            .fontSize(FontSize.subtitleM)
            .fontColor(this.tc)
            .fontWeight(Weight.medium);
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon });

        Row() {
          Text('手动指定周次').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
          Text(this.weekOverride === 0 ? '自动' : `${this.weekOverride} 周`)
            .fontSize(FontSize.subtitleM)
            .fontColor(Theme.sysTextSub())
            .margin({ right: Space.m });
          this.stepBtn('－', () => {
            const n = this.weekOverride - 1;
            this.weekOverride = n < 0 ? 0 : n;
            this.push();
          });
          Row().width(Space.s);
          this.stepBtn('＋', () => {
            const n = this.weekOverride + 1;
            this.weekOverride = n > 30 ? 30 : n;
            this.push();
          });
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon });

        this.listSeparator();

        Row() {
          Text('学期周数').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
          Text(`${this.totalWeeks} 周`)
            .fontSize(FontSize.subtitleM)
            .fontColor(Theme.sysTextSub())
            .margin({ right: Space.m });
          this.stepBtn('－', () => {
            const n = this.totalWeeks - 1;
            this.totalWeeks = n < 1 ? 1 : n;
            this.push();
          });
          Row().width(Space.s);
          this.stepBtn('＋', () => {
            const n = this.totalWeeks + 1;
            this.totalWeeks = n > 30 ? 30 : n;
            this.push();
          });
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon });

        this.listSeparator();

        Row() {
          Text('一天课程节数').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
          Text(`${this.sectionsToShow} 节`)
            .fontSize(FontSize.subtitleM)
            .fontColor(Theme.sysTextSub())
            .margin({ right: Space.m });
          this.stepBtn('－', () => {
            const n = this.sectionsToShow - 1;
            this.sectionsToShow = n < 4 ? 4 : n;
            this.push();
          });
          Row().width(Space.s);
          this.stepBtn('＋', () => {
            const n = this.sectionsToShow + 1;
            this.sectionsToShow = n > Sections.TOTAL ? Sections.TOTAL : n;
            this.push();
          });
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon });

        this.listSeparator();

        Row() {
          Text('上课时间').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
          Text(this.showTimes ? '收起' : '查看').fontSize(FontSize.subtitleM).fontColor(Theme.sysEmphasize());
          Text('\u203A').fontSize(FontSize.subtitleL).fontColor(Theme.hairline()).margin({ left: Space.xs });
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon })
        .onClick(() => {
          this.showTimes = !this.showTimes;
        });

        if (this.showTimes) {
          Column() {
            ForEach(Sections.SLOTS, (s: SectionSlot) => {
              Row() {
                Text(`${s.period} · 第 ${s.no} 节`)
                  .fontSize(FontSize.bodyM)
                  .fontColor(Theme.sysTextMain())
                  .layoutWeight(1);
                Text(`${s.start} - ${s.end}`).fontSize(FontSize.bodyM).fontColor(Theme.sysTextSub());
              }
              .width('100%')
              .constraintSize({ minHeight: Size.touchTarget });
            }, (s: SectionSlot) => `t-${s.no}`);
          }
          .width('100%')
          .padding({ bottom: Space.s });
        }
      }
      .width('100%')
      .padding(Space.l)
      .margin({ top: Space.none })
      .borderRadius(Radius.l)
      .backgroundColor(Theme.sysCard())
      .alignItems(HorizontalAlign.Start);

      // ===== 课表外观 =====
      this.secTitle('课表外观');
      Column() {
        this.switchLine('显示周六', this.showSaturday, (v: boolean) => {
          this.showSaturday = v;
          this.push();
        });
        this.listSeparator();
        this.switchLine('显示周日', this.showSunday, (v: boolean) => {
          this.showSunday = v;
          this.push();
        });
        this.listSeparator();
        this.switchLine('显示非本周课程', this.showNonCurrentWeek, (v: boolean) => {
          this.showNonCurrentWeek = v;
          this.push();
        });
        this.listSeparator();
        this.switchLine('显示教师', this.showTeacher, (v: boolean) => {
          this.showTeacher = v;
          this.push();
        });
        this.listSeparator();
        this.switchLine('显示地点', this.showLocation, (v: boolean) => {
          this.showLocation = v;
          this.push();
        });
        this.listSeparator();
        this.switchLine('参考线', this.showGrid, (v: boolean) => {
          this.showGrid = v;
          this.push();
        });

        this.listSeparator();

        Row() {
          Text('格子形状').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain());
          Row() {
            ForEach(SHAPES, (opt: string, idx: number) => {
              Text(opt)
                .fontSize(FontSize.subtitleS)
                .fontColor(SHAPE_VALUES[idx] === this.shape ? Theme.onEmphasize() : Theme.sysFillInk())
                .textAlign(TextAlign.Center)
                .padding({ left: Space.m, right: Space.m, top: Space.xs, bottom: Space.xs })
                .margin({ left: idx === 0 ? Space.none : Space.xsPlus })
                .borderRadius(Radius.full)
                .backgroundColor(SHAPE_VALUES[idx] === this.shape ? Theme.sysEmphasize() : Theme.sysFill())
                .onClick(() => {
                  this.shape = SHAPE_VALUES[idx];
                  this.push();
                });
            }, (opt: string) => `sh-${opt}`);
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.End);
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon });

        this.listSeparator();

        Row() {
          Text('课程格子高度').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
          Text(`${this.cellHeight} dp`)
            .fontSize(FontSize.subtitleM)
            .fontColor(Theme.sysTextSub())
            .margin({ right: Space.m });
          this.stepBtn('－', () => {
            const n = this.cellHeight - 4;
            this.cellHeight = n < 44 ? 44 : n;
            this.push();
          });
          Row().width(Space.s);
          this.stepBtn('＋', () => {
            const n = this.cellHeight + 4;
            this.cellHeight = n > 100 ? 100 : n;
            this.push();
          });
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon });

        this.listSeparator();

        Row() {
          Text('每天列宽').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
          Text(this.colWidth <= 0 ? '自适应' : `${this.colWidth} dp`)
            .fontSize(FontSize.subtitleM)
            .fontColor(Theme.sysTextSub())
            .margin({ right: Space.m });
          this.stepBtn('－', () => {
            const n = this.colWidth <= 66 ? 0 : this.colWidth - 6;
            this.colWidth = n;
            this.push();
          });
          Row().width(Space.s);
          this.stepBtn('＋', () => {
            const n = this.colWidth <= 0 ? 66 : (this.colWidth + 6 > 150 ? 150 : this.colWidth + 6);
            this.colWidth = n;
            this.push();
          });
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon });

        Text('格子文字一律居中；下面选的是各元素在格子里的上下顺序')
          .fontSize(FontSize.bodyS)
          .fontColor(Theme.sysTextSub())
          .width('100%')
          .padding({ top: Space.m });
        this.slotSetting('课程名位置', 'name');
        this.slotSetting('教室位置', 'location');
        this.slotSetting('教师位置', 'teacher');

        Row() {
          Text('格子圆角半径').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
          Text(`${this.cornerRadius} dp`)
            .fontSize(FontSize.subtitleM)
            .fontColor(Theme.sysTextSub())
            .margin({ right: Space.m });
          this.stepBtn('－', () => {
            const n = this.cornerRadius - 2;
            this.cornerRadius = n < 0 ? 0 : n;
            this.push();
          });
          Row().width(Space.s);
          this.stepBtn('＋', () => {
            const n = this.cornerRadius + 2;
            this.cornerRadius = n > 28 ? 28 : n;
            this.push();
          });
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon });
      }
      .width('100%')
      .padding(Space.l)
      .margin({ top: Space.none })
      .borderRadius(Radius.l)
      .backgroundColor(Theme.sysCard())
      .alignItems(HorizontalAlign.Start);

      // ===== 更多外观 =====
      this.secTitle('更多外观');
      Column() {
        // 【2026-09-28 移除】原「背景色」一行已搬到「配色」页 ——
        // 用户要求「切换背景色的功能移到配色里面去」；语义上背景色属于配色而非布局。
        // 新的入口：设置 → 配色 → 课表背景色（`Theme.scheduleBg`，空值跟随色系）。

        Row() {
          Text('文字大小').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
          Text(`${this.textScale}%`)
            .fontSize(FontSize.subtitleM)
            .fontColor(Theme.sysTextSub())
            .margin({ right: Space.m });
          this.stepBtn('－', () => {
            const n = this.textScale - 5;
            this.textScale = n < 85 ? 85 : n;
            this.push();
          });
          Row().width(Space.s);
          this.stepBtn('＋', () => {
            const n = this.textScale + 5;
            this.textScale = n > 140 ? 140 : n;
            this.push();
          });
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon });

        this.listSeparator();

        Row() {
          Text('课程块不透明度').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
          Text(`${this.blockOpacity}%`)
            .fontSize(FontSize.subtitleM)
            .fontColor(Theme.sysTextSub())
            .margin({ right: Space.m });
          this.stepBtn('－', () => {
            const n = this.blockOpacity - 5;
            this.blockOpacity = n < 50 ? 50 : n;
            this.push();
          });
          Row().width(Space.s);
          this.stepBtn('＋', () => {
            const n = this.blockOpacity + 5;
            this.blockOpacity = n > 100 ? 100 : n;
            this.push();
          });
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon });
      }
      .width('100%')
      .padding(Space.l)
      .margin({ top: Space.none })
      .borderRadius(Radius.l)
      .backgroundColor(Theme.sysCard())
      .alignItems(HorizontalAlign.Start);

      // ===== 上课提醒 =====
      this.secTitle('上课提醒');
      Column() {
        // 【2026-10-07 接入 ill_class_reminder】这一区原先全是「标签 + 数值 + 步进键」的
        // 文字行，扫视时找不到锚点。闹钟插画放在区段顶部当视觉锚，
        // 尺寸与「状态插画」同档（statusIll），不喧宾夺主。
        Row() {
          Image($r('app.media.ill_class_reminder'))
            .width(Size.statusIll)
            .height(Size.statusIll)
            .objectFit(ImageFit.Contain)
            .margin({ right: Space.m })
          Text('到点前提醒你，别错过下一节课')
            .fontSize(FontSize.bodyS)
            .fontColor(Theme.sysTextSub())
            .layoutWeight(1)
            .lineHeight(FontSize.bodyS * 1.4)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ bottom: Space.m });

        this.switchLine('上课前提醒', this.reminderEnabled, (v: boolean) => {
          this.reminderEnabled = v;
          this.push();
        });

        this.listSeparator();

        Row() {
          Text('提前提醒时间').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
          Text(`${this.leadMinutes} 分钟`)
            .fontSize(FontSize.subtitleM)
            .fontColor(Theme.sysTextSub())
            .margin({ right: Space.m });
          this.stepBtn('－', () => {
            const n = this.leadMinutes - 5;
            this.leadMinutes = n < 5 ? 5 : n;
            this.push();
          });
          Row().width(Space.s);
          this.stepBtn('＋', () => {
            const n = this.leadMinutes + 5;
            this.leadMinutes = n > 60 ? 60 : n;
            this.push();
          });
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon });

        this.listSeparator();

        Row() {
          Text('系统提醒能力').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
          Text(ClassReminder.systemAvailable
            ? '已开通'
            : (ClassReminder.lastErrorCode !== 0 ? `未开通（${ClassReminder.lastErrorCode}）` : '待检测'))
            .fontSize(FontSize.bodyM)
            .fontColor(ClassReminder.systemAvailable ? Theme.success() : Theme.sysTextSub());
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon });

        Text('提醒由系统代理发送（代理提醒），应用退到后台或被关闭也能准点提醒。'
          + '需在 AGC「项目设置 → 开放能力管理」申请「代理提醒」开放能力（官方允许场景含「课程提醒」），'
          + '通过后勾选能力开关并重新生成 Profile；未开通时会退回到"应用在前台/存活时的本地通知"。'
          + '停课日不提醒。')
          .fontSize(FontSize.bodyS)
          .fontColor(Theme.sysTextSub())
          .width('100%')
          .lineHeight(FontSize.bodyS * 1.4)
          .padding({ top: Space.xs, bottom: Space.l });
      }
      .width('100%')
      .padding(Space.l)
      .margin({ top: Space.none })
      .borderRadius(Radius.l)
      .backgroundColor(Theme.sysCard())
      .alignItems(HorizontalAlign.Start);

      // ===== 导出与分享 =====
      this.secTitle('导出与分享');
      Column() {
        Row() {
          Text('碰一碰分享课表').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
          Text(this.shareOn ? '已就绪' : '不可用')
            .fontSize(FontSize.bodyM)
            .fontColor(this.shareOn ? this.tc : Theme.sysTextSub());
          Text('\u203A').fontSize(FontSize.subtitleL).fontColor(Theme.hairline()).margin({ left: Space.xs });
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon })
        .onClick(() => {
          this.pokeShare();
        });

        if (this.shareStatus.length > 0) {
          Text(this.shareStatus)
            .fontSize(FontSize.bodyS)
            .fontColor(Theme.sysTextSub())
            .width('100%')
            .lineHeight(FontSize.bodyS * 1.4)
            .padding({ top: Space.xs, bottom: Space.s });
        }

        Text('两台鸿蒙设备顶部碰一碰，即可把整份课表（含学期设置）发给对方。'
          + '对方在知课笺里确认后即可导入，不需要联网。转写笔记页也能碰一碰发单份笔记。')
          .fontSize(FontSize.bodyS)
          .fontColor(Theme.sysTextSub())
          .width('100%')
          .lineHeight(FontSize.bodyS * 1.4)
          .padding({ top: Space.xs, bottom: Space.m });

        this.listSeparator();

        Row() {
          Text('导出为图片（PNG）').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
          Text('\u203A').fontSize(FontSize.subtitleL).fontColor(Theme.hairline());
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon })
        .onClick(() => {
          this.exportSchedule('png');
        });

        this.listSeparator();

        Row() {
          Text('导出为日历（.ics，可导入系统日历）')
            .fontSize(FontSize.subtitleM)
            .fontColor(Theme.sysTextMain())
            .layoutWeight(1);
          Text('\u203A').fontSize(FontSize.subtitleL).fontColor(Theme.hairline());
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon })
        .onClick(() => {
          this.exportSchedule('ics');
        });

        this.listSeparator();

        Row() {
          Text('导出为 JSON（可备份/迁移）').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
          Text('\u203A').fontSize(FontSize.subtitleL).fontColor(Theme.hairline());
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon })
        .onClick(() => {
          this.exportSchedule('json');
        });

        this.listSeparator();

        Row() {
          Text('导出为表格（.csv）').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
          Text('\u203A').fontSize(FontSize.subtitleL).fontColor(Theme.hairline());
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon })
        .onClick(() => {
          this.exportSchedule('csv');
        });
      }
      .width('100%')
      .padding(Space.l)
      .margin({ top: Space.none })
      .borderRadius(Radius.l)
      .backgroundColor(Theme.sysCard())
      .alignItems(HorizontalAlign.Start);

      // ===== 管理 =====
      this.secTitle('管理');
      Column() {
        Row() {
          Text('配色（主题 / 课表 / 字色）').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
          // 主题色小色块：纯装饰非文本容器，保留固定尺寸
          Column()
            .width(Size.iconL)
            .height(Size.iconL)
            .borderRadius(Radius.s)
            .backgroundColor(Theme.cfg.theme)
            .border({ width: 1, color: '#00000022' });
          Text('\u203A').fontSize(FontSize.subtitleL).fontColor(Theme.hairline()).margin({ left: Space.xsPlus });
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon })
        .onClick(() => {
          router.pushUrl({ url: 'pages/ThemeSettings' });
        });

        this.listSeparator();

        Row() {
          Text('管理已添加课程').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
          Text(`${CourseStore.courses.length} 个课程块`).fontSize(FontSize.bodyM).fontColor(Theme.sysTextSub());
          Text('\u203A').fontSize(FontSize.subtitleL).fontColor(Theme.hairline()).margin({ left: Space.xs });
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon })
        .onClick(() => {
          router.pushUrl({ url: 'pages/CourseEdit' });
        });

        this.listSeparator();

        Row() {
          Text('节假日（停课日）').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
          Text(`${this.holidays.length} 天`).fontSize(FontSize.bodyM).fontColor(Theme.sysTextSub());
          Text('\u203A').fontSize(FontSize.subtitleL).fontColor(Theme.hairline()).margin({ left: Space.xs });
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon })
        .onClick(() => {
          this.showHoliday = true;
        });

        this.listSeparator();

        Row() {
          Text('重新从教务导入').fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
          Text('\u203A').fontSize(FontSize.subtitleL).fontColor(Theme.hairline());
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon })
        .onClick(() => {
          router.pushUrl({ url: 'pages/ImportSchedule' });
        });

        this.listSeparator();

        // 【2026-09-28 删除】原「实况窗 · 不适用」一栏 + 说明段已移除。
        // 原因：用户要求「实况窗无法使用就删除不要渲染」——该能力已被官方驳回
        // （场景不在开放范围内），设置页里留一个不能用的条目只会误导使用者。
        // 上课提醒仍由系统「代理提醒」（ClassReminder）承担，不受影响。

        Row() {
          Text('清空课表').fontSize(FontSize.subtitleM).fontColor(Theme.danger()).layoutWeight(1);
          Text(`${CourseStore.courses.length} 个课程块`).fontSize(FontSize.bodyM).fontColor(Theme.sysTextSub());
        }
        .width('100%')
        .constraintSize({ minHeight: Size.listSingleWithIcon })
        .onClick(() => {
          this.confirmClear();
        });
      }
      .width('100%')
      .padding(Space.l)
      .margin({ top: Space.none })
      .borderRadius(Radius.l)
      .backgroundColor(Theme.sysCard())
      .alignItems(HorizontalAlign.Start);

      Text('课表改动即时保存，返回课表页即可看到效果。')
        .fontSize(FontSize.bodyS)
        .fontColor(Theme.sysTextSub())
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: Space.xxl, bottom: Space.xxl });
    }
    .width('100%');
    // 左右边距同上，已由 build() 的居中容器统一给，此处不重复。
  }

  // ================= 共用小组件 =================

  /** 开关行（只传静态标签） */
  @Builder
  switchLine(label: string, on: boolean, tap: (v: boolean) => void) {
    Row() {
      Text(label).fontSize(FontSize.subtitleM).fontColor(Theme.sysTextMain()).layoutWeight(1);
      Toggle({ type: ToggleType.Switch, isOn: on })
        .selectedColor(Theme.sysEmphasize())
        .systemMaterial(Mat.tile())
        .onChange((v: boolean) => {
          tap(v);
        });
    }
    .width('100%')
    .constraintSize({ minHeight: Size.listSingleWithIcon });
  }

  /** 输入框（统一外观；password=true 走密码键盘遮蔽） */
  @Builder
  field(ph: string, value: string, password: boolean, tap: (v: string) => void) {
    TextInput({ placeholder: ph, text: value })
      .type(password ? InputType.Password : InputType.Normal)
      .fontSize(FontSize.subtitleM)
      .fontColor(Theme.sysTextMain())
      .placeholderColor(Theme.sysTextWeak())
      .backgroundColor(Theme.sysFill())
      .borderRadius(Radius.m)
      .height(Size.touchTarget)
      .width('100%')
      .margin({ top: Space.s })
      .onChange((v: string) => {
        tap(v);
      });
  }

  // ================= 弹层 =================

  /** 节假日（停课日）面板 */
  @Builder
  holidayPanel() {
    Column() {
      Column() {
        Row() {
          Text('节假日（停课日）')
            .fontSize(FontSize.subtitleM)
            .fontWeight(Weight.bold)
            .fontColor(Theme.sysTextMain())
            .layoutWeight(1);
          Text('关闭')
            .fontSize(FontSize.subtitleS)
            .fontColor(Theme.sysTextSub())
            .constraintSize({ minHeight: Size.touchTarget, minWidth: Size.touchTarget })
            .textAlign(TextAlign.End)
            .onClick(() => {
              this.showHoliday = false;
            });
        }
        .width('100%')
        .constraintSize({ minHeight: Size.touchTarget });

        Text('添加后，那一天整列不排课，上课提醒也会跳过。')
          .fontSize(FontSize.bodyS)
          .fontColor(Theme.sysTextSub())
          .width('100%')
          .lineHeight(FontSize.bodyS * 1.4)
          .margin({ top: Space.xsPlus });

        if (this.holidays.length === 0) {
          Text('还没有停课日。')
            .fontSize(FontSize.bodyM)
            .fontColor(Theme.sysTextSub())
            .width('100%')
            .padding({ top: Space.l, bottom: Space.l });
        } else {
          // 滚动视口：保留固定高度
          Scroll() {
            Column() {
              ForEach(this.holidays, (d: string) => {
                Row() {
                  Text(d)
                    .fontSize(FontSize.subtitleM)
                    .fontColor(Theme.sysTextMain())
                    .layoutWeight(1);
                  Text('删除')
                    .fontSize(FontSize.bodyM)
                    .fontColor(Theme.danger())
                    .constraintSize({ minHeight: Size.touchTarget, minWidth: Size.touchTarget })
                    .textAlign(TextAlign.End)
                    .onClick(() => {
                      CourseStore.removeHoliday(d).then(() => {
                        this.holidays = CourseStore.semester.holidays.slice();
                      });
                    });
                }
                .width('100%')
                .constraintSize({ minHeight: Size.listSingle })
                .alignItems(VerticalAlign.Center);
              }, (d: string) => `hd-${d}`);
            }
            .width('100%');
          }
          .height(210)
          .width('100%')
          .margin({ top: Space.s })
          .scrollBar(BarState.Off);
        }

        Row() {
          Text('添加停课日')
            .fontSize(FontSize.subtitleS)
            .fontWeight(Weight.medium)
            .fontColor(Theme.onEmphasize())
            .padding({ left: Space.xxl, right: Space.xxl, top: Space.xs, bottom: Space.xs })
            .borderRadius(Radius.full)
            .backgroundColor(Theme.sysEmphasize())
            .systemMaterial(Mat.button())
            .onClick(() => {
              this.pickForHoliday = true;
              this.openDatePick();
            });
        }
        .width('100%')
        .margin({ top: Space.l })
        .justifyContent(FlexAlign.Center);
      }
      .width('88%')
      .padding(Space.xl)
      .borderRadius(Radius.xl)
      .backgroundColor(Theme.sysCard())
      .systemMaterial(Mat.sheet());
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#00000055')
    .transition(Motion.fadeIn());
  }

  /** 日期选择层：自己画，不依赖系统弹窗 */
  @Builder
  datePickPanel() {
    Column() {
      Column() {
        Text(this.pickForHoliday ? '添加停课日' : '开学时间（第一周第一天）')
          .fontSize(FontSize.subtitleM)
          .fontWeight(Weight.bold)
          .fontColor(Theme.sysTextMain());
        Text(`${this.pickY} 年 ${this.pickM} 月 ${this.pickD} 日`)
          .fontSize(FontSize.titleM)
          .fontWeight(Weight.bold)
          .fontColor(this.tc)
          .margin({ top: Space.m });
        Text(this.pickPreview())
          .fontSize(FontSize.bodyS)
          .fontColor(Theme.sysTextSub())
          .margin({ top: Space.xsPlus });

        Row() {
          Text('年').fontSize(FontSize.bodyM).fontColor(Theme.sysTextSub()).width(28);
          this.stepBtn('－', () => {
            this.pickY -= 1;
          });
          Text(`${this.pickY}`)
            .fontSize(FontSize.subtitleM)
            .fontColor(Theme.sysTextMain())
            .width(80)
            .textAlign(TextAlign.Center);
          this.stepBtn('＋', () => {
            this.pickY += 1;
          });
        }
        .width('100%')
        .constraintSize({ minHeight: Size.touchTarget })
        .margin({ top: Space.m })
        .justifyContent(FlexAlign.Center);

        Row() {
          Text('月').fontSize(FontSize.bodyM).fontColor(Theme.sysTextSub()).width(28);
          this.stepBtn('－', () => {
            const n = this.pickM - 1;
            this.pickM = n < 1 ? 12 : n;
          });
          Text(`${this.pickM}`)
            .fontSize(FontSize.subtitleM)
            .fontColor(Theme.sysTextMain())
            .width(80)
            .textAlign(TextAlign.Center);
          this.stepBtn('＋', () => {
            const n = this.pickM + 1;
            this.pickM = n > 12 ? 1 : n;
          });
        }
        .width('100%')
        .constraintSize({ minHeight: Size.touchTarget })
        .justifyContent(FlexAlign.Center);

        Row() {
          Text('日').fontSize(FontSize.bodyM).fontColor(Theme.sysTextSub()).width(28);
          this.stepBtn('－', () => {
            const n = this.pickD - 1;
            this.pickD = n < 1 ? 31 : n;
          });
          Text(`${this.pickD}`)
            .fontSize(FontSize.subtitleM)
            .fontColor(Theme.sysTextMain())
            .width(80)
            .textAlign(TextAlign.Center);
          this.stepBtn('＋', () => {
            const n = this.pickD + 1;
            this.pickD = n > 31 ? 1 : n;
          });
        }
        .width('100%')
        .constraintSize({ minHeight: Size.touchTarget })
        .justifyContent(FlexAlign.Center);

        Row() {
          ForEach(['今天', '本周一', '下周一'], (t: string, idx: number) => {
            Text(t)
              .fontSize(FontSize.subtitleS)
              .fontColor(Theme.sysEmphasize())
              .textAlign(TextAlign.Center)
              .padding({ left: Space.l, right: Space.l, top: Space.xs, bottom: Space.xs })
              .margin({ left: idx === 0 ? Space.none : Space.s })
              .borderRadius(Radius.full)
              .backgroundColor(Theme.sysFill())
              .onClick(() => {
                this.applyQuick(idx);
              });
          }, (t: string) => `q-${t}`);
        }
        .width('100%')
        .margin({ top: Space.l })
        .justifyContent(FlexAlign.Center);

        Row() {
          Text('取消')
            .fontSize(FontSize.subtitleS)
            .fontColor(Theme.sysTextSub())
            .textAlign(TextAlign.Center)
            .padding({ left: Space.xxl, right: Space.xxl, top: Space.xs, bottom: Space.xs })
            .borderRadius(Radius.full)
            .backgroundColor(Theme.sysFill())
            .onClick(() => {
              this.showDatePick = false;
            });
          Text('确定')
            .fontSize(FontSize.subtitleS)
            .fontWeight(Weight.medium)
            .fontColor(Theme.onEmphasize())
            .textAlign(TextAlign.Center)
            .padding({ left: Space.xxl, right: Space.xxl, top: Space.xs, bottom: Space.xs })
            .margin({ left: Space.m })
            .borderRadius(Radius.full)
            .backgroundColor(Theme.sysEmphasize())
            .systemMaterial(Mat.button())
            .opacity(this.pickValid() ? 1 : 0.4)
            .onClick(() => {
              this.applyDate();
            });
        }
        .width('100%')
        .margin({ top: Space.xl })
        .justifyContent(FlexAlign.Center);
      }
      .width('88%')
      .padding(Space.xl)
      .borderRadius(Radius.xl)
      .backgroundColor(Theme.sysCard())
      .systemMaterial(Mat.sheet());
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#00000055')
    .transition(Motion.fadeIn());
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        // ======================================================================
        // 【2026-09-28 第十六次修正 · 「滚不到最上面」的真 bug】
        //
        // ## 用户要求（原话）
        // > 「设置里面的往下滚的那一行菜单页，它要可以滚到最上面去，要可以被这个设置，
        // >   被这个胶囊显示，重建折射出来，不要还没有碰到这个胶囊就触顶了。」
        //
        // ## 病根：`Blank()` 是 `Scroll` 的**兄弟节点**
        // 原结构：
        //   Column() {
        //     Blank().height(barTotalH())   // ← 永久占据视口上方
        //     Scroll() { 内容 }
        //   }
        // `Blank` 把 `Scroll` 的**视口上沿**整体下推到胶囊下沿 ——
        // 于是内容最多只能滚到「胶囊下方」，**永远进不了胶囊区域**，
        // 沉浸材质没有东西可透 → 看起来是块死板（用户说的"触顶"）。
        //
        // ## 正解：让 `Scroll` 视口顶到屏幕最上，避让量改成**内容内的首屏间距**
        // 关键区别：
        //   · 兄弟 `Blank` = 实体，永久占位，视口被推下去（❌ 内容碰不到胶囊）
        //   · 内容内 `Blank` = 只是第一项，**会跟着滚走**（✅ 首屏仍避让，滚动后进胶囊后方）
        // 所以把 `Blank` 从兄弟位置**移进 Scroll 的内容 Column 里**。
        //
        // ⚠️ 两条配套要求：
        //   ① `Scroll` 必须真的够高（`layoutWeight(1)` 在外层 Column 里生效）；
        //   ② 底部 `padding` 仍保留 `barClearanceMin`，否则末项被底栏压住。
        // ======================================================================

        Scroll() {
          Column() {
            // 首屏避让：位置从「Scroll 外面」搬到「内容里面」——这一项会随滚动移出屏幕
            Blank().height(this.barTotalH());

            if (this.sec === 0) {
              this.asrSection();
            } else if (this.sec === 2) {
              // 词典（2026-10-10 新增，第三个分段）
              this.dictSection();
            } else {
              this.scheduleSection();
            }
          }
          .width('100%')
          // ---- 宽屏内容约束（仅平板生效）----
          // 1400vp 屏上卡片若铺满，正文单行会到 1300vp（远超官方 40~70 字符的建议），
          // 且卡片内部信息全挤左半边。约束到 contentMaxWidth() 后居中，左右留呼吸位。
          // ⚠️ 【2026-10-07 修正】同 ListenView —— ArkUI 的 `maxWidth` 没有"不限制"取值，
          //   传 0 等于"上限为零"，会把内容压成竖条。手机端显式给极大值而非 0。
          .constraintSize({ maxWidth: Layout.isTablet() ? Layout.contentMaxWidth() : 100000 })
          // 底部避让悬浮底栏：用 Size.barClearanceMin(= tabBar + floatMargin + 缓冲)。
          // 【2026-09-28 方案B】由 barClearance(100) 收到 barClearanceMin(92)：
          //   沉浸光感是全屏取色的毛玻璃，透出的是胶囊正下方的屏幕内容。留白过大 →
          //   胶囊下方是一段空白 → 材质透出来就是页面底色 → 视觉上"不透"。
          //   收到几何必须的最小值，让内容尽量滚到/进入胶囊后方，材质才有东西可透。
          .padding({ left: Layout.screenMargin(), right: Layout.screenMargin(), bottom: Size.barClearanceMin });
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .width('100%')
        .align(Alignment.Top);
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.sysPage());

      // 顶栏浮层：浮在滚动内容之上，材质才有东西可透（第十二次修正）
      this.barContent();

      if (this.showDatePick) {
        this.datePickPanel();
      }

      if (this.showHoliday) {
        this.holidayPanel();
      }

      if (this.showExportDone) {
        this.exportDonePanel();
      }
    }.transition(Motion.pageEnter())
    .width('100%')
    .height('100%')
    // 【2026-09-28 第十四次修正】外层 Stack 也补底色。
    // 用户反馈「设置里面的容器没铺满全屏，到胶囊下面就终止了」——
    // 原来只有内层 Column 有底色，外层 Stack 是透明的；只要内层因任何原因
    // 没撑到 100%，下方就露出透明区域。给 Stack 兜底最稳。
    .backgroundColor(Theme.sysPage());
  }
}

/**
 * Tab 内嵌用的设置入口。
 *
 * 为什么包装一层：ArkTS 里跨文件**直接 new 一个 struct（`Settings({...})`）不是合法语法**，
 * 只能由本文件内的 @Builder 构造。Main 的第三个 TabContent 调这个函数即可。
 *
 * 注：不带参数的全局 @Builder 才能安全地传给另一个模块使用；带参全局 @Builder
 * 在 ArkUI 里会因"按值传参"不刷新，所以这里固定走 Tab 形态（fromTab=true、默认 sec=0）。
 */
@Builder
export function TabSettingsView() {
  Settings({ fromTab: true, sec: 0 });
}
