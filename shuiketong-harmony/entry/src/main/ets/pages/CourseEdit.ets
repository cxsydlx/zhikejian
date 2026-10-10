import { router } from '@kit.ArkUI';
import { CourseItem, CourseStore } from '../common/CourseStore';
import { Sections } from '../common/SectionTimes';
import { ClassReminder } from '../service/ClassReminder';
import { Theme } from '../common/Theme';
import { Mat } from '../common/Material';
import { WindowInsets } from '../common/WindowInsets';
import { FontSize, Weight, Space, Radius, Size, Motion, Layout } from '../common/DesignToken';

const DAYS: string[] = ['', '一', '二', '三', '四', '五', '六', '日'];

/**
 * 手动管理课程（教务抓取不顺时的兜底）。
 *
 * 列表按 星期 → 起始节次 排序，点一行改、右侧删除；右上「新增」加一节。
 * 保存后由 CourseStore 重跑 8 邻域避色并落盘。
 *
 * ArkUI 约定（本工程踩过的坑）：
 *  · 所有会变的值都放在 @State 且**在 build 里被读到**，否则不触发重绘；
 *  · ForEach 的 key 里带上 rev（否则条目不会重建）；
 *  · 不写"带动态值参数"的 @Builder（按值传参不刷新）。
 */
@Entry
@Component
struct CourseEdit {
  // ---- 主题镜像：ArkUI 只观察「渲染中读取过」的状态；配色变化必须镜像成 @State 才会重绘 ----
  @State tc: string = Theme.themeColor();
  @State tacc: string = Theme.accentColor();
  @State tsoft: string = Theme.softColor();
  @State tpage: string = Theme.pageColor();
  @State ton: string = Theme.onTheme();
  @State tmain: string = Theme.textMain();
  @State tsub: string = Theme.textSub();

  @State list: CourseItem[] = [];
  @State rev: number = 0;

  // 表单
  @State showForm: boolean = false;
  @State editId: string = '';
  @State fName: string = '';
  @State fTeacher: string = '';
  @State fLocation: string = '';
  @State fWeekday: number = 1;
  @State fStart: number = 1;
  @State fEnd: number = 2;
  @State fWeeks: string = '1-16';

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
    Layout.init();
    // 沉浸光感：EntryAbility 已 init，这里再调一次（幂等）以覆盖「router 直接进本页」
    Mat.init();
    // 系统栏避让：全屏沉浸下自绘顶栏要补状态栏高度（异步回填，兜底值撑首帧）
    WindowInsets.sync();
    Theme.onChange(() => {
      this.syncTheme();
    });
    this.syncTheme();

