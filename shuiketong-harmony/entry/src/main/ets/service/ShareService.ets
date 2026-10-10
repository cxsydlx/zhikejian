import { harmonyShare, systemShare } from '@kit.ShareKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import hilog from '@ohos.hilog';
import { CourseStore, CourseItem, Semester, ImportResult } from '../common/CourseStore';
import { TranscriptStore, TrSession, TrLine } from '../common/TranscriptStore';
import { AppState } from '../common/AppState';
import { AppConst } from '../common/AppConst';

const DOMAIN = 0x0000;

/** 分享内容大类 */
export class ShareKind {
  /** 课表（含学期设置） */
  static readonly SCHEDULE: string = 'schedule';
  /** 单份转写笔记 */
  static readonly TRANSCRIPT: string = 'transcript';
}

/**
 * 课表分享载荷。
 *
 * 设计要点：
 *  · 载荷直接复用 CourseStore 落盘用的两段 JSON（coursesJson / semesterJson），
 *    接收侧反序列化走同一套字段映射，**不做格式转换**，避免两边解析口径漂移。
 *  · 用 `extraData` 承载完整 JSON（该字段官方定位就是"与目标 App/设备共享自定义扩展内容"），
 *    `content` 只放一行人类可读摘要 —— 万一对方没装知课笺、或系统把它当纯文本展示，
 *    至少能看到"知课笺课表 · N 个课程块"，而不是一堆看不懂的 JSON。
 *  · `extraData` 的值类型限定 string|number|boolean|Array<...>，所以 JSON 以字符串塞入。
 */
export class SchedulePayload {
  /** 载荷格式版本，将来改结构时用于兼容判断 */
  version: number = 1;
  /** 课表名称 */
  name: string = '';
  /** 学期名 */
  title: string = '';
  /** 课程块数量（仅用于摘要展示，真值以 coursesJson 解析为准） */
  count: number = 0;
  /** CourseStore.persist() 同款的课程数组 JSON */
  coursesJson: string = '[]';
  /** CourseStore.persist() 同款的学期配置 JSON */
  semesterJson: string = '{}';
}

/** 转写笔记分享载荷（单份） */
export class TranscriptPayload {
  version: number = 1;
  title: string = '';
  startMs: number = 0;
  endMs: number = 0;
  /** 转写句子数 */
  count: number = 0;
  /** LLM 整理出的结构化笔记（可空） */
  summary: string = '';
  /** 原始转写，每行一句 */
  lines: string[] = [];

  /** 时长文案（接收侧弹窗展示用） */
  durationText(): string {
    const end = this.endMs > 0 ? this.endMs : Date.now();
    const m = Math.floor((end - this.startMs) / 60000);
    const mm = m < 0 ? 0 : m;
    return mm >= 60 ? `${Math.floor(mm / 60)} 小时 ${mm % 60} 分` : `${mm} 分钟`;
  }
}

/** 待确认的导入结果（接收侧弹窗用）。 */
export class PendingImport {
  /** schedule | transcript */
  kind: string = ShareKind.SCHEDULE;
  payload: SchedulePayload = new SchedulePayload();
  transcript: TranscriptPayload = new TranscriptPayload();
  /** 解析出的条数（课表=课程块数；转写=句数） */
  parsed: number = 0;
  /** 来源描述 */
  from: string = '';
}

/**
 * 碰一碰（Tap to Transfer）分享服务。
 *
 * 发送链路：harmonyShare.on('knockShare', cb) → cb 给到 SharableTarget → target.share(SharedData)。
 * 接收链路：对端 share 的数据以 want 形式投递到本应用 Ability，
 *          在 EntryAbility.onCreate / onNewWant 里用 systemShare.getSharedData(want) 取回。
 *
 * 幂等性：register/unregister 成对调用；页面进入注册、离开注销，避免重复注册导致一次碰触多次回调。
 *
 * 多内容源：发送前先 `setPendingSource(kind, id)` 声明"这次要发什么"（课表 / 某份转写）。
 * 因为碰一碰的回调不带上下文，只能靠这个预置值决定载荷类型。
 */
