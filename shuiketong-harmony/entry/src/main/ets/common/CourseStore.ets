import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Sections } from './SectionTimes';
import { Theme } from './Theme';

/** 课表中的一个课程时间块（一次上课安排）。 */
export class CourseItem {
  id: string = '';
  name: string = '';
  weekday: number = 1;       // 1=周一 … 7=周日
  startSection: number = 1;  // 起始节次
  endSection: number = 1;    // 结束节次
  weeks: number[] = [];      // 上课周次列表
  weekText: string = '';     // 原始周次描述，如 "1-16周"
  location: string = '';
  teacher: string = '';
  campus: string = '';
  colorIndex: number = -1;   // 由 assignColors() 计算（8 邻域避色）
}

/** 课表配置（同时承担学期设置）。 */
export class Semester {
  openDate: string = '';          // 开课日 yyyy-MM-dd（第一周第一天）
  totalWeeks: number = 16;        // 学期周数
  title: string = '';             // 学期名，如 "2026-2027学年秋"
  name: string = '我的课表';       // 课表名称
  firstColMode: string = 'open';  // 第一列：open=开课日所在星期 | monday | sunday
  showSaturday: boolean = true;   // 显示周六
  showSunday: boolean = true;     // 显示周日
  showNonCurrentWeek: boolean = true; // 显示非本周课程（否则隐藏）
  cellHeight: number = 58;        // 每节次行高 dp
  /** 每天列宽 dp；0 = 按屏幕等分，>0 固定列宽（超出屏幕时表格可左右滚动，格子随之变大） */
  colWidth: number = 0;
  cornerRadius: number = 12;      // 格子圆角半径 dp
  shape: string = 'rounded';      // 形状：rounded=圆角矩形 | capsule=胶囊（单行近圆）
  showTeacher: boolean = true;    // 格子里显示教师
  showLocation: boolean = true;   // 格子里显示地点
  showGrid: boolean = true;       // 显示参考线
  weekOverride: number = 0;       // >0 时强制当前周（调休用）
  sectionsToShow: number = 14;    // 课表显示到第几节（1-14）
  bgColor: string = '#FAF7F4';    // 课表区背景色
  textScale: number = 100;        // 文字缩放百分比（85-130）
  blockOpacity: number = 100;     // 课程块不透明度百分比（60-100）
  holidays: string[] = [];        // 停课日期（yyyy-MM-dd），这些天视为无课
  // 格子内容位置（各自独立）：topLeft / topRight / center / bottomLeft / bottomRight / hidden
  // 各槽位**垂直堆叠**（不同槽位永远不会挤在同一行）
  // topLeft / topCenter / topRight / center / nameBelow / bottomLeft / bottomCenter / bottomRight / hidden
  nameSlot: string = 'center';         // 课程名位置
  locationSlot: string = 'nameBelow';  // 教室位置（课名下方一行）
  teacherSlot: string = 'bottomCenter';// 教师位置（贴底居中）
}

/** 一格课程块的三种配色（浅底 / 深字 / 强调条）。 */
export class CourseColor {
  bg: string = '';
  fg: string = '';
  bar: string = '';

  constructor(bg: string, fg: string, bar: string) {
    this.bg = bg;
    this.fg = fg;
    this.bar = bar;
  }
}

/** 导入结果。 */
export class ImportResult {
  ok: boolean = false;
  count: number = 0;
  message: string = '';
}

/** 下一节课的信息（课表提示条与上课提醒共用）。 */
export class UpcomingClass {
  found: boolean = false;
  name: string = '';
  location: string = '';
  teacher: string = '';
  weekday: number = 0;
  section: number = 0;
  daysAhead: number = 0;    // 0=今天 1=明天 …
  minutesLeft: number = -1; // 仅今天有效
  startMs: number = 0;      // 上课时刻时间戳
  key: string = '';         // 用于判断"是否换了一节课"
}

/**
 * 课表仓库：本地持久化 + 正方教务课表解析 + 周次/星期推算 + 邻接避色。
 * 持久化与 AppState 共用同一个 preferences 实例（skt_prefs）。
 */