    CourseStore.onChange(() => {
      this.list = CourseStore.sortedCourses();
      this.rev += 1;
    });
  }

  private openForm(item: CourseItem | null): void {
    if (item == null) {
      this.editId = '';
      this.fName = '';
      this.fTeacher = '';
      this.fLocation = '';
      this.fWeekday = CourseStore.todayWeekday(Date.now());
      this.fStart = 1;
      this.fEnd = 2;
      this.fWeeks = '1-16';
    } else {
      this.editId = item.id;
      this.fName = item.name;
      this.fTeacher = item.teacher;
      this.fLocation = item.location;
      this.fWeekday = item.weekday;
      this.fStart = item.startSection;
      this.fEnd = item.endSection;
      this.fWeeks = item.weekText.length > 0 ? item.weekText : '1-16';
    }
    this.showForm = true;
  }

  private async saveForm(): Promise<void> {
    const name = this.fName.trim();
    if (name.length === 0) {
      AlertDialog.show({
        title: '课程名不能为空',
        message: '请填写课程名，例如「高等数学」。',
        confirm: { value: '好', action: () => {} },
      });
      return;
    }
    const c = new CourseItem();
    c.name = name;
    c.teacher = this.fTeacher.trim();
    c.location = this.fLocation.trim();
    c.campus = '';
    c.weekday = this.fWeekday;
    c.startSection = this.fStart;
    c.endSection = this.fEnd;
    c.weekText = this.fWeeks.trim().length > 0 ? this.fWeeks.trim() : '1-16';
    c.weeks = CourseStore.parseWeeks(c.weekText);
    c.colorIndex = -1;
    // 改课名/周次会换 id：先把旧的删掉，避免同一条记录留两份
    if (this.editId.length > 0 && this.editId !== CourseStore.makeId(c)) {
      await CourseStore.deleteCourse(this.editId);
    }
    await CourseStore.upsertCourse(c);
    ClassReminder.refresh();   // 课表变了：重排系统提醒
    this.showForm = false;
  }

  private confirmDelete(item: CourseItem): void {
    AlertDialog.show({
      title: '删除这节课',
      message: `「${item.name}」周${DAYS[item.weekday]} ${Sections.rangeText(item.startSection, item.endSection)}\n确定删除？`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '删除',
        fontColor: '#C0392B',
        action: () => {
          CourseStore.deleteCourse(item.id);
          ClassReminder.refresh();
        },
      },
    });
  }

  // ---------- UI ----------

  /**
   * 自绘顶栏（返回键 + 标题/副标题 + 右上「新增」胶囊）。
   *
   * ⛔ 不用 `HdsNavigation`：真机实测其子树永不渲染（整页白屏），
   * 详见 `common/RouteBar.ets` 头部。也不用全局 `RouteBar()` ——
   * 全局 `@Builder` 参数**按值传递**，右上按钮依赖页面状态时会不刷新；
   * 写成页面内 `@Builder` 才能正常响应状态。
   *
   * 视觉规格与 `ImportSchedule.barContent()` / `Settings.barContent()` 完全一致
   * （主题色满铺 + `Size.bar` 高度 + 状态栏避让 + 右上白底胶囊），
   * Tab 内页 ⇄ 路由页跳转不会"跳一下"。
   */
  @Builder
  barContent() {
    Row() {
      // 返回键：48×48 触控热区（官方无障碍硬指标）
      Text('\u2039')
        .fontSize(FontSize.titleM)
        .fontColor(this.ton)
        .width(Size.touchTarget)
        .height(Size.touchTarget)
        .textAlign(TextAlign.Center)
        .borderRadius(Radius.full)
        .onClick(() => {
          router.back();
        })

      // 标题（原 hdsBar 未设 subTitle，故不画副标题）
      Column() {
        Text('管理课程')
          .fontSize(FontSize.titleS)
          .fontWeight(Weight.bold)
          .fontColor(this.ton)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .padding({ left: Space.s })

      // 右上动作：白底胶囊
      Text('新增')
        .fontSize(FontSize.subtitleS)
        .fontWeight(Weight.medium)
        .fontColor(this.tc)
        .padding({ left: Space.l, right: Space.l, top: Space.xsPlus, bottom: Space.xsPlus })
        .borderRadius(Radius.full)
        .backgroundColor(Theme.innerColor())
        .systemMaterial(Mat.tile())
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.openForm(null);
        })
    }
    .width('100%')
    // height 补状态栏高度：全屏沉浸下页面延伸到状态栏下方（见 WindowInsets.ets）
    .height(Size.bar + WindowInsets.statusBarVp())
    // 左右边距与内容区对齐（screenMargin），顶栏本身仍是满铺色条
    .padding({
      left: Layout.screenMargin(),
      right: Layout.screenMargin(),
      top: WindowInsets.statusBarVp(),
    })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.tc)
    .systemMaterial(Mat.bar())
  }

  @Builder
  formPanel() {
    Column() {
      Column() {
        Text(this.editId.length > 0 ? '修改课程' : '新增课程')
          .fontSize(FontSize.subtitleL)
          .fontWeight(Weight.bold)
          .fontColor(Theme.sysTextMain())
          .width('100%')

        Text('课程名')
          .fontSize(FontSize.bodyS)
          .fontWeight(Weight.medium)
          .fontColor(Theme.sysTextSub())
          .width('100%')
          .margin({ top: Space.m, bottom: Space.xs })
        TextInput({ text: this.fName, placeholder: '例如：高等数学' })
          .fontSize(FontSize.subtitleM)
          .height(Size.touchTarget)
          .width('100%')
          .backgroundColor(Theme.sysCard())
          .borderRadius(Radius.m)
          .onChange((v: string) => {
            this.fName = v;
          })

        Text('教师 / 地点')
          .fontSize(FontSize.bodyS)
          .fontWeight(Weight.medium)
          .fontColor(Theme.sysTextSub())
          .width('100%')
          .margin({ top: Space.m, bottom: Space.xs })
        Row() {
          TextInput({ text: this.fTeacher, placeholder: '教师（选填）' })
            .fontSize(FontSize.subtitleM)
            .height(Size.touchTarget)
            .layoutWeight(1)
            .backgroundColor(Theme.sysCard())
            .borderRadius(Radius.m)
            .onChange((v: string) => {
              this.fTeacher = v;
            })
          TextInput({ text: this.fLocation, placeholder: '地点（选填）' })
            .fontSize(FontSize.subtitleM)
            .height(Size.touchTarget)
            .layoutWeight(1)
            .margin({ left: Space.s })
            .backgroundColor(Theme.sysCard())
            .borderRadius(Radius.m)
            .onChange((v: string) => {
              this.fLocation = v;
            })
        }
        .width('100%')

        Text('星期')
          .fontSize(FontSize.bodyS)
          .fontWeight(Weight.medium)
          .fontColor(Theme.sysTextSub())
          .width('100%')
          .margin({ top: Space.m, bottom: Space.xs })
        Row() {
          ForEach([1, 2, 3, 4, 5, 6, 7], (d: number) => {
            Text(`周${DAYS[d]}`)
              .fontSize(FontSize.captionL)
              .fontWeight(Weight.medium)
              .fontColor(d === this.fWeekday ? Theme.onEmphasize() : Theme.sysFillInk())
              .textAlign(TextAlign.Center)
              .padding({ left: Space.s, right: Space.s, top: Space.xsPlus, bottom: Space.xsPlus })
              .borderRadius(Radius.full)
              .backgroundColor(d === this.fWeekday ? Theme.sysEmphasize() : Theme.sysFill())
              .margin({ left: d === 1 ? 0 : Space.xs })
              .onClick(() => {
                this.fWeekday = d;
                this.rev += 1;
              })
          }, (d: number) => `fd-${d}-${this.fWeekday}-${this.rev}`)
        }
        .width('100%')

        Text('节次（起 - 止）')
          .fontSize(FontSize.bodyS)
          .fontWeight(Weight.medium)
          .fontColor(Theme.sysTextSub())
          .width('100%')
          .margin({ top: Space.m, bottom: Space.xs })
        Row() {
          Text(`第 ${this.fStart} - ${this.fEnd} 节 · ${Sections.spanText(this.fStart, this.fEnd)}`)
            .fontSize(FontSize.subtitleS)
            .fontColor(Theme.sysTextMain())
            .layoutWeight(1)
          Text('－')
            .fontSize(FontSize.subtitleL)
            .fontColor(Theme.sysEmphasize())
            .width(Size.touchTarget)
            .height(Size.touchTarget)
            .textAlign(TextAlign.Center)
            .borderRadius(Radius.m)
            .backgroundColor(Theme.sysFill())
            .onClick(() => {
              this.fStart = this.fStart > 1 ? this.fStart - 1 : 1;
              if (this.fEnd < this.fStart) {
                this.fEnd = this.fStart;
              }
              this.rev += 1;
            })
          Text('＋')
            .fontSize(FontSize.subtitleL)
            .fontColor(Theme.sysEmphasize())
            .width(Size.touchTarget)
            .height(Size.touchTarget)
            .textAlign(TextAlign.Center)
            .borderRadius(Radius.m)
            .backgroundColor(Theme.sysFill())
            .margin({ left: Space.s })
            .onClick(() => {
              this.fStart = this.fStart < Sections.TOTAL - 1 ? this.fStart + 1 : this.fStart;
              if (this.fEnd < this.fStart) {
                this.fEnd = this.fStart;
              }
              this.rev += 1;
            })
          Text('－')
            .fontSize(FontSize.subtitleL)
            .fontColor(Theme.sysEmphasize())
            .width(Size.touchTarget)
            .height(Size.touchTarget)
            .textAlign(TextAlign.Center)
            .borderRadius(Radius.m)
            .backgroundColor(Theme.sysFill())
            .margin({ left: Space.l })
            .onClick(() => {
              this.fEnd = this.fEnd > this.fStart ? this.fEnd - 1 : this.fStart;
              this.rev += 1;
            })
          Text('＋')
            .fontSize(FontSize.subtitleL)
            .fontColor(Theme.sysEmphasize())
            .width(Size.touchTarget)
            .height(Size.touchTarget)
            .textAlign(TextAlign.Center)
            .borderRadius(Radius.m)
            .backgroundColor(Theme.sysFill())
            .margin({ left: Space.s })
            .onClick(() => {
              this.fEnd = this.fEnd < Sections.TOTAL ? this.fEnd + 1 : this.fEnd;
              this.rev += 1;
            })
        }
        .width('100%')

        Text('周次')
          .fontSize(FontSize.bodyS)
          .fontWeight(Weight.medium)
          .fontColor(Theme.sysTextSub())
          .width('100%')
          .margin({ top: Space.m, bottom: Space.xs })
        TextInput({ text: this.fWeeks, placeholder: '1-16 / 2-16双 / 1,3,5' })
          .fontSize(FontSize.subtitleM)
          .height(Size.touchTarget)
          .width('100%')
          .backgroundColor(Theme.sysCard())
          .borderRadius(Radius.m)
          .onChange((v: string) => {
            this.fWeeks = v;
          })
        Text('写法：1-16 全周 / 2-16双 双周 / 1-15单 单周 / 1,3,5 指定周')
          .fontSize(FontSize.bodyS)
          .fontColor(Theme.sysTextSub())
          .width('100%')
          .margin({ top: Space.s })

        Row() {
          Text('取消')
            .fontSize(FontSize.subtitleS)
            .fontWeight(Weight.medium)
            .fontColor(Theme.sysTextSub())
            .textAlign(TextAlign.Center)
            .padding({ left: Space.xxl, right: Space.xxl, top: Space.xs, bottom: Space.xs })
            .borderRadius(Radius.full)
            .backgroundColor(Theme.sysFill())
            .onClick(() => {
              this.showForm = false;
            })
          Text('保存')
            .fontSize(FontSize.subtitleS)
            .fontWeight(Weight.medium)
            .fontColor(Theme.onEmphasize())
            .textAlign(TextAlign.Center)
            .padding({ left: Space.xxl, right: Space.xxl, top: Space.xs, bottom: Space.xs })
            .margin({ left: Space.m })
            .borderRadius(Radius.full)
            .backgroundColor(Theme.sysEmphasize())
            .systemMaterial(Mat.button())
            .onClick(() => {
              this.saveForm();
            })
        }
        .width('100%')
        .margin({ top: Space.xl })
        .justifyContent(FlexAlign.Center)
      }
      .width('90%')
      .padding(Space.xl)
      .borderRadius(Radius.xl)
      .backgroundColor(Theme.sysCard())
      .systemMaterial(Mat.sheet())
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#00000055')
    .transition(Motion.fadeIn())
  }

  build() {
    Stack() {
      this.pageShell()

      if (this.showForm) {
        this.formPanel()
      }
    }.transition(Motion.pageEnter())
    .width('100%')
    .height('100%')
  }

  /** 页面骨架：自绘顶栏 + 内容流（不再用 HdsNavigation，真机不渲染子树） */
  @Builder
  pageShell() {
    Column() {
      this.barContent()

      if (this.list.length === 0) {
        Column() {
          // 空状态插图：气泡 + 书（暂无课程）
          Image($r('app.media.ill_empty_question'))
            .width(Size.emptyIll)
            .height(Size.emptyIll)
            .objectFit(ImageFit.Contain)
            .margin({ bottom: Space.l })
          Text('还没有课程')
            .fontSize(FontSize.subtitleM)
            .fontWeight(Weight.bold)
            .fontColor(Theme.sysTextMain())
          Text('点右上「新增」手动加一节，\n或在课表页「导入」从教务抓取。')
            .fontSize(FontSize.bodyM)
            .fontColor(Theme.sysTextSub())
            .textAlign(TextAlign.Center)
            .margin({ top: Space.m })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            Text(`共 ${this.list.length} 个课程块 · 点一行可修改`)
              .fontSize(FontSize.bodyS)
              .fontColor(Theme.sysTextSub())
              .width('100%')
              .padding({ left: Space.xs, top: Space.l, bottom: Space.s })

            Column() {
              ForEach(this.list, (item: CourseItem) => {
                Row() {
                  Column()
                    .width(5)
                    .height(34)
                    .borderRadius(3)
                    .backgroundColor(CourseStore.colorOf(item).bar)
                    .margin({ right: Space.m })

                  Column() {
                    Text(item.name)
                      .fontSize(FontSize.subtitleM)
                      .fontColor(Theme.sysTextMain())
                      .width('100%')
                    Text(this.metaOf(item))
                      .fontSize(FontSize.bodyS)
                      .fontColor(Theme.sysTextSub())
                      .width('100%')
                      .margin({ top: Space.xs })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  Text('删除')
                    .fontSize(FontSize.subtitleS)
                    .fontWeight(Weight.medium)
                    .fontColor('#C0392B')
                    .textAlign(TextAlign.Center)
                    .padding({ left: Space.m, right: Space.m })
                    .constraintSize({ minHeight: Size.touchTarget })
                    .onClick(() => {
                      this.confirmDelete(item);
                    })
                }
                .width('100%')
                .constraintSize({ minHeight: Size.touchTarget })
                .alignItems(VerticalAlign.Center)
                .onClick(() => {
                  this.openForm(item);
                })
              }, (item: CourseItem) => `c-${item.id}-${this.rev}`)
            }
            .width('100%')
            .padding({ left: Space.l, right: Space.l })
            .borderRadius(Radius.l)
            .backgroundColor(Theme.sysCard())
          }
          .width('100%')
          .padding({ left: Layout.screenMargin(), right: Layout.screenMargin() })
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.sysPage())
  }

  private metaOf(item: CourseItem): string {
    let s = `周${DAYS[item.weekday]} ${Sections.rangeText(item.startSection, item.endSection)}`;
    if (item.location.length > 0) {
      s += ` · ${item.location}`;
    }
    if (item.teacher.length > 0) {
      s += ` · ${item.teacher}`;
    }
    if (item.weekText.length > 0) {
      s += ` · ${item.weekText}`;
    }
    return s;
  }
}