export class ShareService {
  /** 载荷识别标记 */
  static readonly MARK_KEY: string = 'zhikejian_share';
  /** 载荷类型值（v2 起用 kind 区分课表/转写） */
  static readonly MARK_VALUE: string = 'v2';
  /** 文本 UTD（超文本统一数据类型），纯文本走这个 */
  static readonly UTD_PLAIN_TEXT: string = 'general.plain-text';

  /** 当前是否已注册碰一碰监听 */
  private static registered: boolean = false;
  /** 保存注册时用的回调引用，注销时要传同一个引用 */
  private static knockCb: Callback<harmonyShare.SharableTarget> | null = null;
  /** 最近一次碰一碰的状态文本（供 UI 展示） */
  static lastStatus: string = '';
  /** 接收到的待确认导入（null = 没有） */
  static pendingImport: PendingImport | null = null;
  /** 待确认数据的变更通知（UI 订阅后弹窗） */
  private static pendingListeners: Array<() => void> = [];

  /** 下一次碰一碰要发什么：schedule | transcript */
  private static pendingKind: string = ShareKind.SCHEDULE;
  /** kind=transcript 时的会话 id */
  private static pendingSessionId: string = '';

  /**
   * 声明下一次碰一碰要发的内容。
   * @param kind schedule | transcript
   * @param sessionId kind=transcript 时必填；课表传 ''
   */
  static setPendingSource(kind: string, sessionId: string = ''): void {
    ShareService.pendingKind = kind;
    ShareService.pendingSessionId = sessionId;
  }

  // ---------- 待确认导入的通知机制 ----------

  static onPendingImport(cb: () => void): void {
    ShareService.pendingListeners.push(cb);
  }

  private static notifyPending(): void {
    for (const cb of ShareService.pendingListeners) {
      cb();
    }
  }

  /** 取走待确认导入（取完即清空，避免重复弹窗） */
  static takePending(): PendingImport | null {
    const p = ShareService.pendingImport;
    ShareService.pendingImport = null;
    return p;
  }

  // ---------- 载荷构造：课表 ----------

  /** 把当前课表打包成分享载荷 */
  static buildPayload(): SchedulePayload {
    const p = new SchedulePayload();
    p.version = 1;
    p.name = CourseStore.semester.name;
    p.title = CourseStore.semester.title;
    p.count = CourseStore.courses.length;
    p.coursesJson = ShareService.encodeCourses();
    p.semesterJson = ShareService.encodeSemester();
    return p;
  }

  /** 课程数组 → JSON（字段与 CourseStore.persist() 完全一致） */
  private static encodeCourses(): string {
    const arr: Array<Record<string, Object>> = [];
    for (const c of CourseStore.courses) {
      const o: Record<string, Object> = {
        'id': c.id,
        'name': c.name,
        'weekday': c.weekday,
        'startSection': c.startSection,
        'endSection': c.endSection,
        'weeks': JSON.stringify(c.weeks),
        'weekText': c.weekText,
        'location': c.location,
        'teacher': c.teacher,
        'campus': c.campus,
        'colorIndex': c.colorIndex,
      };
      arr.push(o);
    }
    return JSON.stringify(arr);
  }

  /** 学期配置 → JSON（字段与 CourseStore.persist() 完全一致） */
  private static encodeSemester(): string {
    const s = CourseStore.semester;
    const so: Record<string, Object> = {
      'openDate': s.openDate,
      'totalWeeks': s.totalWeeks,
      'title': s.title,
      'name': s.name,
      'firstColMode': s.firstColMode,
      'showSaturday': s.showSaturday,
      'showSunday': s.showSunday,
      'showNonCurrentWeek': s.showNonCurrentWeek,
      'cellHeight': s.cellHeight,
      'cornerRadius': s.cornerRadius,
      'shape': s.shape,
      'colWidth': s.colWidth,
      'nameSlot': s.nameSlot,
      'locationSlot': s.locationSlot,
      'teacherSlot': s.teacherSlot,
      'showTeacher': s.showTeacher,
      'showLocation': s.showLocation,
      'showGrid': s.showGrid,
      'weekOverride': s.weekOverride,
      'sectionsToShow': s.sectionsToShow,
      'bgColor': s.bgColor,
      'textScale': s.textScale,
      'blockOpacity': s.blockOpacity,
      'holidays': JSON.stringify(s.holidays),
    };
    return JSON.stringify(so);
  }

