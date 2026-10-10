import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { CourseStore, CourseItem } from '../common/CourseStore';
import { Sections } from '../common/SectionTimes';
import { Theme } from '../common/Theme';

const WD_FULL: string[] = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];
const BYDAY: string[] = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

/**
 * 课表导出。
 *
 * 支持四种格式，覆盖不同用途：
 *  · json —— 与本地落盘同口径，用于备份 / 迁移 / 二次加工
 *  · csv  —— 表格软件可打开，方便打印或统计（新格式，已验证）
 *  · ics  —— 标准日历格式，导入系统日历后每节课变成重复日程
 *  · png  —— 课表缩略图（色块版，不依赖字库；要带课程名的图请用系统截屏）
 *
 * 落盘统一用 `picker.DocumentViewPicker`（系统「保存」对话框），由用户自己选目录，
 * 不需要申请受限的存储权限。**不主动创建目录** —— 系统 picker 会在保存时创建，
 * 自建目录在部分机型上会抛 13900001。
 *
 * 注：方法均为 static，用「类名.方法」调用，不用 `this.`（避免 ArkTS 的 this 绑定告警）。
 */
export class ScheduleExportService {

  /** 统一入口：按 kind 导出（kind = json | csv | ics | png） */
  static async export(kind: string): Promise<string> {
    if (kind === 'json') {
      return await ScheduleExportService.exportJson();
    }
    if (kind === 'csv') {
      return await ScheduleExportService.exportCsv();
    }
    if (kind === 'ics') {
      return await ScheduleExportService.exportIcs();
    }
    if (kind === 'png') {
      return await ScheduleExportService.exportPng();
    }
    return '不支持的导出格式';
  }

