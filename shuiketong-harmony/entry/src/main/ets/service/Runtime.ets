import { abilityAccessCtrl, wantAgent, Permissions } from '@kit.AbilityKit';
import { common } from '@kit.AbilityKit';
import { Want } from '@kit.AbilityKit';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppState } from '../common/AppState';
import { AppConst } from '../common/AppConst';

/**
 * 权限申请 + 后台长时任务（音频录制保活）。
 * OpenHarmony SDK：backgroundTaskManager 从 @ohos.resourceschedule.backgroundTaskManager 导入。
 */
export class Runtime {
  /** 申请麦克风权限；返回是否授予。 */
  static async requestMicPermission(ctx: common.UIAbilityContext): Promise<boolean> {
    const atManager = abilityAccessCtrl.createAtManager();
    const perms: Array<Permissions> = ['ohos.permission.MICROPHONE'];
    try {
      const result = await atManager.requestPermissionsFromUser(ctx, perms);
      for (const r of result.authResults) {
        if (r !== 0) {
          return false;
        }
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 申请后台长时任务（AUDIO_RECORDING），录音可越过后台限制。 */
  static async startKeepAlive(ctx: common.UIAbilityContext): Promise<void> {
    try {
      // wantAgent 必须同时给出 bundleName + abilityName，否则抛 16000151
      // Invalid wantagent object -> startBackgroundRunning 失败、后台录音保活静默失效
      const want: Want = {
        bundleName: AppConst.BUNDLE_NAME,
        abilityName: AppConst.ENTRY_ABILITY,
      };
      const info: wantAgent.WantAgentInfo = {
        wants: [want],
        requestCode: 0,
        operationType: wantAgent.OperationType.START_ABILITY,
      };
      const agentObj = await wantAgent.getWantAgent(info);
      // 经典三参签名，兼容所有 SDK 版本
      await backgroundTaskManager.startBackgroundRunning(
        ctx,
        backgroundTaskManager.BackgroundMode.AUDIO_RECORDING,
        agentObj
      );
      AppState.log('后台保活已开启（长时任务 AUDIO_RECORDING）');
    } catch (e) {
      // 不阻塞前台运行，但必须留痕：
      // 这里失败就等于「切后台/锁屏会被系统清理」，此前静默吞异常导致一直查不出原因
      const err = e as BusinessError;
      AppState.log(`后台保活申请失败 code=${err.code} ${err.message}`
        + '（16000151=want 参数无效 201=权限未声明 9800005=长时任务校验失败）');
    }
  }

  static async stopKeepAlive(ctx: common.UIAbilityContext): Promise<void> {
    try {
      await backgroundTaskManager.stopBackgroundRunning(ctx);
    } catch (e) {
      // ignore
    }
  }
}