  /** 摘要文本：给对方一个人类可读的预览（也是 content 字段的值） */
  static summaryText(p: SchedulePayload): string {
    const name = p.name.length > 0 ? p.name : '知课笺课表';
    return `${name} · ${p.count} 个课程块`;
  }

  // ---------- 载荷构造：转写 ----------

  /** 把某次转写打包成分享载荷；找不到返回 null */
  private static buildTranscriptPayload(id: string): TranscriptPayload | null {
    const s = id.length === 0 ? TranscriptStore.current : TranscriptStore.find(id);
    if (s == null) {
      return null;
    }
    const p = new TranscriptPayload();
    p.version = 1;
    p.title = s.title;
    p.startMs = s.startMs;
    p.endMs = s.endMs;
    p.count = s.lines.length;
    p.summary = s.summary;
    const arr: string[] = [];
    for (const l of s.lines) {
      arr.push(l.text);
    }
    p.lines = arr;
    return p;
  }

  private static transcriptSummary(p: TranscriptPayload): string {
    const t = p.title.length > 0 ? p.title : '知课笺课堂笔记';
    return `${t} · ${p.count} 句`;
  }

  // ---------- 解析接收到的载荷 ----------

  /**
   * 从 SharedData 里提取载荷；不是知课笺的载荷则返回 null。
   * 判定依据：extraData 带 MARK_KEY，且 kind 已知并能解析出内容。
   */
  static parsePayload(data: systemShare.SharedData): PendingImport | null {
    let records: systemShare.SharedRecord[] = [];
    try {
      records = data.getRecords();
    } catch (e) {
      return null;
    }
    if (records.length === 0) {
      return null;
    }
    const extra = records[0].extraData;
    if (extra == null) {
      // extraData 没送达（跨设备兜底情况）：不硬认，交给上层提示用户
      return null;
    }
    const mark = extra[ShareService.MARK_KEY];
    if (mark == null) {
      return null;
    }
    const mv = `${mark}`;
    // v1 = 只有课表（旧版本发的）；v2 = 带 kind 字段
    const kind = mv === ShareService.MARK_VALUE
      ? (extra['kind'] == null ? ShareKind.SCHEDULE : `${extra['kind']}`)
      : ShareKind.SCHEDULE;
    if (kind === ShareKind.TRANSCRIPT) {
      return ShareService.parseTranscript(extra);
    }
    return ShareService.parseSchedule(extra);
  }

  private static parseSchedule(extra: Record<string, Object>): PendingImport | null {
    const coursesRaw = extra['courses_json'];
    if (coursesRaw == null) {
      return null;
    }
    const p = new SchedulePayload();
    const v = extra['payload_version'];
    p.version = v == null ? 1 : Number.parseInt(`${v}`, 10);
    if (isNaN(p.version) || p.version <= 0) {
      p.version = 1;
    }
    const nm = extra['schedule_name'];
    p.name = nm == null ? '知课笺课表' : `${nm}`;
    const ti = extra['schedule_title'];
    p.title = ti == null ? '' : `${ti}`;
    p.coursesJson = `${coursesRaw}`;
    const sraw = extra['semester_json'];
    p.semesterJson = sraw == null ? '{}' : `${sraw}`;
    p.count = ShareService.countCourses(p.coursesJson);

    const pending = new PendingImport();
    pending.kind = ShareKind.SCHEDULE;
    pending.payload = p;
    pending.parsed = p.count;
    pending.from = '碰一碰';
    return pending;
  }

