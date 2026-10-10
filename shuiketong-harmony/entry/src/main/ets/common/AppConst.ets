/**
 * 全局常量。
 *
 * BUNDLE_NAME 必须与 AppScope/app.json5 的 bundleName 严格一致。
 * wantAgent 的 Want 必须同时指定 bundleName + abilityName：
 * 只写 abilityName、或写了不存在的包名，都会抛 16000151 Invalid wantagent object，
 * 表现为后台长时任务 / 实况窗「静默失效」（catch 吞掉，无任何界面提示）。
 */
export class AppConst {
  /** 应用包名（与 AppScope/app.json5 一致） */
  static readonly BUNDLE_NAME: string = 'com.zhikejian.app';
  /** 主 Ability 名 */
  static readonly ENTRY_ABILITY: string = 'EntryAbility';
}
