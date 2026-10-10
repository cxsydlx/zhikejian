import { router } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CourseStore, ImportResult } from '../common/CourseStore';
import { ClassReminder } from '../service/ClassReminder';
import { Theme } from '../common/Theme';
import { Mat } from '../common/Material';
import { WindowInsets } from '../common/WindowInsets';
import { FontSize, Weight, Space, Radius, Size, Motion, Layout } from '../common/DesignToken';


/** 正方教务「个人课表查询」页（石家庄铁道大学）。 */
const JW_URL = 'https://jw.stdu.edu.cn/kbcx/xskbcx_cxXskbcxIndex.html?gnmkdm=N253508&layout=default';

/**
 * 在教务页面内执行的抓取脚本：
 * 取当前选中的学年/学期，直接调正方课表接口拿 kbList JSON，经桥接回传应用。
 * 不走 DOM 解析，字段最干净。
 */
const GRAB_JS = `(function () {
  function send(o) {
    try { window.sktBridge.onScheduleData(typeof o === 'string' ? o : JSON.stringify(o)); } catch (e) {}
  }
  try {
    var xnEl = document.querySelector('select[name="xnm"]');
    var xqEl = document.querySelector('select[name="xqm"]');
    var xnm = xnEl ? xnEl.value : '';
    var xqm = xqEl ? xqEl.value : '';
    if (!xnm) { send({ error: 'no-xnm' }); return; }
    var body = 'xnm=' + encodeURIComponent(xnm) + '&xqm=' + encodeURIComponent(xqm) + '&gnmkdm=N253508';
    var xhr = new XMLHttpRequest();
    xhr.open('POST', '/kbcx/xskbcx_cxXsKb.html?gnmkdm=N253508', true);
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.onreadystatechange = function () {
      if (xhr.readyState === 4) {
        if (xhr.status === 200) { send(xhr.responseText); }
        else { send({ error: 'http-' + xhr.status }); }
      }
    };
    xhr.send(body);
  } catch (e) {
    send({ error: 'js-' + e });
  }
})();`;

/** Web → ArkTS 桥接对象（注入为 window.sktBridge）。 */
class ScheduleBridge {
  static handler: ((data: string) => void) | null = null;

  onScheduleData(data: string): void {
    const h = ScheduleBridge.handler;
    if (h != null) {
      h(data);
    }
  }
}

/**
 * 课表导入页：内嵌教务页面，用户自行登录，应用侧只负责抓取与解析。
 * 账号密码始终只输入在教务页面里，应用不接触。
 */
@Entry
@Component
struct ImportSchedule {
  // ---- 主题镜像：ArkUI 只观察「渲染中读取过」的状态；配色变化必须镜像成 @State 才会重绘 ----
  @State tc: string = Theme.themeColor();
  @State tacc: string = Theme.accentColor();
  @State tsoft: string = Theme.softColor();
  @State tpage: string = Theme.pageColor();
  @State ton: string = Theme.onTheme();
  @State tmain: string = Theme.textMain();
  @State tsub: string = Theme.textSub();

  controller: webview.WebviewController = new webview.WebviewController();
  private bridge: ScheduleBridge = new ScheduleBridge();
  @State status: string = '登录后进入「个人课表查询」，先点一次「查询」让课表加载出来，再点右上角「抓取课表」';
  @State busy: boolean = false;
  @State pageLoaded: boolean = false;

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