  private static parseTranscript(extra: Record<string, Object>): PendingImport | null {
    const linesRaw = extra['transcript_lines'];
    if (linesRaw == null) {
      return null;
    }
    const p = new TranscriptPayload();
    p.title = extra['transcript_title'] == null ? '' : `${extra['transcript_title']}`;
    const sm = extra['transcript_start'];
    p.startMs = sm == null ? 0 : Number.parseInt(`${sm}`, 10);
    const em = extra['transcript_end'];
    p.endMs = em == null ? 0 : Number.parseInt(`${em}`, 10);
    p.summary = extra['transcript_summary'] == null ? '' : `${extra['transcript_summary']}`;
    const arr: string[] = [];
    // 用 \u0001 作行分隔（\n 在 extraData 的字符串里容易与转义混淆）
    for (const one of `${linesRaw}`.split('\u0001')) {
      if (one.length > 0) {
        arr.push(one);
      }
    }
    p.lines = arr;
    p.count = arr.length;
    if (p.count === 0 && p.summary.length === 0) {
      return null;
    }

    const pending = new PendingImport();
    pending.kind = ShareKind.TRANSCRIPT;
    pending.transcript = p;
    pending.parsed = p.count;
    pending.from = '碰一碰';
    return pending;
  }

  /** 数一下课程 JSON 里有几条（不依赖 CourseStore 的状态） */
  private static countCourses(json: string): number {
    try {
      const arr = JSON.parse(json) as Array<Record<string, Object>>;
      return arr.length;
    } catch (e) {
      return 0;
    }
  }

  // ---------- 发送侧：注册碰一碰 ----------

