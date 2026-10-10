# 知课笺 HarmonyOS 端

DevEco Studio 5（API 12+）工程，ArkTS + ArkUI。功能与 Android 端对齐：

- 语音识别：**鸿蒙系统识别（Core Speech Kit，端侧离线引擎）**，模型由系统提供、
  无需打包；可切云端识别（voice.xsheep.cn）。两者运行中互为降级（系统不可用→云端，
  云端连续失败→回退系统）
- 端侧规则问题检测（三档特征，含老师找人/点名/回答话术）
- 问题列表 + 「垂询」：自动取问题前 90 秒相关上下文（600 字）+ 提示词，客户端直连 OpenAI 兼容 LLM 流式作答
- 深度思考开关：注入 `enable_thinking`，解析 `reasoning_content` / `reasoning`，思考过程单独展示
- 实况窗（Live View Kit）：锁屏/状态栏胶囊展示听讲时长与提问状态
- 服务器检测增强（wss://skt.xsheep.cn/ws）

## 构建

1. DevEco Studio 打开本目录（harmony/）
2. 自动同步依赖（工程已无第三方依赖；若 oh_modules 里残留旧 sherpa_onnx，可删掉 oh_modules 后重新 Sync）
3. `Build > Build Hap(s)/APP(s) > Build Hap(s)` 出包；真机需要签名（File > Project Structure > Signing Configs 自动签名）

**不需要复制任何模型文件**——本地识别走系统 Core Speech Kit（仅支持中文、需真机，
模拟器无语音服务会自动降级云端识别）。

## 已知风险（构建时如报错按此核对）

- **实况窗已接入真实现**（`@kit.LiveViewKit` / `liveViewManager`，状态机：聆听中→老师提问→
  AI 思考中→答案已生成）。锁屏胶囊真正显示需要 **AGC「实况窗」权益**：AppGallery Connect →
  我的项目 → 申请实况窗权益，审批通过后签名证书才带该能力；未申请时调用报错，
  日志会记录，主功能不受影响。
- **悬浮窗已移除**（上架合规）：原 `FloatWindowService` / `pages/FloatWindow` / 设置开关已删除，
  也不再声明 `ohos.permission.SYSTEM_FLOAT_WINDOW`（system_basic 受限权限，需 AGC 给发布 Profile
  勾选 ACL 才能通过准入检测）。要恢复：AGC 给发布 Profile 加该受限权限 → module.json5 加回声明 →
  按需重建服务与页面。信息展示由实况窗 + 应用内页面承担。
- Core Speech Kit 约束：`writeAudio` 单次仅支持 640/1280 字节 PCM（代码内已按 1280B 切块）；
  长语音模式 `recognizerMode: 'long'`，vadEnd 1.5s 自动断句，另有「文本停更 1.8s」兜底成句 + 相邻去重。
- 后台长时任务走 `@ohos.resourceschedule.backgroundTaskManager`（OpenHarmony 原生），
  AUDIO_RECORDING 模式需 API 12 真机；模拟器不支持音频采集。
- router/pushUrl/getParams 等编译 WARN（deprecated）不影响构建，后续可迁移 Navigation。
- 免签调试：DevEco「自动签名」即可安装自用；分发要出 release 签名包。

## 课表

- 主页改为主页容器 `pages/Main`：底部双 Tab —— **课表**（默认）/ **听课**。
- 作息按学校实际录入：**14 节**，上午 1-5（08:00-12:15）、下午 6-10（14:00-18:15）、
  晚上 11-14（19:00-22:15）；每节 45 分钟，大节内小课间 5 分钟、大节之间 15 分钟。
- 课表第一列 = **开课日所在星期**（课表页「设置」里填开课日 yyyy-MM-dd），
  并据此推算当前周次与每列日期；不在本周上课的课程块淡显。
- 导入：`pages/ImportSchedule` 内嵌教务课表页（`jw.stdu.edu.cn` 正方教务），
  用户自行登录 → 点「抓取课表」→ 页面内调用 `/kbcx/xskbcx_cxXsKb.html` 取 `kbList` JSON
  → 经 `javaScriptProxy` 桥接回应用解析入库。账号密码只输入在教务页面，应用不接触。

## 目录

```
entry/src/main/ets/
├── common/AppState.ets          全局状态 + 配置持久化 + 问题列表 + 转写历史
├── common/CourseStore.ets       课表模型 + 持久化 + 正方教务课表解析 + 周次/星期推算
├── common/SectionTimes.ets      作息时间表（14 节：上午 1-5 / 下午 6-10 / 晚上 11-14）
├── common/AppConst.ets          包名 / Ability 名单一来源
├── entryability/EntryAbility.ets
├── pages/Main.ets               主页容器：底部双 Tab（课表 / 听课）
├── pages/ImportSchedule.ets     课表导入：内嵌教务页面 + JS 抓取
├── pages/QuestionDetail.ets     详情页：思考开关 / 思考过程 / 答案 / 相关上下文
├── pages/Settings.ets           设置：LLM 三件套 / 服务器 / 日志
├── view/CourseTableView.ets     课表视图：按开课日轮转星期列 + 按节次合并课程块
├── view/ListenView.ets          听课视图：实时转写 + 问题列表 + 启停（原 pages/Index）
└── service/
    ├── AsrService.ets           AudioCapturer + Core Speech Kit 系统识别 / 云端识别 + 互降级
    ├── LiveViewService.ets      实况窗状态机（liveViewManager start/update/stop）
    ├── QuestionDetector.ets     三档规则检测（找人/点名/回答）
    ├── TranscriptBuffer.ets     5 分钟环形缓冲 + windowBefore(90s, 600字)
    ├── LlmClient.ets            OpenAI 兼容 SSE 流式（reasoning 双字段兼容）
    ├── LlmRunner.ets            垂询执行器（上下文组装 + 状态写回）
    ├── WsClient.ets             检测服务器 WS（自动重连）
    └── Runtime.ets              麦克风权限 + 后台长时任务
```