export class CourseStore {
  static courses: CourseItem[] = [];
  static semester: Semester = new Semester();

  private static prefs: preferences.Preferences | null = null;
  private static listeners: Array<() => void> = [];

  /**
   * 配色板：柔和新中式 —— 底色加浓、文字加深，避免整体发灰发淡。
   * 已迁到 `Theme`（六套预制色系，可在「配色」页切换）：此处仅作默认橙系的历史备份，
   * 取色一律走 `colorOf()` → `Theme.paletteRaw()`。
   */
  static readonly PALETTE: CourseColor[] = [
    new CourseColor('#F8CDB4', '#8E3410', '#E05A2B'), // 丹橘
    new CourseColor('#C4CFF0', '#23306B', '#3A4F9E'), // 群青
    new CourseColor('#F5E3A8', '#6E4E0A', '#D9A21B'), // 藤黄
    new CourseColor('#C7E3C9', '#1F5A2C', '#5E8C43'), // 竹青
    new CourseColor('#F2C9E1', '#7A2E63', '#C471A8'), // 藕荷
    new CourseColor('#D3C8EE', '#382863', '#7A66B8'), // 黛紫
    new CourseColor('#BCDCE8', '#14506A', '#3E87A0'), // 石青
    new CourseColor('#E3D8A8', '#5A4E12', '#A89434'), // 秋香
    new CourseColor('#F2C3BC', '#8C2416', '#BF4630'), // 朱砂
    new CourseColor('#BFE3DE', '#14564A', '#3E9A8B'), // 松石
  ];

  /** 取课程块配色（按当前「课表配色系」） */
  static colorOf(item: CourseItem): CourseColor {
    const p = Theme.paletteRaw();
    const i = item.colorIndex < 0 ? 0 : item.colorIndex % p.length;
    const rgb = p[i];
    return new CourseColor(rgb[0], rgb[1], rgb[2]);
  }

  /** 订阅变更（订阅时立即回调一次）。 */
  static onChange(cb: () => void): void {
    CourseStore.listeners.push(cb);
    cb();
  }

  private static notify(): void {
    for (const cb of CourseStore.listeners) {
      cb();
    }
  }

  /** init() 是否已完成（碰一碰导入等场景要等它就绪，否则 persist() 会静默丢弃） */
  static ready: boolean = false;

  static async init(ctx: common.UIAbilityContext): Promise<void> {
    CourseStore.prefs = await preferences.getPreferences(ctx, 'skt_prefs');
    await CourseStore.restore();
    CourseStore.assignColors();
    CourseStore.ready = true;
  }

  // ---------- 邻接避色 ----------

  /**
   * 相邻课程块颜色互斥：左右、上下、对角（8 邻域）都不允许同色。
   * 贪心着色 —— 先按天/节次稳定排序，逐块挑一个未被邻块占用的颜色；
   * 同名课程优先复用已分配颜色，保持同一门课在课表里颜色一致（只要不与邻块冲突）。
   */
  static assignColors(): void {
    const list = CourseStore.courses.slice();
    list.sort((a, b) => {
      if (a.weekday !== b.weekday) {
        return a.weekday - b.weekday;
      }
      return a.startSection - b.startSection;
    });
    const n = Theme.paletteRaw().length;
    const nameColor: Map<string, number> = new Map<string, number>();
    for (const c of list) {
      const used: boolean[] = [];
      for (let i = 0; i < n; i++) {
        used.push(false);
      }
      for (const o of list) {
        if (o === c || o.colorIndex < 0) {
          continue;
        }
        if (CourseStore.adjacent(c, o)) {
          used[o.colorIndex] = true;
        }
      }
      let pick = -1;
      const hint = nameColor.get(c.name);
      if (hint != undefined && hint < n && !used[hint]) {
        pick = hint;   // 同门课保持同色
      }
      if (pick < 0) {
        for (let i = 0; i < n; i++) {
          if (!used[i]) {
            pick = i;
            break;
          }
        }
      }
      if (pick < 0) {
        pick = 0;
      }
      c.colorIndex = pick;
      nameColor.set(c.name, pick);
    }
  }

