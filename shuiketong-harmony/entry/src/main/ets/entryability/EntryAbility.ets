import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import hilog from '@ohos.hilog';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { Configuration } from '@ohos.app.ability.Configuration';
import { AppState } from '../common/AppState';
import { Mat } from '../common/Material';
import { Theme } from '../common/Theme';
import { ShareService } from '../service/ShareService';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'skt', '%{public}s', 'Ability onCreate');
    AppState.init(this.context as common.UIAbilityContext);
    // 深色模式：声明「跟随系统」。
    // ⚠️ 不调这一句时，应用在部分系统版本上被按固定浅色渲染 ——
    // 表现就是「系统切了深色，应用里 sys.color.* 一点没变」。
    // 全工程的颜色已迁到系统资源（Theme.sysPage/sysCard/sysFill/...），
    // 声明之后它们会随系统深浅色自动取 base/dark 两套值。
    EntryAbility.applyColorMode(this.context as common.UIAbilityContext);
    // 把 context 交给 Theme：少数「必须先做颜色运算」的方法（innerBase /
    // floatGlassBase）要读 config.colorMode 才能分出深/浅两套中性灰。
    Theme.attachContext(this.context as common.UIAbilityContext);
    // 沉浸光感：探测能力并建材质。必须早于第一个页面 build（各页顶栏/卡片/弹层都要挂材质）。
    Mat.init();
    // 冷启动：若是碰一碰分享进来的，解析出课表载荷暂存。
    // 此时 UI 还没创建，ShareService 会先存 pendingImport，等 Main 页面订阅后弹窗。
    ShareService.handleShareWant(want).then((hit: boolean) => {
      if (hit) {
        hilog.info(DOMAIN, 'skt', '%{public}s', 'cold start share want parsed');
      }
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'skt', '%{public}s', 'Ability onDestroy');
  }

  /**
   * 声明应用的色彩模式 = 跟随系统。
   *
   * 【2026-09-30 新增 · 修「深色模式没有变化」】
   *
   * ## 现象
   * 系统设置切到深色后，课表页照旧（用户要求保留色系，符合预期），
   * 但**设置页 / 听课页**也一点没变 —— 页面底、卡片底仍是浅色。
   *
   * ## 根因
   * 应用从来没有声明过 colorMode。系统对「未声明」的应用在部分版本上
   * 直接按浅色渲染，于是 `$r('sys.color.xxx')` 一直取 base（浅色）值。
   * 我们前面把颜色全迁到系统资源本身是对的，**缺的是这一步声明**。
   *
   * ## 三个取值
   *   COLOR_MODE_NOT_SET  跟随系统（本次采用）
   *   COLOR_MODE_LIGHT    强制浅色
   *   COLOR_MODE_DARK     强制深色
   *
   * 失败只记日志 —— 老版本不支持时静默保持默认行为，不影响功能。
   */
  private static applyColorMode(ctx: common.UIAbilityContext): void {
    try {
      ctx.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      hilog.info(DOMAIN, 'skt', '%{public}s', 'setColorMode(COLOR_MODE_NOT_SET) ok');
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, 'skt', 'setColorMode failed: %{public}s', err.message);
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Main', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'skt', 'Failed to load content: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'skt', 'Succeeded in loading content.');
      EntryAbility.applyImmersiveLayout(windowStage);
    });
  }

  /**
   * 开启全屏沉浸布局 + 透明系统栏。
   *
   * 不开这个，应用默认「非全屏」—— 底部会留出系统安全区，露出系统默认底色
   * （实测 `#F5F5F5` 中性灰），在浅色页面上看就是「下面白了一条」。
   * 这也是沉浸光感的前提：内容与悬浮底栏必须能延伸到屏幕最底边。
   *
   * 失败只记日志不抛 —— 老设备/老版本不支持时静默降级为普通布局，
   * 不影响功能（只是底部会保留安全区）。
   */
  private static applyImmersiveLayout(windowStage: window.WindowStage): void {
    try {
      const win = windowStage.getMainWindowSync();
      // 1) 布局延伸到系统栏区域（含底部手势条）
      win.setWindowLayoutFullScreen(true);
      // 2) 系统栏设为透明/悬浮，内容才能透上去。
      //    ⚠️ 内容色（状态栏/导航栏图标）留空 —— 留空时系统按**当前深浅色**
      //    自动选反色（浅色主题→深图标，深色主题→浅图标）。
      //    之前硬编码 '#1C1917'，切深色后状态栏图标几乎看不见。
      const top: window.SystemBarProperties = {
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
      };
      win.setWindowSystemBarProperties(top).catch((e: Error) => {
        hilog.warn(DOMAIN, 'skt', 'setWindowSystemBarProperties failed: %{public}s', e.message);
      });
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, 'skt', 'applyImmersiveLayout failed: %{public}s', err.message);
    }
  }

  onWindowStageDestroy(): void {
  }

  /**
   * 系统配置变化（含**深浅色切换**）。
   *
   * 【2026-09-30 新增】系统在深色/浅色之间切换时回调这里。
   * `sys.color.*` 资源由系统自己重取值，页面会自动跟；但有两类需要主动处理：
   *   ① 材质（`Mat`）是按主题色构建的，配色语义变了要重建 —— 与换色系同一路径；
   *   ② `innerBase()` / `floatGlassBase()` 这类**先算颜色再做 alpha** 的值，
   *      它们读的是 `Theme.isDark()` 而非系统资源，必须借一次通知让页面重绘。
   * 通知一次 `Theme.onChange` 的订阅者（各页据此刷新，`Mat.rebuild()` 也挂在上面）。
   */
  onConfigurationUpdate(newConfig: Configuration): void {
    hilog.info(DOMAIN, 'skt', 'onConfigurationUpdate colorMode=%{public}d',
      newConfig.colorMode as number);
    Theme.notifyConfigChanged();
  }

  onForeground(): void {
  }

  onBackground(): void {
  }

  /**
   * 应用已在运行时再次收到碰一碰分享（热启动）。
   * 这里只负责解析并暂存，弹窗交给 UI 侧（ShareService.onPendingImport 订阅者）。
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'skt', '%{public}s', 'Ability onNewWant');
    ShareService.handleShareWant(want).then((hit: boolean) => {
      if (hit) {
        hilog.info(DOMAIN, 'skt', '%{public}s', 'warm start share want parsed');
      }
    });
  }
}
