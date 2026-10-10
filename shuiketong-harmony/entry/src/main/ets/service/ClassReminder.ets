import { notificationManager } from '@kit.NotificationKit';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { CourseStore, UpcomingClass } from '../common/CourseStore';
import { AppConst } from '../common/AppConst';
import { AppState } from '../common/AppState';
import { AsrService } from './AsrService';

/** 应用存活时的兜底通知 id：重复发布即更新同一条，不会堆通知 */
const NOTIFY_ID = 10086;
/** 系统代理提醒的通知 id 起点（每条课一个，避免互相覆盖） */
const SYS_ID_BASE = 20000;
const CHECK_MS = 30000;
/** 一次最多排多少条系统提醒（官方上限：单应用有效提醒 ≤ 30） */
const MAX_SYS_REMINDERS = 20;
/** 往前排几天 */
const SCHEDULE_DAYS = 7;

/**
 * 上课提醒。
 *
 * **主路径 = 系统「代理提醒」(reminderAgentManager)**：
 * 把未来几天每节课的提醒时间点一次性排给系统，**应用被杀/不在前台也能准点提醒**。
 * 这不是实况窗——实况窗官方明确不开放「课程提醒 / 录音」场景（TIMER 的"不适用场景案例"
 * 里逐字写了课程提醒），申请必被驳回；而「代理提醒」的开放场景清单里**明确包含课程提醒**。
 *
 * 需要：AGC → 项目设置 → 开放能力管理 → 申请「代理提醒」（课程/学习类属于允许场景），
 * 通过后勾选能力开关、重新生成 Profile 并手动签名；module.json5 已声明
 * `ohos.permission.PUBLISH_AGENT_REMINDER`（normal 级，非 ACL 受限权限）。
 * 能力未开通时 publishReminder 会失败，此时自动退回到"应用存活时的本地通知"。
 *
 * 三条硬规则：
 * 1. 正在上课时不打扰，并终止该节的提醒；
 * 2. 转写运行中时让位（只影响进程内的兜底通知，系统提醒不受影响）；
 * 3. 停课日（节假日）整天跳过 —— 由 CourseStore.upcoming / upcomingList 保证。
 */
export class ClassReminder {
  static enabled: boolean = true;
  static leadMinutes: number = 15;
  /** 代理提醒能力是否可用（首次 publish 成功后置 true，用于设置页提示） */
  static systemAvailable: boolean = false;
  /** 上一次发布失败的错误码（0 = 正常），设置页用它提示"能力未开通" */
  static lastErrorCode: number = 0;

  private static prefs: preferences.Preferences | null = null;
  private static timer: number = -1;
  private static activeKey: string = '';      // 正在提醒的课；'' = 未在提醒
  private static activeName: string = '';
  private static sig: string = '';            // 课表/配置指纹，变了就重排系统提醒

  /** 读取配置并启动检查循环（在主页 aboutToAppear 调用） */
  static async init(ctx: common.UIAbilityContext): Promise<void> {
    ClassReminder.prefs = await preferences.getPreferences(ctx, 'skt_prefs');
    ClassReminder.enabled = (await ClassReminder.prefs.get('reminderEnabled', true)) as boolean;
    ClassReminder.leadMinutes = (await ClassReminder.prefs.get('reminderLead', 15)) as number;
    ClassReminder.start();
    await ClassReminder.scheduleSystem();
  }

  static async saveCfg(): Promise<void> {
    const p = ClassReminder.prefs;
    if (p == null) {
      return;
    }
    await p.put('reminderEnabled', ClassReminder.enabled);
    await p.put('reminderLead', ClassReminder.leadMinutes);
    await p.flush();
    await ClassReminder.scheduleSystem();
  }

  static isReminding(): boolean {
    return ClassReminder.activeKey.length > 0;
  }

  static remindingName(): string {
    return ClassReminder.activeName;
  }

  static start(): void {
    ClassReminder.stopTimer();
    ClassReminder.timer = setInterval(() => {
      ClassReminder.check();
    }, CHECK_MS);
    ClassReminder.check();
  }

  static stop(): void {
    ClassReminder.stopTimer();
    ClassReminder.cancel();
  }

  private static stopTimer(): void {
    if (ClassReminder.timer >= 0) {
      clearInterval(ClassReminder.timer);
      ClassReminder.timer = -1;
    }
  }

  static setEnabled(on: boolean): void {
    ClassReminder.enabled = on;
    if (on) {
      ClassReminder.check();
      ClassReminder.scheduleSystem();
    } else {
      ClassReminder.cancel();
      ClassReminder.clearSystemReminders();
    }
  }

  /** 课表 / 配置变化后手动触发一次（重排系统提醒 + 立即检查） */
  static refresh(): void {
    ClassReminder.sig = ClassReminder.dataSig();
    ClassReminder.scheduleSystem();
    ClassReminder.check();
  }

  private static cancel(): void {
    if (ClassReminder.activeKey.length === 0) {
      return;
    }
    ClassReminder.activeKey = '';
    ClassReminder.activeName = '';
    ClassReminder.clearNotification();
  }