  /**
   * 弹系统「保存」对话框并写入。
   * @returns 保存成功返回 uri，取消返回 ''
   */
  private static async saveFile(name: string, data: string | ArrayBuffer): Promise<string> {
    const p = new picker.DocumentViewPicker();
    const opt = new picker.DocumentSaveOptions();
    opt.newFileNames = [name];
    const uris = await p.save(opt);
    if (uris == null || uris.length === 0) {
      return '';
    }
    const file = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, data);
    } finally {
      fs.closeSync(file);
    }
    return uris[0];
  }

  private static stamp(): string {
    const d = new Date();
    const mm = (d.getMonth() + 1).toString().padStart(2, '0');
    const dd = d.getDate().toString().padStart(2, '0');
    const hh = d.getHours().toString().padStart(2, '0');
    const mi = d.getMinutes().toString().padStart(2, '0');
    return `${mm}${dd}-${hh}${mi}`;
  }

  private static baseName(): string {
    const n = CourseStore.semester.name;
    return n.length > 0 ? n : '我的课表';
  }

  // ---------- JSON ----------

  private static async exportJson(): Promise<string> {
    const arr: Array<Record<string, Object>> = [];
    for (const c of CourseStore.sortedCourses()) {
      const o: Record<string, Object> = {
        'name': c.name,
        'weekday': c.weekday,
        'weekdayText': WD_FULL[c.weekday],
        'startSection': c.startSection,
        'endSection': c.endSection,
        'startTime': ScheduleExportService.timeOf(c.startSection, false),
        'endTime': ScheduleExportService.timeOf(c.endSection, true),
        'weeks': c.weeks,
        'weekText': c.weekText,
        'location': c.location,
        'teacher': c.teacher,
        'campus': c.campus,
      };
      arr.push(o);
    }
    const s = CourseStore.semester;
    const root: Record<string, Object> = {
      'app': '知课笺',
      'exportedAt': new Date().toISOString(),
      'name': s.name,
      'title': s.title,
      'openDate': s.openDate,
      'totalWeeks': s.totalWeeks,
      'holidays': s.holidays,
      'courseCount': arr.length,
      'courses': arr,
    };
    const name = `知课笺-${ScheduleExportService.baseName()}-${ScheduleExportService.stamp()}.json`;
    const uri = await ScheduleExportService.saveFile(name, JSON.stringify(root, null, 2));
    return uri.length > 0 ? `已导出：${name}` : '已取消';
  }

  // ---------- CSV ----------

  private static async exportCsv(): Promise<string> {
    const lines: string[] = [];
    lines.push('课程名,星期,开始节次,结束节次,开始时间,结束时间,周次,教室,教师,校区');
    for (const c of CourseStore.sortedCourses()) {
      const cols: string[] = [
        c.name,
        WD_FULL[c.weekday],
        `${c.startSection}`,
        `${c.endSection}`,
        ScheduleExportService.timeOf(c.startSection, false),
        ScheduleExportService.timeOf(c.endSection, true),
        c.weekText.length > 0 ? c.weekText : ScheduleExportService.weeksText(c.weeks),
        c.location,
        c.teacher,
        c.campus,
      ];
      const q: string[] = [];
      for (const v of cols) {
        q.push(ScheduleExportService.csvCell(v));
      }
      lines.push(q.join(','));
    }
    // Excel 认 BOM（否则中文乱码）
    const name = `知课笺-${ScheduleExportService.baseName()}-${ScheduleExportService.stamp()}.csv`;
    const uri = await ScheduleExportService.saveFile(name, '\uFEFF' + lines.join('\r\n'));
    return uri.length > 0 ? `已导出：${name}` : '已取消';
  }

  private static csvCell(v: string): string {
    const t = v.length > 0 ? v : '';
    if (t.indexOf(',') >= 0 || t.indexOf('"') >= 0 || t.indexOf('\n') >= 0) {
      return '"' + t.replace(/"/g, '""') + '"';
    }
    return t;
  }

  /** 周次文本：连续段压缩成 1-16 / 1,3,5 形式 */
  private static weeksText(weeks: number[]): string {
    if (weeks.length === 0) {
      return '每周';
    }
    const sorted = weeks.slice();
    sorted.sort((a: number, b: number) => a - b);
    const parts: string[] = [];
    let i = 0;
    while (i < sorted.length) {
      let j = i;
      while (j + 1 < sorted.length && sorted[j + 1] === sorted[j] + 1) {
        j++;
      }
      parts.push(i === j ? `${sorted[i]}` : `${sorted[i]}-${sorted[j]}`);
      i = j + 1;
    }
    return parts.join(',') + '周';
  }

  /** 第 section 节的开始/结束时间（HH:mm） */
  private static timeOf(section: number, isEnd: boolean): string {
    const s = Sections.of(section);
    if (s == null) {
      return '';
    }
    return isEnd ? s.end : s.start;
  }

  /** "08:00" -> "080000"（ICS 的本地时间格式） */
  private static hms(t: string): string {
    const p = t.split(':');
    if (p.length < 2) {
      return '000000';
    }
    return `${p[0].padStart(2, '0')}${p[1].padStart(2, '0')}00`;
  }

  private static range(a: number, b: number): number[] {
    const out: number[] = [];
    for (let i = a; i <= b; i++) {
      out.push(i);
    }
    return out;
  }

  private static maxWeek(weeks: number[]): number {
    let m = 1;
    for (const w of weeks) {
      if (w > m) {
        m = w;
      }
    }
    return m;
  }

  // ---------- ICS ----------

  /**
   * 生成 iCalendar（.ics）。
   *
   * 每节课一个 VEVENT：
   *  · DTSTART 取该课**第一次真正上课**的日期（开课日 + 周次推算，跳过停课日），
   *    算不出日期（没设开课日 / 所有周次都撞停课日）的课直接跳过，不生成无意义日程。
   *  · RRULE 用 WEEKLY + BYDAY 指定星期 + COUNT = 最大周次。
   *    注意这是**近似**：非连续周次（如 1,3,5 周）会多出几天，日历客户端只能做到这一步；
   *    要绝对精确请用 CSV 自行加工。
   *  · 停课日通过 EXDATE 排除（按该课的具体时段）。
   */
  private static async exportIcs(): Promise<string> {
    const s = CourseStore.semester;
    const nowStamp = ScheduleExportService.utcStamp(new Date().getTime());
    const out: string[] = [];
    out.push('BEGIN:VCALENDAR');
    out.push('VERSION:2.0');
    out.push('PRODID:-//ZhikeJian//Schedule//CN');
    out.push('CALSCALE:GREGORIAN');
    out.push('METHOD:PUBLISH');
    out.push(`X-WR-CALNAME:${ScheduleExportService.esc(s.name.length > 0 ? s.name : '我的课表')}`);
    if (s.title.length > 0) {
      out.push(`X-WR-CALDESC:${ScheduleExportService.esc(s.title)}`);
    }

    let seq = 0;
    let skipped = 0;
    for (const c of CourseStore.sortedCourses()) {
      const date = ScheduleExportService.firstOccurrence(c);
      if (date.length === 0) {
        skipped += 1;
        continue;
      }
      seq += 1;
      const byDay = BYDAY[c.weekday - 1];
      const weeks = c.weeks.length > 0
        ? c.weeks : ScheduleExportService.range(1, s.totalWeeks);
      const day = date.replace(/-/g, '');
      out.push('BEGIN:VEVENT');
      out.push(`UID:zkt-${c.weekday}-${c.startSection}-${seq}@zhikejian`);
      out.push(`DTSTAMP:${nowStamp}`);
      out.push(`DTSTART;TZID=Asia/Shanghai:${day}T${ScheduleExportService.hms(
        ScheduleExportService.timeOf(c.startSection, false))}`);
      out.push(`DTEND;TZID=Asia/Shanghai:${day}T${ScheduleExportService.hms(
        ScheduleExportService.timeOf(c.endSection, true))}`);
      out.push(`RRULE:FREQ=WEEKLY;BYDAY=${byDay};COUNT=${ScheduleExportService.maxWeek(weeks)}`);
      const title = c.location.length > 0 ? `${c.name} @ ${c.location}` : c.name;
      out.push(`SUMMARY:${ScheduleExportService.esc(title)}`);
      const desc: string[] = [];
      if (c.teacher.length > 0) {
        desc.push(`教师：${c.teacher}`);
      }
      desc.push(`周次：${c.weekText.length > 0 ? c.weekText : ScheduleExportService.weeksText(weeks)}`);
      desc.push(`节次：第 ${c.startSection}-${c.endSection} 节`);
      if (c.campus.length > 0) {
        desc.push(`校区：${c.campus}`);
      }
      out.push(`DESCRIPTION:${ScheduleExportService.esc(desc.join('\n'))}`);
      if (c.location.length > 0) {
        out.push(`LOCATION:${ScheduleExportService.esc(c.location)}`);
      }
      const ex = ScheduleExportService.exDates(c, weeks);
      if (ex.length > 0) {
        out.push(`EXDATE;TZID=Asia/Shanghai:${ex.join(',')}`);
      }
      out.push('END:VEVENT');
    }

    out.push('END:VCALENDAR');
    const name = `知课笺-${ScheduleExportService.baseName()}-${ScheduleExportService.stamp()}.ics`;
    // ICS 规范要求 CRLF
    const uri = await ScheduleExportService.saveFile(name, out.join('\r\n') + '\r\n');
    if (uri.length === 0) {
      return '已取消';
    }
    return skipped > 0
      ? `已导出：${name}（${skipped} 个课程块因算不出日期被跳过）`
      : `已导出：${name}（可导入系统日历）`;
  }

  /** 该课第一次上课的日期（yyyy-MM-dd）；算不出返回 '' */
  private static firstOccurrence(c: CourseItem): string {
    const weeks = c.weeks.length > 0
      ? c.weeks : ScheduleExportService.range(1, CourseStore.semester.totalWeeks);
    const sorted = weeks.slice();
    sorted.sort((a: number, b: number) => a - b);
    for (const w of sorted) {
      const d = CourseStore.dateOf(w, c.weekday);
      if (d.length > 0 && !CourseStore.isHoliday(d)) {
        return d;
      }
    }
    return '';
  }

  /** 停课日对应的 EXDATE 列表 */
  private static exDates(c: CourseItem, weeks: number[]): string[] {
    const out: string[] = [];
    for (const w of weeks) {
      const d = CourseStore.dateOf(w, c.weekday);
      if (d.length > 0 && CourseStore.isHoliday(d)) {
        out.push(`${d.replace(/-/g, '')}T${ScheduleExportService.hms(
          ScheduleExportService.timeOf(c.startSection, false))}`);
      }
    }
    return out;
  }

  private static utcStamp(ms: number): string {
    const d = new Date(ms);
    const p = (n: number): string => n.toString().padStart(2, '0');
    return `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}T`
      + `${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}Z`;
  }

  private static esc(t: string): string {
    return t.replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,')
      .replace(/\r?\n/g, '\\n');
  }

  // ---------- PNG ----------

  /**
   * 画一张课表缩略图并保存。
   *
   * 用 PixelMap 逐像素绘制（不引三方图表库）：背景 → 网格 → 课程色块 → 图例。
   *
   * **为什么图里没有文字**：内置汉字点阵字库体积大，且 ArkTS 侧没有可直接用的
   * 字模 API。所以这张图输出的是**结构与配色准确**的布局缩略图（色块位置 = 上课时间，
   * 下方图例 = 每块对应的颜色），用于快速分享 / 存档预览。
   * 需要"带完整课程名的课表图片"，请用系统截屏。
   */
  private static async exportPng(): Promise<string> {
    const s = CourseStore.semester;
    const cols = CourseStore.visibleWeekdays();
    const rows = Math.max(1, Math.min(s.sectionsToShow, Sections.TOTAL));
    const cellW = 96;
    const cellH = 56;
    const leftW = 56;
    const topH = 44;
    const pad = 16;
    const legendRows = Math.ceil(CourseStore.courses.length / 3);
    const legendH = 20 + legendRows * 20;
    const w = leftW + cols.length * cellW + pad * 2;
    const h = topH + rows * cellH + legendH + pad * 2;

    const buf = new Uint8Array(w * h * 4);
    ScheduleExportService.fillRect(buf, w, 0, 0, w, h, '#FFFFFF');
    ScheduleExportService.fillRect(buf, w, pad, pad, w - pad * 2, topH, Theme.innerColor(0.35));
    ScheduleExportService.fillRect(buf, w, pad, pad + topH, leftW, rows * cellH,
      Theme.innerColor(0.6));

    const grid = '#E7E2DC';
    for (let i = 0; i <= cols.length; i++) {
      ScheduleExportService.fillRect(buf, w, pad + leftW + i * cellW, pad + topH, 1, rows * cellH, grid);
    }
    for (let j = 0; j <= rows; j++) {
      ScheduleExportService.fillRect(buf, w, pad, pad + topH + j * cellH,
        leftW + cols.length * cellW, 1, grid);
    }

    const week = CourseStore.effectiveWeek(Date.now());
    for (const c of CourseStore.sortedCourses()) {
      const ci = cols.indexOf(c.weekday);
      if (ci < 0) {
        continue;
      }
      const startRow = c.startSection - 1;
      if (startRow < 0 || startRow >= rows) {
        continue;
      }
      const endRow = Math.min(c.endSection, rows);
      const rgb = CourseStore.colorOf(c);
      const x = pad + leftW + ci * cellW + 2;
      const y = pad + topH + startRow * cellH + 2;
      const cw = cellW - 4;
      const ch = (endRow - startRow) * cellH - 4;
      const active = CourseStore.activeInWeek(c, week);
      ScheduleExportService.fillRoundRect(buf, w, x, y, cw, ch, 8,
        active ? rgb.bg : Theme.mix(rgb.bg, '#FFFFFF', 0.55), active ? 1 : 0.6);
      ScheduleExportService.fillRoundRect(buf, w, x + 4, y + 4, 4, ch - 8, 2,
        rgb.bar, active ? 1 : 0.5);
    }

    const ly = pad + topH + rows * cellH + 12;
    ScheduleExportService.fillRect(buf, w, pad, ly, w - pad * 2, 1, grid);
    const colStep = Math.floor((w - pad * 2) / 3);
    let seg = 0;
    for (const c of CourseStore.sortedCourses()) {
      const col = seg % 3;
      const row = Math.floor(seg / 3);
      const lx = pad + col * colStep;
      const lyy = ly + 10 + row * 20;
      const rgb = CourseStore.colorOf(c);
      ScheduleExportService.fillRoundRect(buf, w, lx, lyy, 14, 14, 4, rgb.bg, 1);
      ScheduleExportService.fillRoundRect(buf, w, lx + 3, lyy + 3, 8, 8, 3, rgb.bar, 1);
      // 色块右侧的点：位置编码（第几行第几列），代替文字说明
      const ci = cols.indexOf(c.weekday);
      const dots = ci < 0 ? 0 : ci + 1;
      for (let k = 0; k < dots && k < 7; k++) {
        ScheduleExportService.fillRoundRect(buf, w, lx + 20 + k * 6, lyy + 5, 4, 4, 2, rgb.bar, 1);
      }
      seg += 1;
    }

    const px = await ScheduleExportService.toPixelMap(buf, w, h);
    const packer = image.createImagePacker();
    const opts: image.PackingOption = { format: 'image/png', quality: 100 };
    const out = await packer.packing(px, opts);
    px.release();
    packer.release();

    const name = `知课笺-${ScheduleExportService.baseName()}-${ScheduleExportService.stamp()}.png`;
    const uri = await ScheduleExportService.saveFile(name, out);
    return uri.length > 0 ? `已导出：${name}（色块版缩略图）` : '已取消';
  }

  private static async toPixelMap(buf: Uint8Array, w: number, h: number): Promise<image.PixelMap> {
    const opts: image.InitializationOptions = {
      editable: true,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      size: { width: w, height: h },
    };
    // createPixelMap 接受 ArrayBuffer（buf.buffer 可能带 offset，这里我们自己分配的必然是整段）
    const px = await image.createPixelMap(buf.buffer, opts);
    return px;
  }

  /** 填充矩形（alpha<1 时按比例混到已有像素上） */
  private static fillRect(buf: Uint8Array, w: number, x: number, y: number,
    rw: number, rh: number, color: string, alpha: number = 1): void {
    const c = ScheduleExportService.rgbOf(color);
    const h = Math.floor(buf.length / (w * 4));
    const x0 = Math.max(0, Math.floor(x));
    const y0 = Math.max(0, Math.floor(y));
    const x1 = Math.min(w, Math.floor(x + rw));
    const y1 = Math.min(h, Math.floor(y + rh));
    for (let yy = y0; yy < y1; yy++) {
      let idx = (yy * w + x0) * 4;
      for (let xx = x0; xx < x1; xx++) {
        ScheduleExportService.blendAt(buf, idx, c, alpha);
        idx += 4;
      }
    }
  }

  /** 填充圆角矩形（四角按半径裁切） */
  private static fillRoundRect(buf: Uint8Array, w: number, x: number, y: number,
    rw: number, rh: number, r: number, color: string, alpha: number = 1): void {
    const rad = Math.max(0, Math.min(r, Math.floor(Math.min(rw, rh) / 2)));
    if (rad === 0) {
      ScheduleExportService.fillRect(buf, w, x, y, rw, rh, color, alpha);
      return;
    }
    // 中间横带（整宽）
    ScheduleExportService.fillRect(buf, w, x, y + rad, rw, rh - rad * 2, color, alpha);
    // 上下两条（去掉两端的圆角区）
    ScheduleExportService.fillRect(buf, w, x + rad, y, rw - rad * 2, rad, color, alpha);
    ScheduleExportService.fillRect(buf, w, x + rad, y + rh - rad, rw - rad * 2, rad, color, alpha);
    // 四个圆角
    const c = ScheduleExportService.rgbOf(color);
    for (let dy = 0; dy < rad; dy++) {
      for (let dx = 0; dx < rad; dx++) {
        const ddx = rad - 1 - dx;
        const ddy = rad - 1 - dy;
        if (ddx * ddx + ddy * ddy > rad * rad) {
          continue;
        }
        ScheduleExportService.putPx(buf, w, x + dx, y + dy, c, alpha);
        ScheduleExportService.putPx(buf, w, x + rw - 1 - dx, y + dy, c, alpha);
        ScheduleExportService.putPx(buf, w, x + dx, y + rh - 1 - dy, c, alpha);
        ScheduleExportService.putPx(buf, w, x + rw - 1 - dx, y + rh - 1 - dy, c, alpha);
      }
    }
  }

  private static putPx(buf: Uint8Array, w: number, x: number, y: number,
    c: number[], alpha: number): void {
    const h = Math.floor(buf.length / (w * 4));
    if (x < 0 || y < 0 || x >= w || y >= h) {
      return;
    }
    ScheduleExportService.blendAt(buf, (y * w + x) * 4, c, alpha);
  }

  private static blendAt(buf: Uint8Array, idx: number, c: number[], alpha: number): void {
    if (alpha >= 1) {
      buf[idx] = c[0];
      buf[idx + 1] = c[1];
      buf[idx + 2] = c[2];
      buf[idx + 3] = 255;
      return;
    }
    buf[idx] = Math.round(buf[idx] * (1 - alpha) + c[0] * alpha);
    buf[idx + 1] = Math.round(buf[idx + 1] * (1 - alpha) + c[1] * alpha);
    buf[idx + 2] = Math.round(buf[idx + 2] * (1 - alpha) + c[2] * alpha);
    buf[idx + 3] = 255;
  }

  private static rgbOf(hex: string): number[] {
    if (hex.length < 7) {
      return [255, 255, 255];
    }
    return [
      parseInt(hex.substring(1, 3), 16),
      parseInt(hex.substring(3, 5), 16),
      parseInt(hex.substring(5, 7), 16),
    ];
  }
}
