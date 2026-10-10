# 词典站 dictionary.xsheep.cn

英汉词典查询网站 + 后端 API。服务端单文件 Python（零第三方依赖），
发音由服务端 espeak-ng 合成，前端与管理端共用一套 API。

- **线上**：https://dictionary.xsheep.cn
- **API**：`GET /api/v1/word?w=hello`
- **授权信息**：`GET /api/v1/licenses`

## 授权（务必先读）

本站所有第三方数据的授权与「是否修改」逐项记录在
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)—— 那是 CC BY-SA 4.0 第3(a) 条
要求的举证文件，**不要删改**。

一句话版本：

| 用途 | 来源 | 许可 |
|---|---|---|
| 英文释义 | Open English WordNet | CC BY 4.0（**须同时署名 Princeton WordNet**） |
| 发音 | espeak-ng 服务端合成 | GPL-3.0（仅软件，独立进程调用，不传染） |
| 用户改写 | 本站用户 | CC BY-SA 4.0 |

**刻意不用 ECDICT 的释义** —— 它的 MIT 只覆盖软件不覆盖数据，作者 wiki 自己
列出的释义来源是商业词典站（TheFreeDictionary / linguee / Babylon 等），
授权链断裂。详见 NOTICES 第 5 节。

## 部署

只改顶部变量即可：

```bash
DOMAIN=dictionary.xsheep.cn \
SERVER_IP=61.184.12.111 \
SSH_KEY=server/61.184.12.111_id_ed25519 \
./deploy.sh
```

脚本是**幂等**的：可重复执行，词库大小一致会跳过、配置按需重写，
最后**从公网带 SNI 真实访问一次**验收。

## 生成词库

词库（26MB）不入库，需本地生成：

```bash
curl -L -o data/oewn.zip \
  https://codeload.github.com/globalwordnet/english-wordnet/zip/refs/heads/main
python3 build_lexicon.py --zip data/oewn.zip --out lexicon.db
```

产出约 **128000 词条 / 103000 义项**，耗时约 3 秒。

## 多实例 / 负载均衡

`config.json` 的 `backends[]` 就是预留的负载均衡入口：

```json
"backends": [
  { "id": "61",  "host": "127.0.0.1", "port": 8788, "weight": 1, "enabled": true },
  { "id": "184", "host": "10.0.0.5",  "port": 8788, "weight": 1, "enabled": false }
]
```

- **加机器** = 加一行配置 + 加一条 DNS 记录，**不改代码**
- `GET /healthz` 返回本机负载（loadavg / 磁盘 / 内存）+ 逐个探测各后端
- `GET /api/v1/backends` 列出节点与健康状态
- 支持 **粘性会话**：`?backend=<id>` 或 `dict_backend` cookie，
  前端据此实现「手动切换节点」

## 本机开发

```bash
cp config.json config.dev.json      # 改 host 为 127.0.0.1、端口 8789
python3 app.py --config config.dev.json
python3 selftest.py                 # 21 项接口自测（含授权闸门）
```

## API

| 端点 | 说明 |
|---|---|
| `GET /api/v1/word?w=<word>` | 查词，返回音标/词性/义项/例句 + 用户改写层 |
| `GET /api/v1/word/<word>/audio?accent=gb\|us` | 发音（WAV，espeak-ng 合成，带长缓存） |
| `GET /api/v1/batch?w=a,b,c` | 批量查（上限 50） |
| `PUT /api/v1/word` | 提交改写，**必须带 `licenseAgree: true`** |
| `GET /healthz` | 健康 + 负载 + 后端状态 |
| `GET /api/v1/stats` | 词条数/义项数/查询数/热门词 |
| `GET /api/v1/licenses` | 授权清单（前端页脚渲染用） |
| `GET /api/v1/words` | 全部单词列表，**仅限内网** |

⚠️ **刻意不提供全库 CSV/JSON 下载** —— 那会把「纳入相当部分内容的数据库」
认定为改用素材，触发 CC BY-SA 4.0 第 4 条的 ShareAlike 义务。
逐词检索展示不属于该情形。