    ScheduleBridge.handler = (data: string) => {
      this.onGrabbed(data);
    };
  }

  aboutToDisappear(): void {
    ScheduleBridge.handler = null;
  }

  /** 抓取结果处理 */
  private onGrabbed(data: string): void {
    this.busy = false;
    const t = data.trim();
    // 【2026-10-07】加了 hilog：这个链路有 6 个失败分支（未登录 / 没查询 / 登录过期 /
    //   JSON 坏 / 无 kbList / 空课表），界面上只显示一行中文，事后很难复盘到底卡在哪。
    //   真机读法：`hdc shell "hilog -x -T ImportSchedule"`。
    hilog.info(0x0000, 'ImportSchedule', 'grabbed %{public}d bytes, head=%{public}s',
      t.length, t.substring(0, 120));
    if (t.length === 0) {
      this.status = '抓取失败：返回内容为空（可能未登录）';
      return;
    }
    if (t.indexOf('"error"') >= 0 && t.indexOf('kbList') < 0) {
      if (t.indexOf('no-xnm') >= 0) {
        this.status = '抓取失败：没读到学年，请先在教务页点一次「查询」';
      } else if (t.indexOf('http-') >= 0) {
        this.status = `抓取失败：${t.substring(0, 60)}（多为登录已过期，请在页面里重新登录）`;
      } else {
        this.status = `抓取失败：${t.substring(0, 100)}`;
      }
      return;
    }
    const res: ImportResult = CourseStore.importFromZfJson(t);
    if (!res.ok) {
      this.status = `抓取失败：${res.message}`;
      return;
    }
    // ⚠️ 这里原来**没有 .catch()**，是 2026-10-07 定位「导入后课表没显示课程」时
    //   挖出来的缺陷之二：persist() 一旦 reject（磁盘满 / 序列化失败），
    //   then 回调不执行 ⇒ 不弹「导入成功」、status 永远停在「正在抓取课表…」，
    //   用户看到的就是「点了没反应」，且**没有任何错误提示**。
    CourseStore.persist().then(() => {
      this.status = res.message;
      ClassReminder.refresh();   // 新课表：重排未来几天的系统提醒
      AlertDialog.show({
        title: '导入成功',
        message: `${res.message}。\n已保存到本机，返回课表页即可看到。`,
        confirm: {
          value: '返回课表',
          action: () => {
            router.back();
          },
        },
      });
    }).catch((e: BusinessError) => {
      this.status = `保存失败：${e.message}（内存里已有课表，但没写进本机存储）`;
      hilog.error(0x0000, 'ImportSchedule', 'persist failed: %{public}s', e.message);
      AlertDialog.show({
        title: '保存失败',
        message: `课表已解析出 ${res.count} 个时间块，但写入本机存储失败：${e.message}\n` +
          '通常是存储空间不足或应用数据被清理。可以先返回课表页查看，重试导入。',
        confirm: { value: '知道了', action: () => {} },
      });
    });
  }

  private grab(): void {
    if (this.busy) {
      return;
    }
    if (!this.pageLoaded) {
      this.status = '页面还在加载，稍等一下再抓取';
      return;
    }
    this.busy = true;
    this.status = '正在抓取课表…';
    this.controller.runJavaScript(GRAB_JS).catch((e: BusinessError) => {
      this.busy = false;
      this.status = `注入抓取脚本失败：${e.message}`;
    });
  }

  /**
   * 自绘顶栏（返回键 + 标题/副标题 + 右上「抓取课表」胶囊）。
   *
   * ⛔ 不用 `HdsNavigation`：真机实测其子树永不渲染（整页白屏），
   * 详见 `common/RouteBar.ets` 头部。也不用全局 `RouteBar()` ——
   * 全局 `@Builder` 参数**按值传递**，右上按钮文字依赖 `this.busy` 会不刷新；
   * 写成页面内 `@Builder` 才能正常响应状态。
   *
   * 视觉规格与 `Settings.barContent()` / `RouteBar` 完全一致（主题色满铺 +
   * `Size.bar` 高度 + 状态栏避让 + 右上白底胶囊），Tab 内页 ⇄ 路由页跳转不会"跳一下"。
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

      // 标题 + 副标题
      Column() {
        Text('导入课表')
          .fontSize(FontSize.titleS)
          .fontWeight(Weight.bold)
          .fontColor(this.ton)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('教务系统 · 个人课表查询')
          .fontSize(FontSize.captionL)
          .fontColor(Theme.mix(this.ton, this.tc, 0.45))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: Space.textGap })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .padding({ left: Space.s })

      // 右上动作：白底胶囊（忙时降透明度且不响应点击）
      Text(this.busy ? '抓取中…' : '抓取课表')
        .fontSize(FontSize.subtitleS)
        .fontWeight(Weight.medium)
        .fontColor(this.tc)
        .padding({ left: Space.l, right: Space.l, top: Space.xsPlus, bottom: Space.xsPlus })
        .borderRadius(Radius.full)
        .backgroundColor(Theme.innerColor())
        .systemMaterial(Mat.tile())
        .textAlign(TextAlign.Center)
        .opacity(this.busy ? 0.5 : 1)
        .onClick(() => {
          if (!this.busy) {
            this.grab();
          }
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

  build() {
    Column() {
      this.barContent()

      // 状态条（文本自适应高度，不写死，避免系统大字体溢出）
      Text(this.status)
        .fontSize(FontSize.bodyS)
        .fontColor(Theme.sysTextSub())
        .width('100%')
        .padding({
          left: Layout.screenMargin(),
          right: Layout.screenMargin(),
          top: Space.m,
          bottom: Space.m,
        })
        .backgroundColor(Theme.sysFill())

      // 教务页面
      Web({ src: JW_URL, controller: this.controller })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .mixedMode(MixedMode.All)
        .onPageEnd(() => {
          this.pageLoaded = true;
          if (this.busy) {
            return;
          }
          this.status = '页面已加载：登录后点「查询」，再点右上角「抓取课表」';
        })
        .onSslErrorEventReceive((event) => {
          // 国内高校常自签/证书链不全，放行以便正常访问教务
          event.handler.handleConfirm();
        })
        .javaScriptProxy({
          object: this.bridge,
          name: 'sktBridge',
          methodList: ['onScheduleData'],
          controller: this.controller,
        })
        .layoutWeight(1)
    }.transition(Motion.pageEnter())
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.sysPage())
  }
}