  private static check(): void {
    if (!ClassReminder.enabled) {
      return;
    }
    // 课表变了（导入/手动增删/节假日/周数）→ 重排系统提醒
    const sig = ClassReminder.dataSig();
    if (sig !== ClassReminder.sig) {
      ClassReminder.sig = sig;
      ClassReminder.scheduleSystem();
    }
    // 转写运行中：进程内兜底通知让位（系统提醒由系统发，不受影响）
    if (AsrService.isRunning()) {
      ClassReminder.cancel();
      return;
    }
    const now = Date.now();
    // 正在上课：不打扰（同时终止上一节的提醒）
    if (CourseStore.ongoing(now) != null) {
      ClassReminder.cancel();
      return;
    }
    const up = CourseStore.upcoming(now);
    if (!up.found || up.daysAhead !== 0 || up.minutesLeft < 0
      || up.minutesLeft > ClassReminder.leadMinutes) {
      ClassReminder.cancel();
      return;
    }
    ClassReminder.activeKey = up.key;
    ClassReminder.activeName = up.name;
    // 应用在前台/存活：额外发一条本地通知（做到"进了提醒窗口就有提示"）
    ClassReminder.notify(up);
  }

  private static dataSig(): string {
    const s = CourseStore.semester;
    return `${CourseStore.courses.length}|${s.holidays.length}|${s.totalWeeks}|${s.openDate}|${ClassReminder.leadMinutes}`;
  }

  // ---------- 系统代理提醒（主路径） ----------

  /** 清掉本应用所有系统提醒（重排前先清，避免残留旧时间点） */
  static async clearSystemReminders(): Promise<void> {
    try {
      await reminderAgentManager.cancelAllReminders();
    } catch (e) {
      // 能力未开通时这里也会失败，静默即可
    }
  }

  /**
   * 把未来 SCHEDULE_DAYS 天内每节课的提醒点排给系统。
   * 排期失败（代理提醒能力未开通）不报错刷屏，只记一条日志并置 lastErrorCode 供设置页展示。
   */
  static async scheduleSystem(): Promise<void> {
    await ClassReminder.clearSystemReminders();
    if (!ClassReminder.enabled) {
      return;
    }
    const list = CourseStore.upcomingList(Date.now(), SCHEDULE_DAYS);
    const now = Date.now();
    let ok = 0;
    let fail = 0;
    let idx = 0;
    for (const up of list) {
      const trigger = up.startMs - ClassReminder.leadMinutes * 60000;
      if (trigger <= now + 60000) {
        continue;   // 已过提醒点（或就在这一分钟内）：跳过，交给进程内兜底
      }
      if (idx >= MAX_SYS_REMINDERS) {
        break;
      }
      const success = await ClassReminder.publishOne(up, trigger, SYS_ID_BASE + idx);
      idx += 1;
      if (success) {
        ok += 1;
      } else {
        fail += 1;
      }
    }
    if (fail > 0) {
      AppState.log(`上课提醒：系统提醒排期 ${ok} 条成功、${fail} 条失败（code=${ClassReminder.lastErrorCode}）`
        + `；代理提醒开放能力未开通时会失败，需在 AGC「项目设置 → 开放能力管理」申请`);
    } else if (ok > 0) {
      AppState.log(`上课提醒：已排 ${ok} 条系统提醒（应用被杀也能提醒，未来 ${SCHEDULE_DAYS} 天）`);
    }
  }

  private static async publishOne(up: UpcomingClass, triggerMs: number, notifyId: number): Promise<boolean> {
    const d = new Date(triggerMs);
    const where = up.location.length > 0 ? up.location : '见课表';
    const title = up.name;
    const content = `${up.section}节即将开始 · ${where}`;
    const req: reminderAgentManager.ReminderRequestCalendar = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
      dateTime: {
        year: d.getFullYear(),
        month: d.getMonth() + 1,
        day: d.getDate(),
        hour: d.getHours(),
        minute: d.getMinutes(),
        second: 0,
      },
      actionButton: [
        {
          title: '知道了',
          type: reminderAgentManager.ActionButtonType.ACTION_BUTTON_TYPE_CLOSE,
        },
      ],
      wantAgent: {
        pkgName: AppConst.BUNDLE_NAME,
        abilityName: AppConst.ENTRY_ABILITY,
      },
      ringDuration: 5,
      title: `要上课了 · ${title}`,
      content: content,
      expiredContent: '已开始上课',
      notificationId: notifyId,
      slotType: notificationManager.SlotType.CONTENT_INFORMATION,
    };
    try {
      await reminderAgentManager.publishReminder(req);
      ClassReminder.systemAvailable = true;
      ClassReminder.lastErrorCode = 0;
      return true;
    } catch (e) {
      const err = e as BusinessError;
      ClassReminder.lastErrorCode = err.code;
      ClassReminder.systemAvailable = false;
      return false;
    }
  }

  // ---------- 进程内兜底通知（应用存活时） ----------

  private static async notify(up: UpcomingClass): Promise<void> {
    const left = up.minutesLeft <= 0 ? '马上开始' : `${up.minutesLeft} 分钟后`;
    const where = up.location.length > 0 ? up.location : '见课表';
    try {
      const request: notificationManager.NotificationRequest = {
        id: NOTIFY_ID,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: `要上课了 · ${up.name}`,
            text: `${left} · ${where}`,
          },
        },
      };
      await notificationManager.publish(request);
    } catch (e) {
      const err = e as BusinessError;
      AppState.log(`上课提醒通知失败 code=${err.code} ${err.message}`);
    }
  }

  private static async clearNotification(): Promise<void> {
    try {
      await notificationManager.cancel(NOTIFY_ID);
    } catch (e) {
      // 忽略
    }
  }
}
