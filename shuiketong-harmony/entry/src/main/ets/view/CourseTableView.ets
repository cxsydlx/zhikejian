import { display, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { CourseColor, CourseItem, CourseStore } from '../common/CourseStore';
import { Sections, SectionSlot } from '../common/SectionTimes';
import { Theme } from '../common/Theme';
import { Mat } from '../common/Material';
import { WindowInsets } from '../common/WindowInsets';
import { FontSize, Weight, Space, Radius, Size, Motion, Elevation, Layout } from '../common/DesignToken';

/**
 * 配色不再写死：UI 主题色 / 强调色 / 主次字色 全部走 `Theme`（「配色」页可切换色系或单独指定）。
 * 每处渲染时读取 → 改配色后视图订阅 Theme 变更即可重绘。
 */
const LINE = '#E5E0DA';
/** 参考线用色：浅色虚线 */
const GRID_LINE = '#E4DED6';
/** 课程块上下留白的一半 —— 上下各内缩 6vp，相邻两块的缝隙合计 12vp */
const GAP_HALF = 6;
const CELL_H_GAP = 6;    // 左右内缩，同上
const SEC_W = 58;        // 左侧节次列宽（要放下「08:00-08:45」整段时间）
/**
 * 星期表头行高。
 * 2026-09-28 从字面量 40 提成常量 —— 改成液态玻璃后需要显式给 Row 设高
 * （原来没设，靠子项撑），否则 `border` 的上下缘高光会贴到文字上。
 */
const HEADER_H = 44;
/**
 * 悬浮顶栏胶囊左右「多出一圈」的余量（2026-09-28 第七次修正新增）。
 *
 * 顶栏做成浮层后，它应该比下方课表网格**略宽一圈**（视觉上"压"在内容上）。
 * 页面常规边距是 `Layout.screenMargin()`(16)，浮层用它减 6 = 10，
 * 于是胶囊左右各比网格多出 6vp 的"探出量"，悬浮感来自这里。
 */
const CARD_INSET = 6;
const WD_TEXT: string[] = ['', '一', '二', '三', '四', '五', '六', '日'];

/**
 * 一个渲染单元 = 网格里的一段连续节次。
 * 高 = span × 行高，与左侧节次列、参考线严格对齐；底部一条虚线即该段的行界线。
 */
class Cell {
  course: CourseItem | null = null;
  start: number = 1;
  span: number = 1;
}

/** 下一节课 / 正在上课的信息 */
class NextInfo {
  kind: string = 'none';   // now=正在上 | next=下一节 | none=没有课
  weekday: number = 0;
  section: number = 0;
  startTime: string = '';
  name: string = '';
  location: string = '';
  teacher: string = '';
  minutesLeft: number = -1;
  endLeftMin: number = -1;  // 正在上课时：距离下课还有多少分钟
  daysAhead: number = 0;   // 0=今天 1=明天 …
}

/**
 * 课表视图（主页 Tab）。
 *
 * 网格对齐规则（关键）：
 * - 行高恒定 cellHeight()，**节次列每一行也是整行高**，所以左边节次的上下端永远落在参考线上；
 * - 每个渲染单元（课程块或空格）高度 = 节次跨度 × 行高，单元的底边就是参考线；
 * - 参考线不是单独一层铺图，而是"每个单元自己的底边虚线"：
 *   一门课连排跨多个大节时，中间那几条线**根本不存在**，所以不存在"颜色浅了透出参考线"的问题。
 */
@Component
export struct CourseTableView {
  // ---- 主题镜像：ArkUI 只观察「渲染中读取过」的状态；配色变化必须镜像成 @State 才会重绘 ----
  @State tc: string = Theme.themeColor();
  @State tacc: string = Theme.accentColor();
  @State tsoft: string = Theme.softColor();
  @State tpage: string = Theme.pageColor();
  @State ton: string = Theme.onTheme();
  @State tmain: string = Theme.textMain();
  @State tsub: string = Theme.textSub();
  @State toa: string = Theme.onAccent();

  @State courses: CourseItem[] = [];
  /**
   * 渲染版本号：时间推进与课表数据变化时都 +1，并**作为 ForEach 的 key 的一部分**。
   * ArkUI 的 ForEach 只在 key 变化时重建条目，key 不变则沿用旧 UI ——
   * 这正是之前"改了设置界面不刷新"的根因。
   */
  @State rev: number = 0;
  /**
   * 预览周次：0 = 跟随真实本周；>0 = 正在预览该周。
   * 只影响课表显示（含表头日期、非本周课程淡显），**不影响上课提醒** ——
   * 提醒走 CourseStore.effectiveWeek()，翻周看第 15 周不会让提醒跟着跑偏。
   */
  @State viewWeek: number = 0;
  @State showWeekPick: boolean = false;
  /** 周次胶囊条是否展开（默认收起，点左上角「第 X 周」才展开） */
  @State showWeekStrip: boolean = false;
  /** 横向滚动控制器（列宽调大后表格超出屏幕时左右滑） */
  private hScroller: Scroller = new Scroller();
  /**
   * 整页纵向滚动控制器（2026-09-28 结构修正新增）。
   *
   * 原结构里纵向滚动是「表头之下那一小块」的局部滚动 —— 表头在它外面，
   * 所以往上滑到表头就停（用户反馈「只会到节次那里」）。
   * 现在整页只有这一个纵向滚动容器，表头 + 网格都在里面。
   */
  private vScroller: Scroller = new Scroller();

  /** 可见天数 */
  private daysCount(): number {
    return CourseStore.visibleWeekdays().length;
  }

  /**
   * 列宽(vp)：默认按屏宽等分；设置了固定列宽且比等分更宽时用固定值 ——
   * 此时表格总宽超出屏幕，外层横向滚动，格子随之变大。
   */
  private colW(): number {
    const n = this.daysCount();
    if (n <= 0) {
      return 0;
    }
    const screen = px2vp(display.getDefaultDisplaySync().width);
    const fit = (screen - SEC_W - 12) / n;
    const fixed = CourseStore.semester.colWidth;
    // 显式设了更大列宽 → 用设定值（横向滚动，格子变大）
    if (fixed > 0 && fixed > fit) {
      return fixed;
    }
    // 否则按屏宽等分 —— 课表必须一屏铺满（用户用平板就是为了全周一眼看完）。
    //
    // ⚠️ 曾尝试封顶到 Layout.colMaxWidth()(112)，结论是**错的**：
    // 平板 1400vp 下总宽只有 842vp，右侧空出 25% 一片死白，比巨列更难看。
    // 而且 `Scroll` 的内容区宽度由子元素决定（`gridW()`），外层加 `align` 也不会居中
    // —— 除非把网格宽度硬撑到 100%，那又等于不封顶。
    // 所以课表**不做宽度收敛**；需要限制阅读行宽的是设置/听课这类文本页。
    return fit;
  }

  /** 表格内容总宽 */
  private gridW(): number {
    return SEC_W + this.colW() * this.daysCount();
  }

  private ctx: common.UIAbilityContext | null = null;
  private timer: number = -1;
  /** 周次胶囊条的滚动控制器：切换周时把选中格滚到可见位置 */
  private weekScroller: Scroller = new Scroller();

  private syncTheme(): void {
    this.tc = Theme.themeColor();
    this.tacc = Theme.accentColor();
    this.tsoft = Theme.softColor();
    this.tpage = Theme.pageColor();
    this.ton = Theme.onTheme();
    this.tmain = Theme.textMain();
    this.tsub = Theme.textSub();
    this.toa = Theme.onAccent();
  }

  aboutToAppear(): void {
    Theme.onChange(() => {
      this.syncTheme();
    });
    this.syncTheme();

    this.ctx = getContext(this) as common.UIAbilityContext;
    CourseStore.onChange(() => {
      this.courses = CourseStore.courses.slice();
      this.rev += 1;
    });
    // 配色变了（配色页/其它页面改的）→ 重绘
    Theme.onChange(() => {
      this.rev += 1;
    });
    // 今天列 / 当前节次 / 下一节课 随时间推进刷新
    this.timer = setInterval(() => {
      this.rev += 1;
    }, 30000);
    setTimeout(() => {
      this.syncStripScroll();
    }, 120);
  }

  /** 把当前周对应的胶囊滚进可视区（列表可能还没布局完，失败忽略） */
  private syncStripScroll(): void {
    const idx = this.barWeek() - 1;
    if (idx < 0) {
      return;
    }
    try {
      this.weekScroller.scrollToIndex(idx, true, ScrollAlign.CENTER);
    } catch (e) {
      // 列表尚未布局：忽略
    }
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  // ---------- 时间状态 ----------

  private weekLabel(): string {
    if (CourseStore.semester.openDate.length === 0) {
      return '未设开课日';
    }
    const w = CourseStore.effectiveWeek(Date.now());
    if (w === 0) {
      return '未开学';
    }
    if (w < 0) {
      return '已结课';
    }
    const ov = CourseStore.semester.weekOverride > 0 ? '（手动）' : '';
    return `第 ${w} 周${ov}`;
  }

  /**
   * ⛔ **当前无调用点（2026-09-28）** —— 保留备用，不是死代码遗漏。
   *
   * 原来显示在顶栏第二行右侧（`第 3 周 ... 周一 09-28`）。
   * 顶栏压成单行后，中间列让给了「下一节课」提示，这个日期就没有位置了：
   * 日期信息在**周列表头**（`headerRow()` 的 `headerSub(wd)`）里已经逐列显示，
   * 顶栏再重复一遍属于冗余，故保留方法但不渲染。
   *
   * 保留原因：日后若加"点顶栏弹日历/跳周"之类的交互，这是现成的格式化函数。
   * 若要彻底清理，删掉本方法即可（无任何引用）。
   */
  private todayLabel(): string {
    const now = Date.now();
    const wd = CourseStore.todayWeekday(now);
    return `周${WD_TEXT[wd]} ${CourseStore.todayStr(now).substring(5)}`;
  }

  /** 正在上的课，或下一节课（统一走 CourseStore，停课日自动跳过） */
  private nextInfo(): NextInfo {
    const now = Date.now();
    const info = new NextInfo();

    // 1) 正在上的课
    const cur = CourseStore.ongoing(now);
    if (cur != null) {
      info.kind = 'now';
      info.weekday = CourseStore.todayWeekday(now);
      info.section = CourseStore.currentSection(now);
      info.name = cur.name;
      info.location = cur.location;
      info.teacher = cur.teacher;
      info.endLeftMin = CourseStore.endMinutes(cur.endSection) - CourseStore.nowMinutes(now);
      return info;
    }

    // 2) 下一节课
    const up = CourseStore.upcoming(now);
    if (up.found) {
      info.kind = 'next';
      info.weekday = up.weekday;
      info.section = up.section;
      info.name = up.name;
      info.location = up.location;
      info.teacher = up.teacher;
      info.daysAhead = up.daysAhead;
      info.minutesLeft = up.minutesLeft;
    }
    return info;
  }

  /** 「还有多久」文案：不足 1 小时说分钟，否则说小时 */
  private leftText(minutes: number): string {
    if (minutes <= 0) {
      return '';
    }
    if (minutes < 60) {
      return `还有 ${minutes} 分钟`;
    }
    const h = Math.floor(minutes / 60);
    const m = minutes % 60;
    return m === 0 ? `还有 ${h} 小时` : `还有 ${h} 小时 ${m} 分`;
  }

  private nextText(): string {
    const i = this.nextInfo();
    if (i.kind === 'none') {
      if (CourseStore.semester.openDate.length === 0) {
        return '还没设置开课日，点右上角「设置」里填';
      }
      return this.courses.length === 0 ? '还没有课表，点「导入」从教务抓取' : '本周没有更多课了';
    }
    const loc = i.location.length > 0 ? ` · ${i.location}` : '';
    if (i.kind === 'now') {
      const left = this.leftText(i.endLeftMin);
      const tail = left.length > 0 ? ` · ${left}下课` : '';
      return `● 正在上 · ${i.name}${loc}${tail}`;
    }
    const t = Sections.of(i.section);
    const at = t == null ? '' : t.start;
    const head = `▸ 下一节课 · ${i.name}${loc}`;
    if (i.daysAhead === 0) {
      const left = this.leftText(i.minutesLeft);
      const tail = left.length > 0 ? `（${left}）` : '';
      return `${head} · ${at} 开始${tail}`;
    }
    if (i.daysAhead === 1) {
      return `${head} · 明天 ${at} 开始`;
    }
    return `${head} · 周${WD_TEXT[i.weekday]} ${at} 开始`;
  }

  private nextIsNow(): boolean {
    return this.nextInfo().kind === 'now';
  }

  /** 翻周预览时的提示文案 */
  private previewText(): string {
    const w = this.shownWeek();
    const range = CourseStore.weekRangeText(w);
    const n = CourseStore.activeCountInWeek(w);
    const r = range.length > 0 ? ` · ${range}` : '';
    return `正在预览 第 ${w} 周${r} · 本周 ${n} 门课`;
  }

  // ---------- 网格 ----------

  /** 一行（一个节次）的高度 */
  private cellHeight(): number {
    const h = CourseStore.semester.cellHeight;
    return h < 40 ? 40 : (h > 100 ? 100 : h);
  }

  /** 网格总高 */
  private gridHeight(): number {
    return this.showSections() * this.cellHeight();
  }

  /**
   * 课程块内部可用高度（扣掉上下缝隙与内边距）。
   * 用来决定这一块放得下几行文字 —— 按"实际高度"判断，而不是死卡节数：
   * 之前写的是「跨 2 节显示教师、跨 3 节才显示地点」，结果 1-2 节的课永远看不到教室。
   */
  private innerBlockHeight(span: number): number {
    return span * this.cellHeight() - GAP_HALF * 2 - 6;
  }

  /**
   * 课程名自适应字号：按列宽与字数估算，一行放不下就整体缩小（下限 9）；
   * 目的是"宁可字小也别把字挤成一团"。
   */
  private nameFont(name: string, span: number): number {
    const base = (span >= 2 ? 14 : 13) * this.ts();
    const avail = this.colW() - 14;
    const len = name.length > 0 ? name.length : 1;
    const perChar = avail / len;
    return perChar < base ? (perChar < 9 ? 9 : perChar) : base;
  }

  /** 该块高度能放下的行数（上限 4），不再固定 2/3 行 */
  private nameLines(fontSize: number, span: number): number {
    const h = span * this.cellHeight() - 14;
    const n = Math.floor(h / (fontSize * 1.35));
    if (n < 1) {
      return 1;
    }
    return n > 4 ? 4 : n;
  }

  /** 小字（地点 / 教师）字号 */
  private smallFont(name: string, span: number): number {
    const v = this.nameFont(name, span) * 0.72;
    return v < 8 ? 8 : v;
  }

  /**
   * 取「某个位置」应该显示的文本。
   * 课程名 / 教室 / 教师各自独立配置位置（topLeft / topRight / center / bottomLeft / bottomRight / hidden），
   * 同一位置只显示第一个命中的元素（简单可预期）。返回 '' 表示该位置空着。
   */
  private slotText(c: CourseItem, span: number, slot: string): string {
    const sem = CourseStore.semester;
    if (sem.nameSlot === slot) {
      return c.name;
    }
    if (sem.locationSlot === slot && sem.showLocation && c.location.length > 0) {
      return c.location;
    }
    if (sem.teacherSlot === slot && sem.showTeacher && c.teacher.length > 0) {
      return c.teacher;
    }
    return '';
  }

  /**
   * 课程块的文字行：按槽位顺序**从上到下垂直堆叠**（不同槽位永远不会挤在同一行）。
   * 编码 "A|S|文本"：A=对齐(L/C/R)、S=字号(B 大 / S 小)。
   */
  private cellRows(c: CourseItem, span: number): string[] {
    const order: string[] = ['topLeft', 'topCenter', 'topRight', 'center', 'nameBelow',
      'bottomLeft', 'bottomCenter', 'bottomRight'];
    const out: string[] = [];
    for (const slot of order) {
      const t = this.slotText(c, span, slot);
      if (t.length === 0) {
        continue;
      }
      let a = 'C';
      if (slot.endsWith('Left')) {
        a = 'L';
      } else if (slot.endsWith('Right')) {
        a = 'R';
      }
      const big = slot === 'center';
      out.push(`${a}|${big ? 'B' : 'S'}|${t}`);
    }
    return out;
  }

  private rowText(row: string): string {
    return row.substring(4);
  }

  /** 一律水平居中：文字要落在格子正中间（位置设置只决定上下顺序，不再影响左右对齐） */
  private rowAlign(row: string): TextAlign {
    return TextAlign.Center;
  }

  private rowBold(row: string): boolean {
    return row.substring(2, 3) === 'B';
  }

  private rowFont(row: string, name: string, span: number): number {
    return this.rowBold(row) ? this.nameFont(name, span) : this.smallFont(name, span);
  }


  private visibleIf(text: string): Visibility {
    return text.length > 0 ? Visibility.Visible : Visibility.None;
  }

  private canShowTeacher(span: number): boolean {
    return this.innerBlockHeight(span) >= 70;
  }

  /** 教室比教师更该优先显示（找不到教室比不认识老师更麻烦），所以门槛更低 */
  private canShowLocation(span: number): boolean {
    return this.innerBlockHeight(span) >= 54;
  }

  /** 文字缩放系数（配置为百分比） */
  private ts(): number {
    const s = CourseStore.semester.textScale;
    return (s < 85 ? 85 : (s > 140 ? 140 : s)) / 100;
  }

  /** 课程块不透明度系数 */
  private blockAlpha(): number {
    const a = CourseStore.semester.blockOpacity;
    return (a < 50 ? 50 : (a > 100 ? 100 : a)) / 100;
  }

  /** 一天显示到第几节 */
  private showSections(): number {
    const n = CourseStore.semester.sectionsToShow;
    return n < 4 ? 4 : (n > Sections.TOTAL ? Sections.TOTAL : n);
  }

  /**
   * 课程块圆角：
   * rounded = 用配置半径；capsule / circle = 取高度一半。
   * 矩形格子画不出真正的圆，因此「圆形」按单行成整圆、多行成胶囊处理。
   */
  private radiusFor(span: number): number {
    const h = span * this.cellHeight() - GAP_HALF * 2;
    const shape = CourseStore.semester.shape;
    if (shape === 'capsule' || shape === 'circle') {
      return h / 2;
    }
    const r = CourseStore.semester.cornerRadius;
    return r > h / 2 ? h / 2 : r;
  }

  private todayWd(): number {
    return CourseStore.todayWeekday(Date.now());
  }

  /** 预览别的周时不再标"今天"列（那一列的日期已经不是今天了） */
  private isToday(wd: number): boolean {
    return !this.isPreview() && wd === this.todayWd();
  }

  /** 该列在当前显示的这一周是否是停课日（节假日） */
  private isHolidayCol(wd: number): boolean {
    const w = this.shownWeek();
    return CourseStore.holidayInWeek(w > 0 ? w : 1, wd);
  }

  /** 表头副行：停课日显示「停课」，否则显示日期 MM-DD */
  private headerSub(wd: number): string {
    const w = this.shownWeek() > 0 ? this.shownWeek() : 1;
    if (CourseStore.holidayInWeek(w, wd)) {
      return '停课';
    }
    return CourseStore.dateOf(w, wd).substring(5);
  }

  // ---------- 周次预览 ----------

  /** 真实的当前周（受设置里「手动指定周次」影响） */
  private realWeek(): number {
    return CourseStore.effectiveWeek(Date.now());
  }

  /** 课表当前正在显示的周次（预览优先） */
  private shownWeek(): number {
    return this.viewWeek > 0 ? this.viewWeek : this.realWeek();
  }

  /** 是否正在预览「非本周」 */
  private isPreview(): boolean {
    return this.viewWeek > 0 && this.viewWeek !== this.realWeek();
  }

  private weekCount(): number {
    const n = CourseStore.semester.totalWeeks;
    return n < 1 ? 1 : n;
  }

  /** 切换条上显示的周次（未开学时按第 1 周显示，方便提前查看） */
  private barWeek(): number {
    const w = this.shownWeek();
    return w < 1 ? 1 : w;
  }

  private weekList(): number[] {
    const out: number[] = [];
    for (let i = 1; i <= this.weekCount(); i++) {
      out.push(i);
    }
    return out;
  }

  /**
   * 翻到第 w 周（只改显示，不写配置）。
   * 注意：viewWeek 是 @State，但网格用 ForEach 渲染，而 **ForEach 只在 key 变化时重建** ——
   * 所以这里必须同时 +rev，否则格子不会重画。
   */
  private gotoWeek(w: number): void {
    const n = this.weekCount();
    this.viewWeek = w < 1 ? 1 : (w > n ? n : w);
    this.rev += 1;
    this.syncStripScroll();
  }

  private backToNow(): void {
    this.viewWeek = 0;
    this.showWeekPick = false;
    this.rev += 1;
    this.syncStripScroll();
  }

  private columnCells(wd: number): Cell[] {
    const out: Cell[] = [];
    const week = this.shownWeek();
    const shown = this.showSections();
    // 停课日（节假日）：整列不排课
    if (CourseStore.holidayInWeek(week, wd)) {
      for (let s = 1; s <= shown; s++) {
        const b = new Cell();
        b.start = s;
        out.push(b);
      }
      return out;
    }
    let s = 1;
    while (s <= shown) {
      let hit: CourseItem | null = null;
      for (const c of this.courses) {
        if (c.weekday === wd && c.startSection === s) {
          hit = c;
          break;
        }
      }
      if (hit == null) {
        const blank = new Cell();
        blank.start = s;
        blank.span = 1;
        out.push(blank);
        s += 1;
        continue;
      }
      // 同一门课跨多个大节时，按「大课间（≥15 分钟）」切成多块：
      // 大节之间必须留出空隙，不能糊成一整块。
      const show = CourseStore.semester.showNonCurrentWeek || CourseStore.activeInWeek(hit, week);
      const last = hit.endSection > shown ? shown : hit.endSection;
      let segStart = hit.startSection;
      while (segStart <= last) {
        let segEnd = segStart;
        while (segEnd < last && !Sections.isBreakAfter(segEnd)) {
          segEnd += 1;
        }
        const cell = new Cell();
        cell.start = segStart;
        cell.span = segEnd - segStart + 1;
        if (show) {
          cell.course = hit;
        }
        out.push(cell);
        segStart = segEnd + 1;
      }
      s = last + 1;
    }
    return out;
  }

  private showDetail(c: CourseItem): void {
    const when = `周${WD_TEXT[c.weekday]} ${Sections.rangeText(c.startSection, c.endSection)}（${Sections.spanText(c.startSection, c.endSection)}）`;
    const lines: string[] = [when];
    if (c.location.length > 0) {
      lines.push(`地点：${c.campus.length > 0 ? c.campus + ' ' : ''}${c.location}`);
    }
    if (c.teacher.length > 0) {
      lines.push(`教师：${c.teacher}`);
    }
    if (c.weekText.length > 0) {
      lines.push(`周次：${c.weekText}`);
    }
    AlertDialog.show({
      title: c.name,
      message: lines.join('\n'),
      confirm: { value: '知道了', action: () => {} },
    });
  }

  /**
   * 课程块文字颜色：命中「地区 → 字色」规则时用规则色，否则用该块自己的深色。
   * （规则在「配色」页配置，比如"基教楼 → 蓝色字"）
   */
  private fgOf(c: CourseItem): string {
    const rc = Theme.regionColor(c.name, c.location, c.campus);
    return rc.length > 0 ? rc : CourseStore.colorOf(c).fg;
  }

  /** 正在上的课：只有看本周时才标；翻到别的周时这一栏不再是"现在" */
  private isOngoing(c: CourseItem): boolean {    if (this.isPreview()) {
      return false;
    }
    const now = Date.now();
    if (c.weekday !== CourseStore.todayWeekday(now)) {
      return false;
    }
    if (!CourseStore.activeInWeek(c, CourseStore.effectiveWeek(now))) {
      return false;
    }
    const m = CourseStore.nowMinutes(now);
    return m >= CourseStore.startMinutes(c.startSection) && m < CourseStore.endMinutes(c.endSection);
  }

  /** 今天正在上的节次（用于行高亮）；今天没课、非上课时段、或正在翻其他周时返回 0 */
  private currentSecOfToday(): number {
    if (this.isPreview()) {
      return 0;
    }
    const now = Date.now();
    const sec = CourseStore.currentSection(now);
    if (sec <= 0) {
      return 0;
    }
    const c = CourseStore.courseAt(CourseStore.todayWeekday(now), sec);
    if (c == null || !CourseStore.activeInWeek(c, CourseStore.effectiveWeek(now))) {
      return 0;
    }
    return sec;
  }

  private isCurrentSection(no: number): boolean {
    if (this.isPreview()) {
      return false;
    }
    const now = Date.now();
    if (CourseStore.currentSection(now) !== no) {
      return false;
    }
    const c = CourseStore.courseAt(CourseStore.todayWeekday(now), no);
    return c != null && CourseStore.activeInWeek(c, CourseStore.effectiveWeek(now));
  }

  // ---------- UI ----------

  /**
   * 内容区顶栏（**单行紧凑版**，2026-09-28 按用户要求重排）。
   *
   * ## 改版前（占三行，纵向吃掉太多屏幕）
   * ```
   * 知课笺                                        [导入]
   * 第 3 周 ⌄                              周一 09-28
   * ● 下一节课 · 机械工程导论 · 教学楼315 · 明天 08:00 开始
   * ```
   * 三行加起来约 140vp，平板横屏下把课表挤到下半屏；且「知课笺」是 App 名，
   * 占据顶栏最重的位置却零信息量 —— 用户明确要求压成一行。
   *
   * ## 改版后（单行，约 64vp）
   * ```
   * 第 3 周 ⌄          ▸ 下一节：机械工程导论 · 教学楼315          [导入]
   * ```
   * · 左：`第 N 周 ⌄` —— **仍然是点开周次胶囊条的热区**（行为不变，热区扩大到整块左侧）
   * · 中：下一节/正在上课提示 —— 原来独立占一整条的 `hintBar` 收进中间，
   *       用 `layoutWeight(1)` 抢剩余宽度，左右各留 `Space.m` 保证不贴到两侧
   * · 右：`导入` 胶囊按钮
   * · **移除 `知课笺`**（App 名在启动器/任务卡里已有）
   *
   * ## 为什么提示文字要截断而不是换行
   * 单行顶栏的高度必须固定（`Size.bar`），文字一旦折行就会把顶栏撑高、破坏与网格的对齐。
   * 课程名/地点可能很长 → `maxLines(1)` + `TextOverflow.Ellipsis`。
   * 想读全文的话下面还有课表本体，顶栏只承担"一眼看到关键信息"的作用。
   *
   * ## 为什么不用 `HdsNavigation`（全局结论，详见 common/RouteBar.ets 头部）
   * `HdsNavigation` 在**本工程设备上完全不可用**：`canIUse` 返回 true，但内部子树永不渲染。
   * 三种场景全部白屏 —— TabContent 内 / @Entry 路由页 / 极简 titleBar。
   * ∴ **全工程一律不使用 `HdsNavigation`**，顶栏统一自绘，
   * 沉浸光感由 `Mat.bar()`（含 `lightEffect`）提供。
   * ⚠️ 代价：拿不到「滚动渐变模糊」—— 那是 `HdsNavigation` 独有能力。
   */
  @Builder
  barContent() {
    // ==========================================================================
    // 【2026-09-28 第七次修正 · 顶栏改为「悬浮胶囊」】
    //
    // ## 用户要求（原话）
    // > 「这个第三周这一个容器，没有必要做成一个，第四个一条边全部贴在屏幕上面，
    // >   你可以做成一个**带有圆角的容器，放在课表上层，像是悬浮着**，
    // >   然后再加上**液态玻璃效果，记得有折射**。」
    //
    // ## 改动：贴边满宽条 → 四周留空的圆角胶囊
    // 原形态是一条顶到屏幕左右两边的实色长条 + 下缘分隔线，
    // 视觉上是「页面的一部分」而不是「浮起来的控件」。
    //
    // ## 拆成两层的原因
    // · **本函数（外层）**：只负责「四周留白 + 顶到状态栏下方」——
    //   留白让胶囊脱离屏幕边缘，"悬浮感"首先来自这里。
    // · **`barCapsule()`（内层）**：胶囊本体（圆角 + 玻璃 + 边缘高光）。
    //   ⚠️ 圆角**必须开在内层**：若开在外层，外层 padding 区域会被算进圆角范围，
    //      圆角会画在留白之外 → 胶囊看起来还是贴边的（这一步踩过）。
    // ==========================================================================
    Row() {
      this.barCapsule()
    }
    .width('100%')
    // 左右留白 = 页面常规边距 再收进 CARD_INSET，
    // 让胶囊比下方课表网格「多出一圈」—— 浮层压在内容上的视觉暗示。
    .padding({
      left: Layout.screenMargin() - CARD_INSET,
      right: Layout.screenMargin() - CARD_INSET,
      top: Space.s + WindowInsets.statusBarVp(),
      bottom: Space.none,
    })
  }

  /**
   * 顶栏悬浮胶囊（第七次修正新增）。
   *
   * 用户要求「带有圆角的容器，放在课表上层，像是悬浮着」——
   * 把它从"贴边条"抽出来做成独立的圆角胶囊，四周留白，与表头共用一套玻璃语言。
   */
  @Builder
  barCapsule() {
    // ==========================================================================
    // 【2026-09-28 第九次修正 · 加一层「小薄雾」】
    //
    // ## 用户要求（原话）
    // > 「回退到上个版本，再加一层小薄雾」
    //
    // 已回退到 54d127f（悬浮胶囊，无折射环）。本版**只加一层薄雾**，不动别的。
    //
    // ## 什么是"薄雾"
    // 上一版的问题不是"不够透"，而是**太干净** —— ULTRA_THIN 模糊只做了
    // "把背景糊掉"，玻璃表面缺少一层**均匀的、极淡的散射感**。
    // 真实玻璃（尤其磨砂/带水汽的）表面会有一层弥散的微光，
    // 让底下的颜色"看得见但被拉远"。这层就是薄雾。
    //
    // ## 做法
    // 在内容**下面**垫一层 `Stack` 底衬：
    // · 一层极淡的近白 + 一层主题色微染，两者叠加 = 均匀薄雾
    // · 用一个极缓慢的 `radialGradient`（不像第八轮那样做"中部亮斑"，
    //   这里要的是**均匀**，所以中心到边缘只差一点点，几乎看不出方向）
    // · 不挂材质（材质在外层 Stack 上）—— 薄雾只是**着色**，不是独立材质
    //
    // ⚠️ 与第八轮的区别（别再搞混）：
    // · 第八轮 = 边缘强高光 + 中部亮斑 → 做"折射 + 凸面"（**不均匀**）
    // · 本轮   = 均匀的一层淡雾 → 做"表面散射"（**均匀**）
    // 这两件事视觉目标相反，不能同时叠，用户明确说要雾就不要再加折射环。
    // ==========================================================================
    Stack({ alignContent: Alignment.TopStart }) {
      // ---- 薄雾层（垫在内容下面）----
      // 中心与边缘浓度几乎一致（0.10 → 0.06），只留一丝极缓的过渡避免"平板感"。
      //
      // ⚠️ 高度**必须给确定值**，不能写 `'100%'`：
      // 外层 Stack 自身没有固定高度（由内容撑开），子节点写 `height('100%')`
      // 会去解析"父容器的高度"这个尚不存在的值 → Stack 被撑到异常尺寸，
      // 内容看起来"跑到中间"（本次踩的坑）。
      // 用 `capsuleHostH()`（即胶囊内高 = touchTarget + 上下 padding）精确对上内容行高。
      Column()
        .width('100%')
        .height(this.capsuleHostH())
        .borderRadius(Radius.xl)
        .radialGradient({
          center: ['50%', '50%'] as [Length, Length],
          radius: '86%',
          colors: [
            // 中心：薄雾本体（近白混一点点暖，避免发冷）
            // 【2026-09-28 第十六次修正】0.10 → 0.12，与听课/设置页统一（三页同构）。
            [Theme.alphaOf(Theme.glassHighlight(), 0.12), 0.0],
            // 边缘：只比中心淡一点点 —— 要的是"均匀"，不是"亮斑"
            [Theme.alphaOf(Theme.glassHighlight(), 0.06), 1.0],
          ],
        })

      // ---- 内容（原 Row 整体下沉一层）----

      Row() {
        // ---- 左：第 N 周（点开周次条）----
        // 【2026-09-28 第二十一次修正 · 前景色改系统资源值以启用 colorInvert】
        //   用户要求顶栏也能"按背景亮度自动黑/白"，而 `colorInvert` **只认 `$r('sys.color.*')`**。
        //   原来「第 N 周」用 `this.tmain`、下拉箭头用 `this.tc`（都是算出来的 hex）→ 不触发。
        //   → 周次走 `text_primary`，箭头走 `text_secondary`。
        Row() {
          Text(`第 ${this.barWeek()} 周`)
            .fontSize(FontSize.titleS)
            .fontWeight(Weight.bold)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
          Text(this.isPreview() ? '预览' : '⌄')
            .fontSize(FontSize.bodyS)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .margin({ left: Space.xs })
        }
        .height(Size.touchTarget)
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.showWeekStrip = !this.showWeekStrip;
          this.rev += 1;
        })

        // ---- 中：下一节课提醒卡（替换原单行文字）----
        // 【2026-09-28 第十一次修正】用户给出参考图（淡蓝底 + 左竖条 + 图标 +
        // 课程名/时间地点 + 右侧倒计时），要求「就跟你之前改的胶囊一样」做成卡，
        // 并明确「中间那行删掉，只留卡片」。
        //
        // ⚠️ 配色换成本页色系：参考图是**蓝色**系（偏教务/iOS 通知观感），
        //    而课表页主色是暖橙红（#C0492F）。照搬蓝底会跟整页打架，
        //    所以保留**全部结构与比例**，只把色相换成 this.tc / tintColor。
        //    这点已跟用户说明。
        this.nextClassCard()

        // ---- 预览态下的「回到本周」----
        if (this.isPreview()) {
          Text('回到本周')
            .fontSize(FontSize.bodyS)
            .fontWeight(Weight.medium)
            .fontColor(this.tc)
            .padding({ left: Space.s, right: Space.s, top: Space.xs, bottom: Space.xs })
            .onClick(() => {
              this.backToNow();
            })
        }

        // ---- 右：导入 ----
        // 【2026-09-28 第二十次修正 · 官方胶囊规范】原来手写 height/padding/borderRadius.full；
        // 改用官方 `ButtonType.Capsule` + `controlSize(SMALL)` + `role`。
        // ⚠️ 它是**次要按钮**（浅色副容器底 + `Mat.tile()`），不是主题色实底 —— 这点保持不变。
        Button('导入', { type: ButtonType.Capsule, stateEffect: true })
          .controlSize(ControlSize.SMALL)
          .role(ButtonRole.NORMAL)
          .fontWeight(Weight.medium)
          // 【2026-09-28 第二十一次修正】`this.tmain` → 系统资源值（启用 colorInvert，见上）
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .backgroundColor(Theme.innerBase())
          .systemMaterial(Mat.tile())
          .onClick(() => {
            router.pushUrl({ url: 'pages/ImportSchedule' });
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: Space.s, right: Space.s, top: Space.s, bottom: Space.s })
    }
    .width('100%')
    // ⚠️ Stack 没有 `alignItems`（那是 Row/Column 的）—— 对齐用 `alignContent`。
    // 这里不设：内容 Row 已是 width('100%') + 自身 alignItems，够用。
    // ==========================================================================
    // ---- 胶囊玻璃本体（与 headerRow 同一套：ULTRA_THIN + 极低着色 + 反色）----
    //
    // 原来的顶栏是**贴边满宽实色条**，视觉上是"页面的一部分"。
    // 用户要求做成「悬浮在上层的圆角容器」，所以这里：
    // · 大圆角（Radius.xl = 24）—— 圆角是"这是一块独立浮板"的第一视觉信号
    // · 四周留白（交给外层 padding，见 barContent 尾部）
    // · 极低不透明度降级底 + 液态玻璃材质 —— 底下课程块滚过时能被模糊透出
    // · 用 `Mat.floatGlass()`（= 液态玻璃 + **applyShadow**）→ 自带投影，
    //   投影就是"悬浮感"的物理来源（表头用的是无阴影的 `liquidGlass()`）
    // ==========================================================================
    // 【2026-09-28 第十六次修正 · 三页统一 + 补回透明性】
    //   ① 参照系：原来 `alphaOf(this.tpage, 0.10)` 在本页"看着正常"纯属侥幸
    //      —— 本页页面底是更深的 `scheduleBgColor()`；同一参数搬到浅底页面就消失。
    //      → 色相统一参照 `mix(softColor, #FFF, 0.25)`。
    //   ② 不透明度：第十五轮一度写成实色（alpha 100%）→ 材质被盖死、胶囊不透。
    //      → 留 0.45，让沉浸材质有东西可透。
    .backgroundColor(Theme.alphaOf(Theme.mix(Theme.softColor(), '#FFFFFF', 0.25), 0.45))
    .systemMaterial(Mat.floatGlass())
    .borderRadius(Radius.xl)
    // ---- 边缘高光：玻璃板的受光面（"折射"观感的来源，同 headerRow 的做法）----
    // ⚠️ 系统**没有**折射 API（SDK 全文搜 refract 零命中），只能用「上缘近白高光 +
    //    下缘暗切边」造出"这是一块有厚度的玻璃板"的错觉，以此近似折射观感。
    .border({
      width: { top: 1, bottom: Size.divider },
      color: {
        top: Theme.glassHighlight(),
        // 【2026-09-28 第二十二次修正 · 下缘改中性灰分隔线】
        //   用户要求：「容器和容器之间用一条灰色横线隔离」→ 特指**顶栏胶囊下方**。
        //   原来是 `mix(tsoft, #000, 0.12)` —— 带主题色调、且太淡（12% 黑），
        //   在浅色页面上基本看不见。改成中性灰：不跟主题色走、三页统一、边界清晰。
        //   用半透明而非实色，避免完全盖住胶囊自带的玻璃投影。
        bottom: Theme.alphaOf('#B3B3B3', 0.50),
      },
    })
  }

  /**
   * 下一节课提醒卡（第十一次修正新增，替换胶囊中间那行文字）。
   *
   * ## 参考图结构（用户提供）
   * ```
   * ┌──────────────────────────────────────────────────────┐
   * │ ▌ ┌──┐  下一节 · 高等数学              距离上课       │
   * │ ▌ │📘│                                  32 分钟      │
   * │ ▌ └──┘  10:00 · 教学楼 A203                          │
   * └──────────────────────────────────────────────────────┘
   *   ↑左竖条  ↑图标   ↑主文/副文            ↑右侧倒计时
   * ```
   * · **左竖条**：强调色实心圆角条，是"这是哪一类通知"的分类标识
   * · **图标**：圆角方块底 + 书本图形
   * · **主文**：`下一节 · 课程名`（粗、主文字色）
   * · **副文**：`时间 · 地点`（细、次级色）
   * · **右**：上方小字`距离上课` + 下方**大号数字**`32` + 小字`分钟`
   * · **卡片**：大圆角 + 淡色底
   *
   * ## ⚠️ 配色：换成本页色系（已跟用户说明）
   * 参考图是**蓝色**系（教务/iOS 通知那种观感），课表页主色是暖橙红 `#C0492F`。
   * 照搬蓝底会跟整页打架 → **保留全部结构与比例，只换色相**：
   * · 左竖条 / 图标底 / 大数字 → `this.tc`（主题色）
   * · 卡底 → `Theme.tintColor(0.90)`（主题色极浅混白）
   *
   * ## 三种状态
   * · `now`（正在上课）：主文改`正在上 · 课程名`，右侧显示`距下课 / N 分钟`
   * · `next` 且今天（`daysAhead === 0`）：显示`距离上课 / N 分钟`
   * · `next` 非今天（明天/本周内）：右侧换成`明天` / `周X`，不再显示分钟
   * · `none`（没课）：整卡替换为一句提示文字（复用原 `nextText()` 文案）
   */
  @Builder
  nextClassCard() {
    if (this.nextInfo().kind === 'none') {
      // 没课：退回单行提示（不做空卡，避免占位）
      Text(this.isPreview() ? this.previewText() : this.nextText())
        .fontSize(FontSize.bodyS)
        .fontColor(this.tsub)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ left: Space.m, right: Space.m })
    } else {
      Row() {
        // ---- 左：强调色竖条 ----
        // 高 ≈ 内容高的一半：短条读作"分类标识"，长条会读成"边框"
        Column()
          .width(3)
          .height(Size.touchTarget * 0.55)
          .borderRadius(Radius.xs)
          .backgroundColor(this.tc)

        // ---- 图标：圆角方块 + 书本 ----
        Stack() {
          Text('\u{1F4D8}')
            .fontSize(FontSize.bodyM)
        }
        .width(Size.touchTarget * 0.72)
        .height(Size.touchTarget * 0.72)
        .borderRadius(Radius.s)
        .backgroundColor(this.tc)
        .margin({ left: Space.s })

        // ---- 中：主文 + 副文 ----
        // 【2026-09-28 第二十一次修正 · 前景色改系统资源值以启用 colorInvert】
        //   卡片挂在顶栏胶囊内，胶囊挂的是 `Mat.floatGlass()`（ULTRA_THIN + colorInvert），
        //   所以这里也必须用资源值才能被反色接管。
        //   ⚠️ 左侧竖条 / 图标块 / 右侧大数字**保持 `this.tc` 主题色不动** ——
        //     它们是"色标"，属于内容语义（跟课程块的彩色策略一致），不参与黑白反色。
        Column() {
          Text(this.cardTitle())
            .fontSize(FontSize.bodyM)
            .fontWeight(Weight.bold)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.cardSub())
            .fontSize(FontSize.captionL)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: Space.textGap })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: Space.s })

        // ---- 右：倒计时（大数字）----
        Column() {
          Text(this.cardRightTop())
            .fontSize(FontSize.captionM)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          Row() {
            Text(this.cardBigNum())
              .fontSize(FontSize.titleL)
              .fontWeight(Weight.bold)
              .fontColor(this.tc)
            Text(this.cardUnit())
              .fontSize(FontSize.captionL)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
              .margin({ left: Space.textGap })
              .alignSelf(ItemAlign.End)
          }
          .alignItems(VerticalAlign.Bottom)
        }
        .alignItems(HorizontalAlign.End)
        .margin({ left: Space.s })
      }
      .layoutWeight(1)
      .alignItems(VerticalAlign.Center)
      .padding({ left: Space.s, right: Space.m, top: Space.xsPlus, bottom: Space.xsPlus })
      .borderRadius(Radius.m)
      // 卡底 40% —— 用户指定「卡片的不透明度调成 40」。
      // 原来是 `Theme.tintColor(0.90)`（不透明浅主题色），
      // 太高会把材质盖住；40% 既能立住"这是一张卡"，又透得出底下的玻璃质感。
      .backgroundColor(Theme.alphaOf(this.tpage, 0.40))
      .onClick(() => {
        if (this.nextInfo().kind === 'next') {
          this.backToNow();
        }
      })
    }
  }

  /** 卡主文：`下一节 · 高等数学` / `正在上 · 高等数学` */
  private cardTitle(): string {
    const i = this.nextInfo();
    const head = i.kind === 'now' ? '正在上' : '下一节';
    return `${head} · ${i.name}`;
  }

  /** 卡副文：`10:00 · 教学楼 A203`（没地点就只给时间） */
  private cardSub(): string {
    const i = this.nextInfo();
    const t = Sections.of(i.section);
    const at = t == null ? '' : t.start;
    if (i.location.length === 0) {
      return at;
    }
    return at.length === 0 ? i.location : `${at} · ${i.location}`;
  }

  /** 卡右侧上方小字 */
  private cardRightTop(): string {
    const i = this.nextInfo();
    if (i.kind === 'now') {
      return '距下课';
    }
    if (i.daysAhead === 0) {
      return '距离上课';
    }
    return i.daysAhead === 1 ? '明天' : `周${WD_TEXT[i.weekday]}`;
  }

  /** 卡右侧大数字：今天给分钟数；非今天给开课时间；异常给空串 */
  private cardBigNum(): string {
    const i = this.nextInfo();
    if (i.kind === 'now') {
      return `${i.endLeftMin}`;
    }
    if (i.daysAhead === 0) {
      return i.minutesLeft > 0 ? `${i.minutesLeft}` : '即将';
    }
    const t = Sections.of(i.section);
    return t == null ? '' : t.start;
  }

  /** 卡右侧单位小字 */
  private cardUnit(): string {
    const i = this.nextInfo();
    if (i.kind === 'now' || i.daysAhead === 0) {
      return '分钟';
    }
    return '';
  }

  /**
   * ⛔ **已删除：`hintBar()`（2026-09-28）**
   *
   * 原来是一条独立占位的「下一节课 / 正在预览第 X 周」提示条（浅底 + 圆角卡片）。
   * 用户反馈顶栏三行太占纵向空间，要求压成一行 → 其内容已收进
   * `barContent()` 的中间列（`layoutWeight(1)` + 单行省略号）。
   *
   * 保留这条注释是为了说明**为什么 build() 里不再有它**，
   * 免得下次有人看到"提示信息没地方显示"又新加一条出来。
   *
   * 历史结论（供参考，仍成立）：
   * · 这类辅助信息条**不要用重色实底**（曾用 `this.tacc` 深藏青实底 + 主题色字，
   *   一行 12vp 小字压过整个课表网格，打开 App 第一眼看到的是它而不是课程）。
   * · 官方对辅助信息条的建议是浅底 + 语义色文字，只有真正的警告/错误才允许重色实底。
   * · 「回到本周」是预览态下唯一的重色锚点 —— 现在保留文字色（`this.tc`）不套胶囊底，
   *   因为单行顶栏没有富余空间放一个胶囊。
   */

  /**
   * 星期表头（横随网格滚动、纵向固定）。
   *
   * ## 【2026-09-28】改为「液态玻璃」
   * 用户要求：背景模糊 + 轻微折射、边缘高光随滚动位移、玻璃与文字颜色按下方内容亮度自适应。
   *
   * ### 系统能力边界（查过 SDK 与官方 FAQ，先说清哪些是真做的）
   * | 诉求 | 状态 | 实现 |
   * |---|---|---|
   * | 背景模糊 | ✅ 真实现 | `Mat.liquidGlass()` = `ImmersiveMaterial(ULTRA_THIN)` |
   * | 玻璃/文字按下方亮度自适应 | ✅ **系统原生** | `colorInvert: true`（`Mat.liquidGlass()` 内已开） |
   * | 轻微折射 | ⚠️ **近似** | 系统**未暴露**任何 refract API（SDK 全文搜 `refract` = 0 命中）。用 `ULTRA_THIN` 最薄档 + 主题色 0.10 极低着色模拟"隔着薄玻璃看"的观感 |
   * | 边缘高光随滚动位移 | ⚠️ **近似** | 系统**无**"跟随滚动"的折射高光。这里用「上缘高光线 + 下缘分隔线」做出玻璃板的**边缘高光**观感；它随横向滚动一起位移（因为整条表头在 `Scroll(hScroller)` 内），但**不是**由滚动量驱动的动态折射 |
   *
   * ### ⚠️ `colorInvert` 生效的硬性前提（官方 FAQ 原话）
   * > 自动反色仅对通过**资源接口**设置的颜色值生效……使用代码中**硬编码**的颜色值
   * > （如 `Color.White`、`'#FFFFFFFF'`）**不会触发**自动反色。
   *
   * 所以本函数内所有文字的 `.fontColor()` **必须**用 `$r('app.color.xxx')`，
   * 不能再用 `this.tmain` / `this.tsub` 这类运行时字符串 —— 否则自适应静默失效。
   * 资源色定义在 `resources/base/element/color.json`（`liquid_header_*`），
   * 取值是**深色兜底**：设备不支持反色时正常显示深色字，支持时系统自动转为浅色。
   *
   * ⚠️ 另两个已知限制（官方明示，不是我们的 bug）：
   * · 仅**高/中算力**设备生效，低算力设备上 `style` 与 `colorInvert` 无视觉差异；
   * · 需要**系统沉浸光感开得足够强**才容易触发反色，弱配置下可能不反色。
   */
  @Builder
  headerRow() {
    Row() {
      Column() {
        Text('节次')
          .fontSize(FontSize.captionM)
          .fontColor($r('app.color.liquid_header_sub'))
      }
      .width(SEC_W)
      .height(HEADER_H)
      .justifyContent(FlexAlign.Center)

      ForEach(CourseStore.visibleWeekdays(), (wd: number) => {
        Column() {
          Text(`周${WD_TEXT[wd]}`)
            .fontSize(FontSize.captionL)
            .fontWeight(this.isToday(wd) ? Weight.bold : Weight.medium)
            // 今天用强调资源色（同样走 $r，才能参与自动反色）
            .fontColor(this.isToday(wd)
              ? $r('app.color.liquid_header_accent')
              : $r('app.color.liquid_header_text'))
          Text(this.headerSub(wd))
            .fontSize(FontSize.captionM)
            // 停课日用警告色（硬编码红已移除，改用强调资源色，避免破坏反色链路）
            .fontColor(this.isHolidayCol(wd)
              ? $r('app.color.liquid_header_accent')
              : (this.isToday(wd)
                ? $r('app.color.liquid_header_accent')
                : $r('app.color.liquid_header_sub')))
            .margin({ top: Space.textGap })
        }
        .width(this.colW())
        .height(HEADER_H)
        .justifyContent(FlexAlign.Center)
      }, (wd: number) => `hd-${wd}-${this.rev}`)
    }
    .width(this.gridW())
    .height(HEADER_H)
    // ==========================================================================
    // 【2026-09-28 结构修正 · 表头改为随内容滚动（不吸顶）】
    //
    // ## 为什么放弃了吸顶
    // 原结构里表头在纵向 Scroll **之外**，它天然不动 —— 但代价是
    // **往上滑只到表头就停**（用户反馈「只会到节次那里」）。
    // 把表头移进纵向滚动容器后，就**必须**显式吸顶才能维持原来的行为。
    //
    // 但 **ArkUI 的 `Scroll` 没有 `sticky` 属性**（只有 `List` 有），
    // 而表头又在「纵向 Scroll → 横向 Scroll」两层嵌套里：
    // · 吸顶要靠**纵向**层级控制
    // · 与网格同步横滑要靠**横向**层级控制
    // 两个需求分别落在不同层级，`Scroll` 嵌套下无法同时满足。
    //
    // ## 用户决定（2026-09-28 20:42）：走方案① —— 表头不吸顶
    // 理由是「先验证玻璃到底透不透」：如果透，再花力气做吸顶；
    // 如果不透，说明根本不是布局问题，做吸顶就是白费。
    //
    // 后续若要吸顶，两条已知路径（都未实施）：
    // · 方案②：表头独立成浮层，监听 `hScroller.currentOffset()` 手工同步横移
    //          （两套 Scroll 手工同步，滑动抖动/边界差帧需真机调）
    // · 方案③：纵向容器改用 `List` + `ListItemGroup.sticky`
    //          （但课表的跨行课程块靠 Stack 绝对定位绘制，搬进 List 要重做布局）
    // ==========================================================================
    // ---- 液态玻璃本体 ----
    // 保留 backgroundColor 当降级底：材质不生效时它是唯一底色（见 Material.ets 铁律）。
    // ⚠️ 2026-09-28 修正：原为 0.35 —— 那是拿"材质可能不生效"当默认假设写的。
    //   实测日志 `uiMaterial: supported=TRUE` 已确认材质生效，此时这层底反而成了
    //   一层奶膜，把玻璃的通透感糊掉（用户报「完全没有玻璃效果」）。
    //   降到 0.08：材质生效时它几乎不可见；万一材质失效，也仍有极淡的底托住文字。
    .backgroundColor(Theme.alphaOf(this.tpage, 0.08))
    .systemMaterial(Mat.liquidGlass())
    // ---- 边缘高光（模拟玻璃板的上下缘）----
    // 上缘一条近白的高光线 = 玻璃"受光面"；下缘一条细线 = 玻璃"切边"。
    // 两者合起来给平面 Row 造出"这是一块有厚度的板"的错觉（即"轻微折射"的观感来源）。
    .border({
      width: { top: 1, bottom: Size.divider },
      color: {
        top: Theme.glassHighlight(),
        bottom: Theme.mix(this.tsoft, '#000000', 0.12),
      },
    })
  }

  /**
   * 周次胶囊条（原「调时间控件」从下方上移到此）：可左右滑动看各周，点一下即跳到该周。
   * 每格显示该周「几门课」—— 1-8 周与 9-16 周课程数量不同会直接看出来。
   */
  @Builder
  weekStrip() {
    Row() {
      Text('\u2039')
        .fontSize(FontSize.titleS)
        .fontColor(this.barWeek() > 1 ? this.tmain : Theme.neutral())
        .width(Size.touchTarget)
        .height(Size.touchTarget)
        .textAlign(TextAlign.Center)
        .borderRadius(Radius.full)
        .backgroundColor(Theme.innerBase())
        .systemMaterial(Mat.tile())
        .onClick(() => {
          this.gotoWeek(this.barWeek() - 1);
        })

      List({ space: Space.xsPlus, scroller: this.weekScroller }) {
        ForEach(this.weekList(), (w: number) => {
          ListItem() {
            Column() {
              Text(`第${w}周`)
                .fontSize(FontSize.captionL)
                .fontWeight(w === this.barWeek() ? Weight.bold : Weight.regular)
                .fontColor(w === this.barWeek() ? Color.White : this.tmain)
              Text(`${CourseStore.activeCountInWeek(w)}门`)
                .fontSize(FontSize.captionM)
                .fontColor(w === this.barWeek() ? '#FFFFFFCC' : this.tsub)
                .margin({ top: Space.textGap })
            }
            .width(56)
            .height(40)
            .justifyContent(FlexAlign.Center)
            .borderRadius(Radius.m)
            .backgroundColor(w === this.barWeek() ? this.tc : Theme.innerColor())
            .systemMaterial(w === this.barWeek() ? undefined : Mat.tile())
            .border(w === this.realWeek() && w !== this.barWeek()
              ? { width: 1.5, color: this.tacc }
              : { width: 0 })
            .onClick(() => {
              this.gotoWeek(w);
              this.showWeekStrip = false;   // 选完周自动收起
              this.rev += 1;
            })
          }
        }, (w: number) => `ws-${w}-${this.barWeek()}-${this.rev}`)
      }
      .listDirection(Axis.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .height(Size.touchTarget)

      Text('\u203a')
        .fontSize(FontSize.titleS)
        .fontColor(this.barWeek() < this.weekCount() ? this.tmain : Theme.neutral())
        .width(Size.touchTarget)
        .height(Size.touchTarget)
        .textAlign(TextAlign.Center)
        .borderRadius(Radius.full)
        .backgroundColor(Theme.innerBase())
        .systemMaterial(Mat.tile())
        .onClick(() => {
          this.gotoWeek(this.barWeek() + 1);
        })
    }
    .width('100%')
    .padding({ left: Space.s, right: Space.s, top: Space.xsPlus, bottom: Space.xsPlus })
    // 【2026-09-28 结构修正】原为 `Color.White` 实色 —— 它移进纵向滚动容器后
    // 会随内容滚动，实色白条滚过顶栏下方时会透出一块死白。
    // 改成「极淡降级底 + 材质」，与表头同一套观感。
    .backgroundColor(Theme.cardBase())
    .systemMaterial(Mat.liquidGlass())
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 周选择器：一格一周，显示该周「几门课」——
   * 这样 1-8 周与 9-16 周课程数量不同会直接看出来，点一下即跳过去。
   */
  @Builder
  weekPickPanel() {
    Column() {
      Column() {
        Row() {
          Text('跳转到第几周')
            .fontSize(FontSize.subtitleM)
            .fontWeight(Weight.bold)
            .fontColor(this.tmain)
            .layoutWeight(1)
          Text('关闭')
            .fontSize(FontSize.subtitleS)
            .fontWeight(Weight.medium)
            .fontColor(this.tsub)
            .constraintSize({ minHeight: Size.touchTarget })
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.showWeekPick = false;
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text('不同课的上课周期不同（如 1-8 周 / 9-16 周），翻到那一周就能提前看到当时的课表。')
          .fontSize(FontSize.bodyS)
          .fontColor(this.tsub)
          .width('100%')
          .margin({ top: Space.xs })

        Grid() {
          ForEach(this.weekList(), (w: number) => {
            GridItem() {
              Column() {
                Text(`第${w}周`)
                  .fontSize(FontSize.cellTitle)
                  .fontWeight(w === this.barWeek() ? Weight.bold : Weight.regular)
                  .fontColor(w === this.barWeek() ? Color.White : this.tmain)
                Text(`${CourseStore.activeCountInWeek(w)} 门`)
                  .fontSize(FontSize.captionM)
                  // 【2026-09-28】原为硬编码 '#FFEDD5'（橙系浅色）→ 换主题色会串色。
                  // 改用主题色与白的混色，保证在任何色系下都是"主色上的浅色副文"。
                  .fontColor(w === this.barWeek() ? Theme.mix(this.tc, '#FFFFFF', 0.75) : this.tsub)
                  .margin({ top: Space.textGap })
              }
              .width('100%')
              .height(50)
              .justifyContent(FlexAlign.Center)
              .borderRadius(Radius.m)
              .backgroundColor(w === this.barWeek() ? this.tc : Theme.innerColor())
              .border(w === this.realWeek() && w !== this.barWeek()
                ? { width: 1, color: this.tacc }
                : { width: 0 })
              .onClick(() => {
                this.gotoWeek(w);
                this.showWeekPick = false;
              })
            }
          }, (w: number) => `wk-${w}-${this.rev}`)
        }
        .columnsTemplate('1fr 1fr 1fr 1fr')
        // 【2026-09-28 用户反馈「这几个块都连在一起」】
        // 间距从 Space.s(8) 提到 Space.m(12)：8vp 在深色底上几乎看不出缝。
        .columnsGap(Space.m)
        .rowsGap(Space.m)
        // ⚠️ 原为写死 `.height(300)` —— 一旦「行数×50 + 间距」超过 300，
        //    Grid 会压缩 GridItem，把 12vp 的行间距吃掉 → 又粘成一片。
        //    改用 minHeight：让 Grid 按内容自然撑高，间距才不会被吞。
        .constraintSize({ minHeight: 300 })
        .width('100%')
        .margin({ top: Space.l })

        Row() {
          Text(this.isPreview() ? '回到本周' : '关闭')
            .fontSize(FontSize.subtitleM)
            .fontWeight(Weight.medium)
            .fontColor(Color.White)
            .padding({ left: Space.xxxl, right: Space.xxxl, top: Space.xs, bottom: Space.xs })
            .borderRadius(Radius.full)
            .backgroundColor(this.tc)
            .systemMaterial(Mat.button())
            .textAlign(TextAlign.Center)
            .onClick(() => {
              if (this.isPreview()) {
                this.backToNow();
              } else {
                this.showWeekPick = false;
              }
            })
        }
        .width('100%')
        .margin({ top: Space.l })
        .justifyContent(FlexAlign.Center)
      }
      .width('88%')
      .padding(Space.xl)
      .borderRadius(Radius.xl)
      .backgroundColor(Theme.alphaOf(this.tpage, 0.92))
      .systemMaterial(Mat.sheet())
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#00000055')
    .transition(Motion.fadeIn())
    .onClick(() => {
      this.showWeekPick = false;
    })
  }

  /**
   * 网格主体。
   *
   * 结构：Row[ 节次列 | 每天一列 ]，列内按单元依次堆叠。
   * 参考线就是「每个单元的底边虚线」，所以：
   * - 节次列的每一行高 = 一整格 → 上下端必然落在参考线上；
   * - 课程块在单元内四周内缩（上下各 6vp）→ 相邻两块之间天然有 12vp 缝隙；
   * - 一门课跨多个大节时中间没有单元 → 那几条参考线根本不存在，不会透过浅色块显出来。
   */
  @Builder
  gridBody() {
    Stack() {
      // 当前节次整行高亮（铺最底层，不遮课程块、不拦手势）
      if (this.currentSecOfToday() > 0) {
        Row()
          .width('100%')
          .height(this.cellHeight())
          .backgroundColor('#33FFD8A8')
          .position({ x: 0, y: (this.currentSecOfToday() - 1) * this.cellHeight() })
          .hitTestBehavior(HitTestMode.None)
      }

      Row() {
        // ---- 左侧节次列：每行整行高，与参考线严格对齐 ----
        Column() {
          ForEach(Sections.SLOTS.slice(0, this.showSections()), (s: SectionSlot) => {
            Column() {
              Text(s.no.toString())
                .fontSize(FontSize.captionL)
                .fontWeight(this.isCurrentSection(s.no) ? Weight.bold : Weight.medium)
                .fontColor(this.isCurrentSection(s.no) ? this.tacc : this.tmain)
              Text(`${s.start}-${s.end}`)
                .fontSize(FontSize.captionM)
                .fontColor(this.isCurrentSection(s.no) ? this.tacc : this.tsub)
                .margin({ top: Space.textGap })
            }
            .width('100%')
            .height(this.cellHeight())
            .justifyContent(FlexAlign.Center)
            .backgroundColor(this.isCurrentSection(s.no) ? Theme.tintSoft() : Theme.innerColor())
            .border({
              width: { bottom: CourseStore.semester.showGrid ? Size.divider : 0 },
              color: GRID_LINE,
              style: BorderStyle.Dashed,
            })
          }, (s: SectionSlot) => `sec-${s.no}-${this.rev}`)
        }
        .width(SEC_W)

        // ---- 每天一列：列左边界一条竖参考线（课程块左右各内缩 6vp，不会压住它）----
        ForEach(CourseStore.visibleWeekdays(), (wd: number) => {
          Column() {
            ForEach(this.columnCells(wd), (cell: Cell) => {
              // 单元：高 = 跨度 × 行高，底边虚线 = 行界线（课程块在其内部内缩）
              Column() {
                if (cell.course != null) {
                  // ================================================================
                  // 【2026-09-28 第二十二次修正 · 课程块「玻璃高光 + 色带 + 投影」】
                  //
                  // ## 用户要求（原话）
                  // > 「课表页要保持配色区分，不同课程要有不同的颜色」
                  // > 「课程块太素，要更好看」
                  // > 选定方向：**加玻璃高光 + 加色带标识 + 加投影悬浮**（不加渐变）
                  //
                  // ## 为什么原来"素"
                  // 改动前就是「一个 Column + backgroundColor(bg) + 1px 细描边」——
                  // 单层平色，没有任何受光面或深度信号，读起来就是一块贴纸。
                  //
                  // ## 改法：单层 → Stack 三层
                  // 块体（底：圆角 + 块色 + 描边 + 投影）→ 高光（受光面）→ 色带（分类标识）
                  //
                  // ⚠️ **Stack 的子节点"后写的在上面"**，顺序不能乱：
                  //    块体必须第一（最底），否则高光/色带会被内容盖掉。
                  // ⚠️ 高光层与色带层都必须 `hitTestBehavior(HitTestMode.None)`，
                  //    否则会截住点击 → 课程块点不开详情（自绘 View 的老坑）。
                  // ================================================================
                  Stack({ alignContent: Alignment.TopStart }) {
                    // ---- 层 1（最底）：块体 + 内容 ----
                    Column() {
                      // 每行一个元素，按槽位顺序自上而下排布（不会再挤在同一行）
                      ForEach(this.cellRows(cell.course!, cell.span), (row: string) => {
                        Text(this.rowText(row))
                          .fontSize(this.rowFont(row, cell.course!.name, cell.span))
                          .fontWeight(this.rowBold(row) ? Weight.bold : Weight.regular)
                          .fontColor(this.fgOf(cell.course!))
                          .opacity(this.rowBold(row) ? 1 : 0.9)
                          .maxLines(this.rowBold(row)
                            ? this.nameLines(this.nameFont(cell.course!.name, cell.span), cell.span)
                            : 1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .width('100%')
                          .textAlign(this.rowAlign(row))
                      }, (row: string, idx: number) => `cr-${idx}-${row}-${this.rev}`)
                    }
                    .justifyContent(FlexAlign.Center)
                    .width('100%')
                    .height('100%')
                    // 左侧多留 3vp：给色带让位，文字不要压上去
                    .padding({ left: Space.m, right: Space.xs, top: Space.xs, bottom: Space.xs })
                    .borderRadius(this.radiusFor(cell.span))
                    .backgroundColor(CourseStore.colorOf(cell.course!).bg)
                    .border(this.isOngoing(cell.course!)
                      ? { width: 2, color: this.tacc }
                      : { width: 1, color: CourseStore.colorOf(cell.course!).bar })
                    // ---- 投影（悬浮感的物理来源）----
                    // 正在上课的块加重投影，进一步强调"这一块是当下的焦点"。
                    .shadow({
                      radius: this.isOngoing(cell.course!) ? 12 : 6,
                      color: Theme.alphaOf('#000000', this.isOngoing(cell.course!) ? 0.16 : 0.09),
                      offsetX: 0,
                      offsetY: this.isOngoing(cell.course!) ? 4 : 2,
                    })

                    // ---- 层 2：玻璃高光（受光面，铺满整块）----
                    // 顶部近白 → 中段完全透明：模拟"光从上方打下来"。
                    // 与顶栏胶囊共用 `Theme.glassHighlight()`，保持同一套玻璃语言。
                    Column()
                      .width('100%')
                      .height('100%')
                      .borderRadius(this.radiusFor(cell.span))
                      .linearGradient({
                        angle: 160,   // 略斜，比 180 纯正面更自然（折射感）
                        colors: [
                          [Theme.alphaOf(Theme.glassHighlight(), 0.50), 0.0],
                          [Theme.alphaOf(Theme.glassHighlight(), 0.0), 0.55],
                        ],
                      })
                      .hitTestBehavior(HitTestMode.None)

                    // ---- 层 3（最上）：左侧色带（课程分类标识）----
                    // 用 `bar`（该课程的强调色）而不是 `fg`（深文字色）——
                    // `bar` 与块底同色相但更饱和，读起来是"色标"而不是"一道黑边"。
                    //
                    // 【2026-09-28 第二十三次修正 · 色带超出格子范围的 bug】
                    //   用户反馈：「你新加的左边的那一条竖线有点太长了，已经超出格子的范围。」
                    //   —— 判断完全正确，是我的错。
                    //
                    //   根因：`.height('100%')` 在 Stack 里解析为**Stack 自身高度**，
                    //   而我同时又给了 `.margin({ top: Space.s, bottom: Space.s })`。
                    //   ArkUI 里 margin 是**加在尺寸之外**的 → 实际占位 = 100% + 16vp，
                    //   色带必然溢出 Stack 上下各 8vp，看起来"戳出格子"。
                    //
                    //   修法：改用**确定值** `高度 - 上下 margin`，与块体高度严格一致。
                    //   （与课表页 `barCapsule` 的"薄雾层必须给确定高度"是同一个坑。）
                    Column()
                      .width(3)
                      .height(cell.span * this.cellHeight() - GAP_HALF * 2 - Space.s * 2)
                      .borderRadius(Radius.full)
                      .backgroundColor(CourseStore.colorOf(cell.course!).bar)
                      .margin({ left: Space.xs, top: Space.s, bottom: Space.s })
                      .hitTestBehavior(HitTestMode.None)
                  }
                  .width(`calc(100% - ${CELL_H_GAP * 2}vp)`)
                  .height(cell.span * this.cellHeight() - GAP_HALF * 2)
                  .margin({ top: GAP_HALF })
                  .opacity((CourseStore.activeInWeek(cell.course!, this.shownWeek()) ? 1 : 0.45) * this.blockAlpha())
                  .onClick(() => {
                    this.showDetail(cell.course!);
                  })
                }
              }
              .width('100%')
              .height(cell.span * this.cellHeight())
              .alignItems(HorizontalAlign.Center)
              .border({
                width: { bottom: CourseStore.semester.showGrid ? Size.divider : 0 },
                color: GRID_LINE,
                style: BorderStyle.Dashed,
              })
            }, (cell: Cell) => `cell-${wd}-${cell.start}-${this.rev}`)
          }
          .width(this.colW())
          .border({
            width: { left: CourseStore.semester.showGrid ? Size.divider : 0 },
            color: GRID_LINE,
            style: BorderStyle.Dashed,
          })
          .backgroundColor(this.isHolidayCol(wd)
            ? '#14000000'
            : (this.isToday(wd) ? Theme.mix(this.tsoft, '#FFFFFF', 0.55) : Color.Transparent))
        }, (wd: number) => `col-${wd}-${this.rev}`)
      }
      .width(this.gridW())
      .alignItems(VerticalAlign.Top)
    }
    .width(this.gridW())
    .height(this.gridHeight())
    .align(Alignment.TopStart)
  }

  @Builder
  emptyTip() {
    Column() {
      // 空状态插图：日历网格 + 幼苗（透明底 PNG，随主题色卡片自然融合）
      Image($r('app.media.ill_empty_course'))
        .width(Size.emptyIll)
        .height(Size.emptyIll)
        .objectFit(ImageFit.Contain)
        .margin({ bottom: Space.l })
      Text('还没有课表')
        .fontSize(FontSize.subtitleM)
        .fontWeight(Weight.bold)
        .fontColor(this.tmain)
      Text('点右上角「导入」打开教务课表页抓取，\n或先在「设置」里填好开课日。')
        .fontSize(FontSize.bodyM)
        .fontColor(this.tsub)
        .textAlign(TextAlign.Center)
        .margin({ top: Space.s })
      Text('去导入课表')
        .fontSize(FontSize.subtitleM)
        .fontWeight(Weight.medium)
        .fontColor(Color.White)
        .padding({ left: Space.xxl, right: Space.xxl, top: Space.xs, bottom: Space.xs })
        .borderRadius(Radius.full)
        .backgroundColor(this.tc)
        .systemMaterial(Mat.button())
        .margin({ top: Space.xl })
        .textAlign(TextAlign.Center)
        .onClick(() => {
          router.pushUrl({ url: 'pages/ImportSchedule' });
        })
    }
    .width('100%')
    .padding({ top: Space.huge + Space.xxl, bottom: Space.huge })
    .padding({ left: Layout.screenMargin(), right: Layout.screenMargin() })
    .justifyContent(FlexAlign.Center)
  }

  build() {
    // ==========================================================================
    // 【2026-09-28 第六次结构修正 · 用户指出"容器没铺满"】
    //
    // ## 用户原话
    // > 「我怀疑往上滑课表根本不会滑到最顶端，而是只会到节次那里。
    // >   换句话说，你的容器没有铺满，你只是画了一个部分页面的容器。」
    //
    // ## 他说对了。原结构是「三块拼起来的分区布局」：
    // ```
    // Column {                    ← 分区，不是铺满
    //   barContent()              ← 占一块，自己画不透明背景 backgroundColor(tpage)
    //   weekStrip()（可选）        ← 又占一块
    //   Scroll(横向)              ← 剩下的（layoutWeight 1）
    //     └ Column
    //        ├ headerRow()        ← 表头在这，纵向 Scroll 之【外】
    //        └ Scroll(纵向)       ← 只有这块能上下滚
    // ```
    // **两处致命伤**：
    // ① 顶栏是内容的**兄弟**而非浮层 → 内容永远不会经过它下方
    //    → 顶栏的材质「没东西可透」，跟不做材质观感一样。
    // ② 表头在纵向 Scroll **之外** → 往上滑只到表头就撞墙（用户描述的现象）。
    //
    // ## 改法：顶栏浮层 + 单一纵向 Scroll（表头随内容滚动，不吸顶）
    // 用 Stack：底层是**整页唯一的纵向滚动容器**（内容从顶栏下方经过），
    // 顶栏用 align(Alignment.TopStart) 浮在最上面。
    // 这样顶栏玻璃真的能透出滚过的课程块 —— 这才是沉浸光感的成立前提。
    //
    // ## 表头吸顶：本轮**不做**（用户 2026-09-28 20:42 决定走方案①）
    // 原因见 `headerRow()` 上方注释（`Scroll` 无 sticky + 两层嵌套层级冲突）。
    // 先验证"玻璃到底透不透"，再决定要不要花力气做吸顶。
    // ==========================================================================
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        if (this.courses.length === 0) {
          Scroll() {
            this.emptyTip()
          }
          .layoutWeight(1)
        } else {
          // ★ 唯一的纵向滚动容器。**周次条、表头、网格全在里面** ——
          //   weekStrip 原来在滚动容器外（占一块固定高度），移进来说明见下方注释。
          //   ⚠️ 顶部留出顶栏高度：内容从顶栏下方经过（顶栏是浮层，要先被让出位置，
          //      否则第一行会被顶栏永久盖住）。用透明占位而不是 padding，
          //      这样滚到底时网格仍能延伸到悬浮胶囊后方（不破坏方案B的透光）。
          Scroll(this.vScroller) {
            Column() {
              // 表头之上先垫一块顶栏高的透明占位（浮层需要的位置）
              Blank().height(this.barTotalH())
              // ---- 周次胶囊条（按需展开）----
              // 【2026-09-28 修正】原在滚动容器**外** → 展开时会顶掉内容高度，
              //   且浮层顶栏会盖住它。移进滚动容器后随内容一起滚，位置关系才正确。
              if (this.showWeekStrip) {
                this.weekStrip()
              }
              // 横向滚动容器：表头与网格都在它里面 → 左右滑时列对齐同步
              Scroll(this.hScroller) {
                Column() {
                  this.headerRow()
                  this.gridBody()
                }
                .width(this.gridW())
              }
              .scrollable(ScrollDirection.Horizontal)
              .scrollBar(BarState.Off)
              .width('100%')
              // ⚠️ 必须给高度：横向 Scroll 放进纵向 Scroll 后不再有 layoutWeight 撑开，
              //    高度取「表头 + 网格」的确定值，否则会被压成 0（整片空白）。
              .height(HEADER_H + this.gridHeight())

              Blank().height(Size.barClearanceMin)
            }
            .width('100%')
          }
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
          .layoutWeight(1)
          .width('100%')
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.scheduleBgColor())

      // 顶栏浮层：浮在滚动内容之上，材质才有东西可透
      this.barContent()

      if (this.showWeekPick) {
        this.weekPickPanel()
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 悬浮顶栏胶囊的**总占位高度** —— 滚动内容需要让出的顶部空间。
   *
   * 【2026-09-28 第七次修正】顶栏改成悬浮胶囊后，高度构成变了：
   * · `WindowInsets.statusBarVp()` 状态栏
   * · `Space.s` 胶囊上方的留白
   * · 胶囊本体高 —— 内容高 `Size.touchTarget`(48) + 上下 `Space.s`(8×2) padding
   * · `Space.s` 胶囊下方的留白
   *
   * ⚠️ 必须**精确**给出：少算 → 第一行课被胶囊盖住；
   *    多算 → 顶部凭空多一段空白（用户对空白很敏感）。
   * 这也是我把「胶囊内 padding」写成和 `Space.s` 同值的原因 —— 便于这里对账。
   */
  private barTotalH(): number {
    // 【2026-09-28 第十五次修正】下侧余量 Space.s → Space.l，与听课/设置页统一。
    return WindowInsets.statusBarVp() + Space.s + (Size.touchTarget + Space.s * 2) + Space.l;
  }

  /**
   * 胶囊**内高** —— 即胶囊本体减去上下 padding 之后，留给内容行的高度。
   *
   * 用途：`barCapsule()` 里那层"薄雾"的 `Column` 需要一个**确定高度**
   * （不能写 `height('100%')`，理由见该方法内的注释）。
   * 这里把「内容行高(`Size.touchTarget`) + 上下 padding(`Space.s` × 2)」算出来，
   * 与内容 `Row` 的 `padding({ top: Space.s, bottom: Space.s })` 保持一致。
   *
   * ⚠️ 这条公式与 `barCapsule()` 的 padding **必须同步改**：
   *    改一处的 padding 就要回来改这里，否则薄雾层会高出/矮于胶囊。
   */
  private capsuleHostH(): number {
    return Size.touchTarget + Space.s * 2;
  }
}