  /**
   * 注册碰一碰发送监听。
   *
   * 设备差异（实测 + 官方示例口径）：
   *  · 手机：`on('knockShare', cb)` 直接注册即可，**不要传 capability**；
   *  · PC / 2in1 / 平板：必须传 `{ windowId }`，否则碰一碰无响应（窗口级手势需要知道碰的是哪个窗口）。
   * 传错反而会导致监听不生效，所以这里按 deviceInfo.deviceType 分流。
   *
   * @param ctx 当前 Ability 上下文（2in1 用来取 windowId）
   * @param onStatus 状态回调：把"已就绪 / 正在发送 / 成功 / 失败"推给 UI
   */
  static async registerKnock(ctx: common.UIAbilityContext,
    onStatus: (text: string) => void): Promise<boolean> {
    if (ShareService.registered) {
      return true;
    }
    if (!canIUse('SystemCapability.Collaboration.HarmonyShare')) {
      ShareService.lastStatus = '本机不支持碰一碰';
      onStatus(ShareService.lastStatus);
      return false;
    }
    try {
      const cb: Callback<harmonyShare.SharableTarget> = (target: harmonyShare.SharableTarget) => {
        ShareService.onKnock(target, onStatus);
      };
      const devType: string = deviceInfo.deviceType as string;
      if (devType === '2in1' || devType === 'tablet') {
        const win = await window.getLastWindow(ctx);
        // SendCapabilityRegistry 是 interface，不能 new，用带类型标注的字面量构造
        const capObj: harmonyShare.SendCapabilityRegistry = {
          windowId: win.getWindowProperties().id,
        };
        harmonyShare.on('knockShare', capObj, cb);
      } else {
        harmonyShare.on('knockShare', cb);
      }
      ShareService.knockCb = cb;
      ShareService.registered = true;
      ShareService.lastStatus = '已就绪，等待碰一碰';
      onStatus(ShareService.lastStatus);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, 'skt', 'registerKnock failed: %{public}s', JSON.stringify(err));
      ShareService.lastStatus = `碰一碰不可用（${err.code}）`;
      onStatus(ShareService.lastStatus);
      return false;
    }
  }

  /** 注销碰一碰监听（页面离开时调用） */
  static unregisterKnock(): void {
    if (!ShareService.registered) {
      return;
    }
    try {
      const cb = ShareService.knockCb;
      if (cb != null) {
        harmonyShare.off('knockShare', cb);
      } else {
        harmonyShare.off('knockShare');
      }
    } catch (e) {
      hilog.error(DOMAIN, 'skt', 'unregisterKnock failed: %{public}s', JSON.stringify(e));
    }
    ShareService.registered = false;
    ShareService.knockCb = null;
    ShareService.lastStatus = '';
  }

  /** 碰一碰触发回调：按预置来源把内容投送给对端 */
  private static onKnock(target: harmonyShare.SharableTarget,
    onStatus: (text: string) => void): void {
    if (ShareService.pendingKind === ShareKind.TRANSCRIPT) {
      ShareService.shareTranscript(target, onStatus);
      return;
    }
    ShareService.shareSchedule(target, onStatus);
  }

  private static shareSchedule(target: harmonyShare.SharableTarget,
    onStatus: (text: string) => void): void {
    const payload = ShareService.buildPayload();
    if (payload.count === 0) {
      onStatus('课表是空的，没有内容可分享');
      target.reject(harmonyShare.SharableErrorCode.NO_CONTENT_ERROR).catch((e: BusinessError) => {
        hilog.error(DOMAIN, 'skt', 'reject failed: %{public}s', JSON.stringify(e));
      });
      return;
    }
    onStatus(`正在发送「${ShareService.summaryText(payload)}」…`);
    let data: systemShare.SharedData | null = null;
    try {
      data = ShareService.buildScheduleData(payload);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, 'skt', 'buildScheduleData failed: %{public}s', JSON.stringify(err));
      onStatus('组装分享数据失败');
      return;
    }
    target.share(data).then(() => {
      ShareService.lastStatus = `已发送：${ShareService.summaryText(payload)}`;
      onStatus(ShareService.lastStatus);
    }).catch((e: BusinessError) => {
      hilog.error(DOMAIN, 'skt', 'share failed: %{public}s', JSON.stringify(e));
      ShareService.lastStatus = `发送失败（${e.code}）`;
      onStatus(ShareService.lastStatus);
    });
  }

  private static shareTranscript(target: harmonyShare.SharableTarget,
    onStatus: (text: string) => void): void {
    const payload = ShareService.buildTranscriptPayload(ShareService.pendingSessionId);
    if (payload == null || (payload.count === 0 && payload.summary.length === 0)) {
      onStatus('这份笔记还没有内容');
      target.reject(harmonyShare.SharableErrorCode.NO_CONTENT_ERROR).catch((e: BusinessError) => {
        hilog.error(DOMAIN, 'skt', 'reject failed: %{public}s', JSON.stringify(e));
      });
      return;
    }
    onStatus(`正在发送「${ShareService.transcriptSummary(payload)}」…`);
    let data: systemShare.SharedData | null = null;
    try {
      data = ShareService.buildTranscriptData(payload);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, 'skt', 'buildTranscriptData failed: %{public}s', JSON.stringify(err));
      onStatus('组装分享数据失败');
      return;
    }
    target.share(data).then(() => {
      ShareService.lastStatus = `已发送：${ShareService.transcriptSummary(payload)}`;
      onStatus(ShareService.lastStatus);
    }).catch((e: BusinessError) => {
      hilog.error(DOMAIN, 'skt', 'share failed: %{public}s', JSON.stringify(e));
      ShareService.lastStatus = `发送失败（${e.code}）`;
      onStatus(ShareService.lastStatus);
    });
  }

  /**
   * 构造 SharedData。
   * SharedRecord 是 interface，系统未提供构造函数，用**带类型标注的对象字面量**直接构造。
   */
  private static buildScheduleData(p: SchedulePayload): systemShare.SharedData {
    const rec: systemShare.SharedRecord = {
      utd: ShareService.UTD_PLAIN_TEXT,
      content: ShareService.summaryText(p),
      title: p.name.length > 0 ? p.name : '知课笺课表',
      description: '碰一碰分享的课表，在知课笺中确认后可导入',
      extraData: ShareService.packScheduleExtra(p),
    };
    return new systemShare.SharedData(rec);
  }

  private static buildTranscriptData(p: TranscriptPayload): systemShare.SharedData {
    const rec: systemShare.SharedRecord = {
      utd: ShareService.UTD_PLAIN_TEXT,
      content: ShareService.transcriptSummary(p),
      title: p.title.length > 0 ? p.title : '知课笺课堂笔记',
      description: '碰一碰分享的课堂笔记，在知课笺中确认后可保存',
      extraData: ShareService.packTranscriptExtra(p),
    };
    return new systemShare.SharedData(rec);
  }

  /** 组装课表 extraData（Record 的值类型限定为 string|number|boolean|数组） */
  private static packScheduleExtra(p: SchedulePayload): Record<string, string | number | boolean> {
    const extra: Record<string, string | number | boolean> = {};
    extra[ShareService.MARK_KEY] = ShareService.MARK_VALUE;
    extra['kind'] = ShareKind.SCHEDULE;
    extra['payload_version'] = p.version;
    extra['schedule_name'] = p.name;
    extra['schedule_title'] = p.title;
    extra['courses_json'] = p.coursesJson;
    extra['semester_json'] = p.semesterJson;
    return extra;
  }

  /** 组装转写 extraData */
  private static packTranscriptExtra(p: TranscriptPayload): Record<string, string | number | boolean> {
    const extra: Record<string, string | number | boolean> = {};
    extra[ShareService.MARK_KEY] = ShareService.MARK_VALUE;
    extra['kind'] = ShareKind.TRANSCRIPT;
    extra['payload_version'] = p.version;
    extra['transcript_title'] = p.title;
    extra['transcript_start'] = p.startMs;
    extra['transcript_end'] = p.endMs;
    extra['transcript_summary'] = p.summary;
    // \u0001 作行分隔：\n 在 extraData 的字符串里容易被系统/上层转义，用不可见控制符更稳
    extra['transcript_lines'] = p.lines.join('\u0001');
    return extra;
  }

  // ---------- 接收侧：解析 want ----------

  /**
   * 尝试从 Ability 的 want 中解析分享数据。
   * 命中知课笺载荷时存入 pendingImport 并通知 UI。
   * @returns 是否识别到载荷
   */
  static async handleShareWant(want: Want): Promise<boolean> {
    try {
      const data = await systemShare.getSharedData(want);
      const pending = ShareService.parsePayload(data);
      if (pending == null) {
        return false;
      }
      ShareService.pendingImport = pending;
      AppState.log(`收到碰一碰分享：${pending.kind}，${pending.parsed} 项`);
      ShareService.notifyPending();
      return true;
    } catch (e) {
      // 不是分享 want 时会抛 1003703001（Parse data failed），属正常情况，不报错
      const err = e as BusinessError;
      hilog.info(DOMAIN, 'skt', 'handleShareWant: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  // ---------- 导入：课表 ----------

  /**
   * 把待确认载荷写入课表（覆盖式）。
   * 复用 CourseStore 的反序列化口径：直接走 preferences 同款字段映射。
   */
  static async applyImport(pending: PendingImport): Promise<ImportResult> {
    const res = new ImportResult();
    if (pending.kind !== ShareKind.SCHEDULE) {
      res.ok = false;
      res.message = '这不是课表载荷';
      return res;
    }
    const items = ShareService.decodeCourses(pending.payload.coursesJson);
    if (items.length === 0) {
      res.ok = false;
      res.message = '分享的课表里没有课程';
      return res;
    }
    CourseStore.courses = items;
    ShareService.applySemester(pending.payload.semesterJson);
    CourseStore.assignColors();
    await CourseStore.persist();
    res.ok = true;
    res.count = items.length;
    res.message = `已导入 ${items.length} 个课程块`;
    return res;
  }

  /** 反序列化课程数组（与 CourseStore.decodeCourses 同口径） */
  private static decodeCourses(raw: string): CourseItem[] {
    const out: CourseItem[] = [];
    try {
      const arr = JSON.parse(raw) as Array<Record<string, Object>>;
      for (const o of arr) {
        const c = new CourseItem();
        c.id = CourseStore.str(o, 'id');
        c.name = CourseStore.str(o, 'name');
        c.weekday = CourseStore.num(o, 'weekday', 1);
        c.startSection = CourseStore.num(o, 'startSection', 1);
        c.endSection = CourseStore.num(o, 'endSection', 1);
        c.weekText = CourseStore.str(o, 'weekText');
        c.location = CourseStore.str(o, 'location');
        c.teacher = CourseStore.str(o, 'teacher');
        c.campus = CourseStore.str(o, 'campus');
        c.colorIndex = CourseStore.num(o, 'colorIndex', -1);
        const wraw = CourseStore.str(o, 'weeks');
        if (wraw.length > 0) {
          try {
            c.weeks = JSON.parse(wraw) as number[];
          } catch (e) {
            c.weeks = [];
          }
        }
        if (c.name.length > 0) {
          out.push(c);
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, 'skt', 'decodeCourses failed');
    }
    return out;
  }

  /** 反序列化学期配置（与 CourseStore.restore 同口径） */
  private static applySemester(raw: string): void {
    if (raw.length === 0 || raw === '{}') {
      return;
    }
    try {
      const o = JSON.parse(raw) as Record<string, Object>;
      const s = new Semester();
      s.openDate = CourseStore.str(o, 'openDate');
      s.totalWeeks = CourseStore.num(o, 'totalWeeks', 16);
      s.title = CourseStore.str(o, 'title');
      s.name = CourseStore.strOr(o, 'name', '我的课表');
      s.firstColMode = CourseStore.strOr(o, 'firstColMode', 'open');
      s.showSaturday = CourseStore.boolOr(o, 'showSaturday', true);
      s.showSunday = CourseStore.boolOr(o, 'showSunday', true);
      s.showNonCurrentWeek = CourseStore.boolOr(o, 'showNonCurrentWeek', true);
      s.cellHeight = CourseStore.num(o, 'cellHeight', 58);
      s.colWidth = CourseStore.num(o, 'colWidth', 0);
      s.nameSlot = CourseStore.strOr(o, 'nameSlot', 'center');
      s.locationSlot = CourseStore.strOr(o, 'locationSlot', 'nameBelow');
      s.teacherSlot = CourseStore.strOr(o, 'teacherSlot', 'bottomCenter');
      s.cornerRadius = CourseStore.num(o, 'cornerRadius', 12);
      s.shape = CourseStore.strOr(o, 'shape', 'rounded');
      s.showTeacher = CourseStore.boolOr(o, 'showTeacher', true);
      s.showLocation = CourseStore.boolOr(o, 'showLocation', true);
      s.showGrid = CourseStore.boolOr(o, 'showGrid', true);
      s.weekOverride = CourseStore.num(o, 'weekOverride', 0);
      s.sectionsToShow = CourseStore.num(o, 'sectionsToShow', 14);
      s.bgColor = CourseStore.strOr(o, 'bgColor', '#FAF7F4');
      s.textScale = CourseStore.num(o, 'textScale', 100);
      s.blockOpacity = CourseStore.num(o, 'blockOpacity', 100);
      const hraw = CourseStore.str(o, 'holidays');
      if (hraw.length > 0) {
        try {
          s.holidays = JSON.parse(hraw) as string[];
        } catch (e) {
          s.holidays = [];
        }
      }
      CourseStore.semester = s;
    } catch (e) {
      hilog.error(DOMAIN, 'skt', 'applySemester failed');
    }
  }

  // ---------- 导入：转写 ----------

  /**
   * 把收到的转写笔记存为一条**新的历史记录**（不覆盖当前转写）。
   * 走 TranscriptStore 的正规入口，保证与本地生成的记录结构一致。
   */
  static async applyTranscriptImport(pending: PendingImport): Promise<ImportResult> {
    const res = new ImportResult();
    const t = pending.transcript;
    if (t.count === 0 && t.summary.length === 0) {
      res.ok = false;
      res.message = '分享的笔记里没有内容';
      return res;
    }
    const id = await TranscriptStore.importSession(t.title, t.startMs, t.endMs, t.lines, t.summary);
    if (id.length === 0) {
      res.ok = false;
      res.message = '保存失败（本地存储未就绪）';
      return res;
    }
    res.ok = true;
    res.count = t.count;
    res.message = `已保存到历史记录（${t.count} 句）`;
    return res;
  }

  /** 包名（供 UI 提示用） */
  static bundleName(): string {
    return AppConst.BUNDLE_NAME;
  }
}