  /** 两课程块是否在网格上相邻（含对角）：天差 ≤1 且节次区间重叠或紧挨。 */
  private static adjacent(a: CourseItem, b: CourseItem): boolean {
    const dd = Math.abs(a.weekday - b.weekday);
    if (dd > 1) {
      return false;
    }
    return a.startSection <= b.endSection + 1 && b.startSection <= a.endSection + 1;
  }

  // ---------- 持久化 ----------

  private static async restore(): Promise<void> {
    const p = CourseStore.prefs;
    if (p == null) {
      return;
    }
    try {
      const raw = (await p.get('coursesJson', '[]')) as string;
      CourseStore.courses = CourseStore.decodeCourses(raw);
    } catch (e) {
      CourseStore.courses = [];
    }
    try {
      const sraw = (await p.get('semesterJson', '')) as string;
      if (sraw.length > 0) {
        const o = JSON.parse(sraw) as Record<string, Object>;
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
        s.nameSlot = CourseStore.str(o, 'nameSlot');
        s.locationSlot = CourseStore.str(o, 'locationSlot');
        s.teacherSlot = CourseStore.str(o, 'teacherSlot');
        if (s.nameSlot.length === 0) { s.nameSlot = 'center'; }
        if (s.locationSlot.length === 0) { s.locationSlot = 'nameBelow'; }
        if (s.teacherSlot.length === 0) { s.teacherSlot = 'bottomCenter'; }
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
          } catch (e2) {
            s.holidays = [];
          }
        }
        CourseStore.semester = s;
      }
    } catch (e) {
      // 忽略损坏配置
    }
  }

  static async persist(): Promise<void> {
    const p = CourseStore.prefs;
    if (p == null) {
      // ⚠️ 原来这里是静默 `return`，是 2026-10-07 定位「导入后课表没显示课程」时
      // 挖出来的真缺陷之一：`persist()` 末尾负责 `notify()`，而课表页
      // （`CourseTableView.onChange`）**只靠 notify 刷新**。prefs 没就绪时直接
      // return ⇒ 不落盘、**也不 notify** ⇒ 内存里的 courses 变了但课表页永远不重绘，
      // 而调用方（`ImportSchedule`）毫不知情，还会照样弹「导入成功」。
      // 现在至少留下 hilog，可在真机 `hilog -x -T CourseStore` 直接读出来。
      hilog.error(0x0000, 'CourseStore',
        'persist() skipped: prefs is null (init 未完成？) courses=%{public}d',
        CourseStore.courses.length);
      return;
    }
    const arr: Array<Record<string, Object>> = [];
    for (const c of CourseStore.courses) {
      const o: Record<string, Object> = {
        'id': c.id, 'name': c.name, 'weekday': c.weekday,
        'startSection': c.startSection, 'endSection': c.endSection,
        'weeks': JSON.stringify(c.weeks), 'weekText': c.weekText,
        'location': c.location, 'teacher': c.teacher,
        'campus': c.campus, 'colorIndex': c.colorIndex,
      };
      arr.push(o);
    }
    await p.put('coursesJson', JSON.stringify(arr));
    const s = CourseStore.semester;
    const so: Record<string, Object> = {
      'openDate': s.openDate, 'totalWeeks': s.totalWeeks, 'title': s.title,
      'name': s.name, 'firstColMode': s.firstColMode,
      'showSaturday': s.showSaturday, 'showSunday': s.showSunday,
      'showNonCurrentWeek': s.showNonCurrentWeek,
      'cellHeight': s.cellHeight, 'cornerRadius': s.cornerRadius, 'shape': s.shape,
      'colWidth': s.colWidth, 'nameSlot': s.nameSlot,
      'locationSlot': s.locationSlot, 'teacherSlot': s.teacherSlot,
      'showTeacher': s.showTeacher, 'showLocation': s.showLocation,
      'showGrid': s.showGrid, 'weekOverride': s.weekOverride,
      'sectionsToShow': s.sectionsToShow, 'bgColor': s.bgColor,
      'textScale': s.textScale, 'blockOpacity': s.blockOpacity,
      'holidays': JSON.stringify(s.holidays),
    };
    await p.put('semesterJson', JSON.stringify(so));
    await p.flush();
    CourseStore.notify();
  }

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
      // 损坏则返回空
    }
    return out;
  }

  static async setSemester(openDate: string, totalWeeks: number, title: string): Promise<void> {
    CourseStore.semester.openDate = openDate;
    CourseStore.semester.totalWeeks = totalWeeks;
    CourseStore.semester.title = title;
    await CourseStore.persist();
  }

  /** 保存任意配置改动（视图改完配置后调用）。 */
  static async saveConfig(): Promise<void> {
    await CourseStore.persist();
  }

  static async clearAll(): Promise<void> {
    CourseStore.courses = [];
    await CourseStore.persist();
  }

  // ---------- 正方教务课表解析 ----------

  static importFromZfJson(raw: string): ImportResult {
    const res = new ImportResult();
    const text = raw.trim();
    const s = text.indexOf('{');
    const e = text.lastIndexOf('}');
    if (s < 0 || e <= s) {
      res.message = '返回内容不是课表数据（可能未登录或页面未加载完）';
      return res;
    }
    let o: Record<string, Object>;
    try {
      o = JSON.parse(text.substring(s, e + 1)) as Record<string, Object>;
    } catch (err) {
      res.message = '课表 JSON 解析失败';
      return res;
    }
    const kb = o['kbList'];
    if (kb == null) {
      res.message = '未找到 kbList 字段：请先在教务页面完成查询';
      return res;
    }
    const arr = kb as Array<Record<string, Object>>;
    const items: CourseItem[] = [];
    for (const r of arr) {
      const c = CourseStore.fromZfRecord(r);
      if (c != null) {
        items.push(c);
      }
    }
    if (items.length === 0) {
      res.message = '课表为空（该学期可能没有排课）';
      return res;
    }
    CourseStore.courses = CourseStore.dedup(items);
    CourseStore.assignColors();   // 重新按邻接避色分配
    res.ok = true;
    res.count = CourseStore.courses.length;
    res.message = `已导入 ${res.count} 个课程时间块`;
    return res;
  }

  private static fromZfRecord(r: Record<string, Object>): CourseItem | null {
    const name = CourseStore.str(r, 'kcmc');
    if (name.length === 0) {
      return null;
    }
    const c = new CourseItem();
    c.name = name.trim();
    c.weekday = CourseStore.num(r, 'xqj', 1);
    if (c.weekday < 1 || c.weekday > 7) {
      return null;
    }
    const sec = CourseStore.parseSections(CourseStore.str(r, 'jcs'));
    c.startSection = sec[0];
    c.endSection = sec[1];
    if (c.startSection < 1 || c.startSection > 14) {
      return null;
    }
    c.weekText = CourseStore.str(r, 'zcd');
    c.weeks = CourseStore.parseWeeks(c.weekText);
    // 场地：正方标准字段是 cdmc；个别版本场地名为空但给了教学楼名（jxlmc），兜底取一下
    let loc = CourseStore.str(r, 'cdmc').trim();
    if (loc.length === 0) {
      loc = CourseStore.str(r, 'jxlmc').trim();
    }
    c.location = loc;
    c.teacher = CourseStore.str(r, 'xm').trim();
    c.campus = CourseStore.str(r, 'xqmc');
    c.id = `${c.weekday}|${c.startSection}|${c.endSection}|${c.name}|${c.weekText}`;
    return c;
  }

  private static dedup(items: CourseItem[]): CourseItem[] {
    const seen: CourseItem[] = [];
    for (const it of items) {
      let dup = false;
      for (const s of seen) {
        if (s.id === it.id) {
          dup = true;
          break;
        }
      }
      if (!dup) {
        seen.push(it);
      }
    }
    return seen;
  }

  /** "1-2" / "3" / "1-2节" -> [start, end] */
  private static parseSections(jcs: string): number[] {
    const t = jcs.replace(/[^0-9\-]/g, '');
    const parts = t.split('-');
    const a = parseInt(parts[0], 10);
    const b = parts.length > 1 ? parseInt(parts[1], 10) : a;
    const start = isNaN(a) ? 1 : a;
    const end = isNaN(b) ? start : b;
    return [start, end < start ? start : end];
  }

  /** 周次描述解析："1-16" / "1-16周" / "1,3,5" / "2-16双" / "1-15单" / "5-8,10-12"。 */
  static parseWeeks(zcd: string): number[] {
    let s = zcd.replace(/周/g, '').trim();
    let parity = 0; // 0=全部 1=单周 2=双周
    if (s.endsWith('单')) {
      parity = 1;
      s = s.substring(0, s.length - 1);
    } else if (s.endsWith('双')) {
      parity = 2;
      s = s.substring(0, s.length - 1);
    }
    const out: number[] = [];
    for (const seg of s.split(',')) {
      const t = seg.trim();
      if (t.length === 0) {
        continue;
      }
      if (t.indexOf('-') > 0) {
        const ab = t.split('-');
        const a = parseInt(ab[0], 10);
        const b = parseInt(ab[1], 10);
        if (!isNaN(a) && !isNaN(b)) {
          for (let i = a; i <= b; i++) {
            out.push(i);
          }
        }
      } else {
        const n = parseInt(t, 10);
        if (!isNaN(n)) {
          out.push(n);
        }
      }
    }
    const filtered: number[] = [];
    for (const w of out) {
      const need = parity === 0 || (parity === 1 ? w % 2 === 1 : w % 2 === 0);
      if (need) {
        filtered.push(w);
      }
    }
    return filtered;
  }

  // ---------- 周次 / 星期推算 ----------

  private static parseDateMs(s: string): number {
    const t = s.trim().replace(/-/g, '/');
    if (t.length === 0) {
      return 0;
    }
    const ms = new Date(t).getTime();
    return isNaN(ms) ? 0 : ms;
  }

  private static startOfDay(ms: number): number {
    const d = new Date(ms);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
  }

  /** 今天是第几周（1 起）；未到开课日返回 0，超出学期周数返回 -1。 */
  static currentWeek(nowMs: number): number {
    const open = CourseStore.parseDateMs(CourseStore.semester.openDate);
    if (open <= 0) {
      return 0;
    }
    const days = Math.floor((CourseStore.startOfDay(nowMs) - CourseStore.startOfDay(open)) / 86400000);
    if (days < 0) {
      return 0;
    }
    const w = Math.floor(days / 7) + 1;
    return w > CourseStore.semester.totalWeeks ? -1 : w;
  }

  /** 实际生效的周次（手动指定优先）。 */
  static effectiveWeek(nowMs: number): number {
    const ov = CourseStore.semester.weekOverride;
    if (ov > 0) {
      return ov;
    }
    return CourseStore.currentWeek(nowMs);
  }

  /** 开课日对应的星期（1=周一 … 7=周日）；未设置返回 1。 */
  static openWeekday(): number {
    const ms = CourseStore.parseDateMs(CourseStore.semester.openDate);
    if (ms <= 0) {
      return 1;
    }
    const js = new Date(ms).getDay(); // 0=周日
    return js === 0 ? 7 : js;
  }

  /** 今天星期几（1=周一 … 7=周日）。 */
  static todayWeekday(nowMs: number): number {
    const js = new Date(nowMs).getDay();
    return js === 0 ? 7 : js;
  }

  /** 全部列顺序（未过滤周六周日）：第一列由 firstColMode 决定。 */
  static columnWeekdays(): number[] {
    const mode = CourseStore.semester.firstColMode;
    let first = CourseStore.openWeekday();
    if (mode === 'monday') {
      first = 1;
    } else if (mode === 'sunday') {
      first = 7;
    }
    const out: number[] = [];
    for (let i = 0; i < 7; i++) {
      out.push(((first - 1 + i) % 7) + 1);
    }
    return out;
  }

  /** 实际展示的列（按配置隐藏周六/周日）。 */
  static visibleWeekdays(): number[] {
    const out: number[] = [];
    for (const wd of CourseStore.columnWeekdays()) {
      if (wd === 6 && !CourseStore.semester.showSaturday) {
        continue;
      }
      if (wd === 7 && !CourseStore.semester.showSunday) {
        continue;
      }
      out.push(wd);
    }
    return out;
  }

  /** 第 week 周第 weekday 天的日期（yyyy-MM-dd）；未设置开课日返回 ''。 */
  static dateOf(week: number, weekday: number): string {
    const open = CourseStore.parseDateMs(CourseStore.semester.openDate);
    if (open <= 0 || week < 1) {
      return '';
    }
    const offset = (week - 1) * 7 + (weekday - CourseStore.openWeekday());
    const d = new Date(CourseStore.startOfDay(open) + offset * 86400000);
    const mm = (d.getMonth() + 1).toString().padStart(2, '0');
    const dd = d.getDate().toString().padStart(2, '0');
    return `${d.getFullYear()}-${mm}-${dd}`;
  }

  /** 今天的日期串 */
  static todayStr(nowMs: number): string {
    const d = new Date(nowMs);
    const mm = (d.getMonth() + 1).toString().padStart(2, '0');
    const dd = d.getDate().toString().padStart(2, '0');
    return `${d.getFullYear()}-${mm}-${dd}`;
  }

  static courseAt(weekday: number, section: number): CourseItem | null {
    for (const c of CourseStore.courses) {
      if (c.weekday === weekday && c.startSection === section) {
        return c;
      }
    }
    return null;
  }

  static activeInWeek(item: CourseItem, week: number): boolean {
    if (item.weeks.length === 0) {
      return true;
    }
    return item.weeks.indexOf(week) >= 0;
  }

  // ---------- 周次预览（翻周查看） ----------

  /** 第 week 周有课的课程块数量（周选择器里显示，用来一眼看出 1-8 周 / 9-16 周的区别）。 */
  static activeCountInWeek(week: number): number {
    let n = 0;
    for (const c of CourseStore.courses) {
      if (CourseStore.activeInWeek(c, week)) {
        n += 1;
      }
    }
    return n;
  }

  /** 第 week 周的日期范围文本 "10-27 ~ 11-02"（按周一到周日）；未设开课日返回 ''。 */
  static weekRangeText(week: number): string {
    const mon = CourseStore.dateOf(week, 1);
    const sun = CourseStore.dateOf(week, 7);
    if (mon.length === 0 || sun.length === 0) {
      return '';
    }
    return `${mon.substring(5)} ~ ${sun.substring(5)}`;
  }

  // ---------- 手动管理课程 ----------

  /** 稳定 id：同一天、同节次、同名、同周次视为同一个课程块（重新导入时用于去重） */
  static makeId(c: CourseItem): string {
    return `${c.weekday}|${c.startSection}|${c.endSection}|${c.name}|${c.weekText}`;
  }

  /** 新增或更新（id 相同则整块替换），并重跑邻接避色 */
  static async upsertCourse(c: CourseItem): Promise<void> {
    c.id = CourseStore.makeId(c);
    const i = CourseStore.courses.findIndex((x: CourseItem) => x.id === c.id);
    if (i >= 0) {
      CourseStore.courses[i] = c;
    } else {
      CourseStore.courses.push(c);
    }
    CourseStore.assignColors();
    await CourseStore.persist();
  }

  static async deleteCourse(id: string): Promise<void> {
    CourseStore.courses = CourseStore.courses.filter((x: CourseItem) => x.id !== id);
    CourseStore.assignColors();
    await CourseStore.persist();
  }

  /** 按 星期 → 起始节次 → 课名 排序（管理页用） */
  static sortedCourses(): CourseItem[] {
    const out = CourseStore.courses.slice();
    out.sort((a: CourseItem, b: CourseItem) => {
      if (a.weekday !== b.weekday) {
        return a.weekday - b.weekday;
      }
      if (a.startSection !== b.startSection) {
        return a.startSection - b.startSection;
      }
      if (a.name === b.name) {
        return 0;
      }
      return a.name < b.name ? -1 : 1;
    });
    return out;
  }

  // ---------- 节假日（停课日） ----------

  static isHoliday(date: string): boolean {
    return date.length > 0 && CourseStore.semester.holidays.indexOf(date) >= 0;
  }

  static async addHoliday(date: string): Promise<void> {
    if (date.length === 0 || CourseStore.isHoliday(date)) {
      return;
    }
    const list = CourseStore.semester.holidays.slice();
    list.push(date);
    list.sort();
    CourseStore.semester.holidays = list;
    await CourseStore.persist();
  }

  static async removeHoliday(date: string): Promise<void> {
    CourseStore.semester.holidays =
      CourseStore.semester.holidays.filter((d: string) => d !== date);
    await CourseStore.persist();
  }

  /** 第 week 周第 weekday 天是否停课 */
  static holidayInWeek(week: number, weekday: number): boolean {
    return CourseStore.isHoliday(CourseStore.dateOf(week, weekday));
  }

  /**
   * 未来 days 天内的所有课（按时间升序，跳过停课日）。
   * 上课提醒用它一次性把未来几天的提醒排给系统（代理提醒），这样应用被杀也能提醒。
   */
  static upcomingList(nowMs: number, days: number): UpcomingClass[] {
    const out: UpcomingClass[] = [];
    const base = CourseStore.startOfDay(nowMs);
    const nowMin = CourseStore.nowMinutes(nowMs);
    for (let step = 0; step < days; step++) {
      const dayMs = base + step * 86400000;
      const dateStr = CourseStore.todayStr(dayMs);
      if (CourseStore.isHoliday(dateStr)) {
        continue;   // 停课日整天跳过
      }
      const week = CourseStore.effectiveWeek(dayMs);
      if (week < 1) {
        continue;
      }
      const wd = CourseStore.todayWeekday(dayMs);
      const isFirst = step === 0;
      const list: CourseItem[] = [];
      for (const c of CourseStore.courses) {
        if (c.weekday !== wd || !CourseStore.activeInWeek(c, week)) {
          continue;
        }
        if (isFirst && CourseStore.startMinutes(c.startSection) <= nowMin) {
          continue;   // 今天的课：已开始的不要
        }
        list.push(c);
      }
      list.sort((a: CourseItem, b: CourseItem) => a.startSection - b.startSection);
      for (const c of list) {
        const up = new UpcomingClass();
        up.found = true;
        up.name = c.name;
        up.location = c.location;
        up.teacher = c.teacher;
        up.weekday = wd;
        up.section = c.startSection;
        up.daysAhead = step;
        up.startMs = dayMs + CourseStore.startMinutes(c.startSection) * 60000;
        up.key = `${wd}|${c.startSection}|${c.name}|${dateStr}`;
        out.push(up);
      }
    }
    return out;
  }

  // ---------- 时间 ----------

  /** 某节课的开始/结束时间换算为当天分钟数；无效返回 -1。 */
  static startMinutes(section: number): number {
    const s = Sections.of(section);
    if (s == null) {
      return -1;
    }
    const p = s.start.split(':');
    return parseInt(p[0], 10) * 60 + parseInt(p[1], 10);
  }

  static endMinutes(section: number): number {
    const s = Sections.of(section);
    if (s == null) {
      return -1;
    }
    const p = s.end.split(':');
    return parseInt(p[0], 10) * 60 + parseInt(p[1], 10);
  }

  static nowMinutes(nowMs: number): number {
    const d = new Date(nowMs);
    return d.getHours() * 60 + d.getMinutes();
  }

  /** 此刻正在上的节次（1-14）；不在上课时段返回 0。 */
  static currentSection(nowMs: number): number {
    const m = CourseStore.nowMinutes(nowMs);
    for (const s of Sections.SLOTS) {
      if (m >= CourseStore.startMinutes(s.no) && m < CourseStore.endMinutes(s.no)) {
        return s.no;
      }
    }
    return 0;
  }

  // ---------- 小工具 ----------

  static str(o: Record<string, Object>, k: string): string {
    const v = o[k];
    return typeof v === 'string' ? v as string : '';
  }

  static strOr(o: Record<string, Object>, k: string, dft: string): string {
    const v = o[k];
    return typeof v === 'string' && (v as string).length > 0 ? v as string : dft;
  }

  static num(o: Record<string, Object>, k: string, dft: number): number {
    const v = o[k];
    if (typeof v === 'number') {
      return v as number;
    }
    if (typeof v === 'string') {
      const n = parseInt(v as string, 10);
      return isNaN(n) ? dft : n;
    }
    return dft;
  }

  static boolOr(o: Record<string, Object>, k: string, dft: boolean): boolean {
    const v = o[k];
    return typeof v === 'boolean' ? v as boolean : dft;
  }

  // ---------- 正在上 / 下一节（课表与上课提醒共用） ----------

  /** 此刻正在上的课；没在上课返回 null。 */
  static ongoing(nowMs: number): CourseItem | null {
    const sec = CourseStore.currentSection(nowMs);
    if (sec <= 0) {
      return null;
    }
    const c = CourseStore.courseAt(CourseStore.todayWeekday(nowMs), sec);
    if (c == null || !CourseStore.activeInWeek(c, CourseStore.effectiveWeek(nowMs))) {
      return null;
    }
    return c;
  }

  /**
   * 用于「推断科目」的课程名。优先级：
   *   ① 此刻正在上的课
   *   ② 今天接下来最近的一节
   *   ③ 今天已经上过的最近一节（补课 / 拖堂 / 课后自习）
   *   ④ 空串（今天完全没课）
   *
   * 【2026-09-30 搬到 CourseStore · 消除两处口径不一致】
   * 原来这个方法藏在 `AsrService`（private static），设置页要用同一套逻辑
   * 就得复制一份 —— 复制两份必然漂移。搬到这里成为唯一来源：
   * `AsrService.resolveSubject()` 与设置页 `refreshSubject()` 都调它。
   */
  static currentCourseName(nowMs: number): string {
    const c = CourseStore.ongoing(nowMs);
    if (c != null) {
      return c.name;
    }
    const wd = CourseStore.todayWeekday(nowMs);
    const week = CourseStore.effectiveWeek(nowMs);
    const sec = CourseStore.currentSection(nowMs);
    // ② 往后找最近的一节
    for (let s = sec + 1; s <= 14; s++) {
      const it = CourseStore.courseAt(wd, s);
      if (it != null && CourseStore.activeInWeek(it, week)) {
        return it.name;
      }
    }
    // ③ 往前回溯最近的一节（当天最后一节课之后 / 晚上启动的场景）
    for (let s = (sec > 14 ? 14 : sec); s >= 1; s--) {
      const it = CourseStore.courseAt(wd, s);
      if (it != null && CourseStore.activeInWeek(it, week)) {
        return it.name;
      }
    }
    return '';
  }

  /** 从此刻起、往后 7 天内最近的一节课（跳过停课日）。 */
  static upcoming(nowMs: number): UpcomingClass {
    const out = new UpcomingClass();
    const base = CourseStore.startOfDay(nowMs);
    const nowMin = CourseStore.nowMinutes(nowMs);
    for (let step = 0; step < 7; step++) {
      const dayMs = base + step * 86400000;
      const dateStr = CourseStore.todayStr(dayMs);
      if (CourseStore.isHoliday(dateStr)) {
        continue;   // 停课日整天跳过
      }
      const week = CourseStore.effectiveWeek(dayMs);
      if (week < 1) {
        continue;
      }
      const wd = CourseStore.todayWeekday(dayMs);
      const isFirst = step === 0;
      let best: CourseItem | null = null;
      for (const c of CourseStore.courses) {
        if (c.weekday !== wd || !CourseStore.activeInWeek(c, week)) {
          continue;
        }
        const sm = CourseStore.startMinutes(c.startSection);
        if (isFirst && sm <= nowMin) {
          continue;
        }
        if (best == null || c.startSection < best.startSection) {
          best = c;
        }
      }
      if (best != null) {
        out.found = true;
        out.name = best.name;
        out.location = best.location;
        out.teacher = best.teacher;
        out.weekday = wd;
        out.section = best.startSection;
        out.daysAhead = step;
        out.minutesLeft = isFirst ? CourseStore.startMinutes(best.startSection) - nowMin : -1;
        out.startMs = dayMs + CourseStore.startMinutes(best.startSection) * 60000;
        out.key = `${wd}|${best.startSection}|${best.name}|${dateStr}`;
        return out;
      }
    }
    return out;
  }
}
