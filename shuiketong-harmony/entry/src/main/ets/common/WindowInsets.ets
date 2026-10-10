import window from '@ohos.window';
import { display } from '@kit.ArkUI';
import hilog from '@ohos.hilog';

/**
 * 系统栏避让尺寸（vp）。
 *
 * ## 为什么需要它
 * 本应用开了**全屏沉浸布局**（`EntryAbility.applyImmersiveLayout` →
 * `setWindowLayoutFullScreen(true)`），页面内容会延伸到状态栏 / 底部手势条下方。
 * 好处是彻底消除「底部露出系统灰白条」（见 Main.ets 注释）；
 * 代价是**自绘顶栏会被状态栏压住**。
 *
 * ∴ 自绘顶栏顶部要补 `WindowInsets.statusBarVp()`。
 *
 * ## 取值策略
 * 同步从 `getLastWindow` 拿真实避让区是异步的，而顶栏 build 时需要立刻拿到值。
 * 所以：**先给经验兜底值保证首帧可用，异步取到真实值后写回缓存**
 * （页面在 `aboutToAppear` 里调一次 `sync()`，通常用户还没看清就已经校正完了）。
 *
 * **任何一步失败都不能抛** —— 布局避让问题不该让应用起不来。
 */
export class WindowInsets {
  /** 兜底经验值：主流直板机状态栏约 36vp、手势条约 24vp */
  private static readonly FALLBACK_STATUS = 36;
  private static readonly FALLBACK_NAV = 24;

  private static statusBar: number = WindowInsets.FALLBACK_STATUS;
  private static navBar: number = WindowInsets.FALLBACK_NAV;
  private static queried: boolean = false;

  /**
   * 触发一次真实避让区查询（异步回填）。
   * 幂等：重复调用只生效一次。页面 `aboutToAppear` 里调即可。
   */
  static sync(): void {
    if (WindowInsets.queried) {
      return;
    }
    WindowInsets.queried = true;
    try {
      window.getLastWindow(getContext())
        .then((w: window.Window) => {
          WindowInsets.readAvoidAreas(w);
        })
        .catch((e: Error) => {
          hilog.warn(0x0000, 'skt', 'WindowInsets: getLastWindow failed: %{public}s', e.message);
        });
    } catch (e) {
      const err = e as Error;
      hilog.warn(0x0000, 'skt', 'WindowInsets: sync failed: %{public}s', err.message);
    }
  }

  /** 从 Window 读避让区，物理 px → vp */
  private static readAvoidAreas(w: window.Window): void {
    try {
      const d: number = WindowInsets.density();

      const sys: window.AvoidArea = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      if (sys.topRect.height > 0) {
        WindowInsets.statusBar = Math.round(sys.topRect.height / d);
      }

      const nav: window.AvoidArea = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      if (nav.bottomRect.height > 0) {
        WindowInsets.navBar = Math.round(nav.bottomRect.height / d);
      }
      hilog.info(0x0000, 'skt', 'WindowInsets: status=%{public}d nav=%{public}d (vp)',
        WindowInsets.statusBar, WindowInsets.navBar);
    } catch (e) {
      const err = e as Error;
      hilog.warn(0x0000, 'skt', 'WindowInsets: readAvoidAreas failed: %{public}s', err.message);
    }
  }

  private static density(): number {
    try {
      const dp: number = display.getDefaultDisplaySync().densityPixels;
      return dp > 0 ? dp : 1;
    } catch (e) {
      return 1;
    }
  }

  /** 状态栏高度（vp）。自绘顶栏的顶部 padding 用这个。 */
  static statusBarVp(): number {
    return WindowInsets.statusBar;
  }

  /** 底部手势条高度（vp）。悬浮元素的额外底部留白参考。 */
  static navigationBarVp(): number {
    return WindowInsets.navBar;
  }

  /** 旋转 / 分屏后主动刷新（下次 `sync()` 会重新查询） */
  static resync(): void {
    WindowInsets.queried = false;
    WindowInsets.sync();
  }
}
