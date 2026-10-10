# 知课笺 · monorepo

课表 / 听课转写 / 词典三件套的完整源代码。

| 目录 | 内容 | 技术栈 |
|---|---|---|
| `shuiketong-harmony/` | 鸿蒙客户端「知课笺」（课表 + 听课转写 + 词典三个 Tab） | ArkTS / ArkUI / HDS |
| `dictionary-web/` | 英汉词典后端（`dictionary.xsheep.cn`） | Python 3.8 标准库，零第三方依赖 |
| `deploy/` | 部署脚本与运维说明 | bash |

---

## 一、鸿蒙客户端

### 构建

**必须 JDK 21**（DevEco 自带的 jbr 是 JDK 25，会报 `requires java >= 21` 之类的错）：

```bash
export JAVA_HOME="C:\Users\<你>\.jdks\jbr-21.0.11"
export PATH="$JAVA_HOME/bin:$PATH"          # ⚠️ 用 Windows 反斜杠形式，C:/ 形式会 spawn java ENOENT
export DEVECO_SDK_HOME="C:\Program Files\Huawei\DevEco Studio\sdk"

node "C:/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.js" \
     assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-signed.hap`

### ⚠️ 签名配置不在库里

`build-profile.json5` **故意不入库**（含本机桌面绝对路径 + DevEco 加密的密码密文）。

```bash
cp build-profile.json5.template build-profile.json5
```

然后在 DevEco Studio 里填自己的签名：`File → Project Structure → Signing Configs`

- **自动签名**最省事，但**代理提醒（`PUBLISH_AGENT_REMINDER`）功能需要手动签名** + AGC 审核过的 Profile
- 填完 DevEco 会把明文加密成密文写回本文件

⛔ **私钥（`.p12`）永远不要提交** —— 泄露等于别人能伪造你的签名包。

### 环境要求

- DevEco Studio 6.x（API 22+）
- 设备：HarmonyOS NEXT / OpenHarmony
- 已申请的权限：网络、麦克风

---

## 二、词典后端

线上：**https://dictionary.xsheep.cn**

### 本地起服务

```bash
cd dictionary-web

# 1. 生成词库（只需跑一次，约 3 秒）
#    数据源下载见 README 里的「数据来源」一节
python build_lexicon.py  --zip data/oewn.zip  --out lexicon.db
python import_ecdict.py  --csv data/ecdict.csv --db lexicon.db
python import_examples.py --zip data/cmn-eng.zip --db lexicon.db

# 2. 改 config.json 里的 lexicon / audio_dir 为绝对路径
#    ⚠️ 不要用相对路径 —— app.py 启动后会 chdir 到 /tmp

# 3. 起
python app.py --config config.json
```

### 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/word?w=<word>` | 查词（返回中英释义、考纲标签、IPA、双语例句） |
| GET | `/api/v1/word/<word>/audio?accent=gb\|us` | 英音 / 美音（WAV，espeak-ng 服务端合成） |
| PUT | `/api/v1/word` | 提交改写释义（**强制 `licenseAgree: true`**） |
| GET | `/api/v1/stats` | 词库统计 |
| GET | `/api/v1/licenses` | 授权清单（CC BY / BY-SA 的署名义务） |
| GET | `/healthz` | 健康检查 + 本机负载 + 逐个探测后端 |

### 部署

见 `deploy/README-deploy.md`。一键部署只改脚本顶部变量：

```bash
SSH_KEY=/path/to/id_ed25519 WS_PYTHON=/path/to/python bash deploy.sh
```

脚本有**四道闸门**任一不过就中止，不会留下"看起来部署完成实际 502"的局面：

1. 上传前校验词库五表齐全、`zh`/`example` 非空
2. `nginx -t` 失败即中止且不 reload（写错会让**所有站点**一起挂）
3. 五项公网 HTTP 验收（带 SNI，本机自测 200 ≠ 公网可用）
4. **深度内容校验**（不只看 200）：中文释义是否真换行、例句是否带 Tatoeba 署名、授权清单是否披露来源

### 数据来源与许可

见 `dictionary-web/THIRD-PARTY-NOTICES.md`。要点：

- 英文释义：**Open English WordNet**（CC BY 4.0，派生自 Princeton WordNet，需**同时署名两者**）
- 中文释义 + 考纲标签：**ECDICT**（MIT）
- 双语例句：**Tatoeba**（CC BY 2.0 FR，**要求署名到句子作者**）
- 发音：服务端 **espeak-ng** 合成（非第三方录音，不传染 GPL）

**刻意不提供全库 CSV/JSON 下载** —— 那会触发 CC BY-SA 第 4 条的数据库 ShareAlike 义务。

---

## 三、目录里没有什么

| 缺什么 | 为什么 |
|---|---|
| `build-profile.json5` | 含本机绝对路径 + DevEco 密文，见上文 |
| `*.p12` / `*.p7b` / `*.cer` | 私钥永不公开 |
| `lexicon.db`（26MB） | 可由三个导入脚本重新生成，不进版本库 |
| `data/*.csv`（63MB） | ECDICT 原始 CSV，同上 |
| `audio/` | espeak-ng 运行时缓存，持续膨胀 |
| `entry/build/`、`oh_modules/` | 构建产物 |

重建词库的命令在 `dictionary-web/README.md` 里。

---

## 四、许可

本仓库自有代码：**GPL-3.0-or-later**。

⚠️ 各数据源的许可**不同且有传染性差异**，使用前务必读
`dictionary-web/THIRD-PARTY-NOTICES.md`。特别是：
OEWN 是 CC BY 4.0（要求署名）、Tatoeba 是 CC BY 2.0 FR（要求署名到作者），
用户提交的释义是 CC BY-SA 4.0（有 ShareAlike）。

**GPL 是你选的**，但它约束的是"你写的代码"，
不能也不应该用来覆盖上游数据的许可条件。