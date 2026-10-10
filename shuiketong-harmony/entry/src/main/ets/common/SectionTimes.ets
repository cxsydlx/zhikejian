/**
 * 作息时间表 —— 石家庄铁道大学（按用户提供的实际时间录入）。
 *
 * 共 14 节：
 *   上午 1-5 节（08:00-12:15）
 *   下午 6-10 节（14:00-18:15）
 *   晚上 11-14 节（19:00-22:15）
 * 每节 45 分钟；同一大节内两小节间隔 5 分钟，大节之间间隔 15 分钟；
 * 中午午休至 14:00，晚上 19:00 开始（对应学校的“晚上 11 节”）。
 */
export class SectionSlot {
  no: number = 0;      // 节次序号
  start: string = '';  // 开始时间 HH:mm
  end: string = '';    // 结束时间 HH:mm
  period: string = ''; // 上午 | 下午 | 晚上

  constructor(no: number, start: string, end: string, period: string) {
    this.no = no;
    this.start = start;
    this.end = end;
    this.period = period;
  }
}

export class Sections {
  static readonly TOTAL: number = 14;

  static readonly SLOTS: SectionSlot[] = [
    new SectionSlot(1, '08:00', '08:45', '上午'),
    new SectionSlot(2, '08:50', '09:35', '上午'),
    new SectionSlot(3, '09:50', '10:35', '上午'),
    new SectionSlot(4, '10:40', '11:25', '上午'),
    new SectionSlot(5, '11:30', '12:15', '上午'),
    new SectionSlot(6, '14:00', '14:45', '下午'),
    new SectionSlot(7, '14:50', '15:35', '下午'),
    new SectionSlot(8, '15:50', '16:35', '下午'),
    new SectionSlot(9, '16:40', '17:25', '下午'),
    new SectionSlot(10, '17:30', '18:15', '下午'),
    new SectionSlot(11, '19:00', '19:45', '晚上'),
    new SectionSlot(12, '19:50', '20:35', '晚上'),
    new SectionSlot(13, '20:40', '21:25', '晚上'),
    new SectionSlot(14, '21:30', '22:15', '晚上'),
  ];

  static of(no: number): SectionSlot | null {
    for (const s of Sections.SLOTS) {
      if (s.no === no) {
        return s;
      }
    }
    return null;
  }

  /** "08:00-09:35"（取起始节的开始时间到结束节的结束时间） */
  static spanText(start: number, end: number): string {
    const a = Sections.of(start);
    const b = Sections.of(end);
    if (a == null || b == null) {
      return '';
    }
    return `${a.start}-${b.end}`;
  }

  /** "第3节" 或 "1-2节" */
  static rangeText(start: number, end: number): string {
    return start === end ? `第${start}节` : `${start}-${end}节`;
  }

  /** 上午/下午/晚上 */
  static periodOf(no: number): string {
    const s = Sections.of(no);
    return s == null ? '' : s.period;
  }

  /** "08:00" -> 480（当天分钟数）；格式不对返回 -1 */
  static toMin(hhmm: string): number {
    const p = hhmm.split(':');
    if (p.length < 2) {
      return -1;
    }
    return parseInt(p[0], 10) * 60 + parseInt(p[1], 10);
  }

  /**
   * 第 no 节之后是否是大节分界 —— 两节间隔 ≥ 15 分钟（大课间 / 午休 / 晚休）。
   * 课表据此把「同一门课连排的多个大节」断开显示：
   * 大节之间必须有空隙，不能糊成一整块。
   */
  static isBreakAfter(no: number): boolean {
    const a = Sections.of(no);
    const b = Sections.of(no + 1);
    if (a == null || b == null) {
      return false;
    }
    return Sections.toMin(b.start) - Sections.toMin(a.end) >= 15;
  }
}
