# 部署说明

## 一键部署（词典站）

```bash
cd dictionary-web
SSH_KEY=/path/to/61.184.12.111_id_ed25519 \
WS_PYTHON=/path/to/python \
  bash deploy.sh
```

只需要改 `deploy.sh` 顶部的变量：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DOMAIN` | `dictionary.xsheep.cn` | 换站点只改这里 |
| `SERVER_IP` | `61.184.12.111` | |
| `SSH_USER` / `SSH_KEY` | `root` / 空 | 私钥路径必填 |
| `APP_DIR` | `/disk/www/dictionary` | **数据盘**，见下文「为什么不是 /opt」 |
| `WS_PYTHON` | 自动探测 | 本机 Python 路径（WSL/Git Bash 场景用） |

脚本是**幂等**的：词库大小一致就跳过、配置按需重写。重复执行安全。

---

## 搬迁到别的服务器

1. 改 `deploy.sh` 顶部的 `DOMAIN` / `SERVER_IP` / `SSH_KEY`
2. 在新服务器上放好泛证书（脚本从
   `/www/server/panel/vhost/ssl/xsheep.cn/` 取）
3. 在 DNS 加一条 A 记录指向新 IP
4. 跑脚本

### 负载均衡（多实例）

`config.json` 的 `backends[]` 支持配多台，**加机器 = 加一行配置 + 一条 DNS，不改代码**：

```json
{
  "instance_id": "dict-61",
  "backends": [
    { "id": "b61", "host": "10.0.0.1", "port": 8788, "weight": 1, "enabled": true },
    { "id": "b62", "host": "10.0.0.2", "port": 8788, "weight": 1, "enabled": true }
  ]
}
```

`/healthz` 会返回**本机负载**（CPU 空闲率、内存、负载均值）+ **逐个探测后端**的存活状态。

客户端可以用 `?backend=<id>` 请求指定后端（粘性会话）。

前端负载均衡用 DNS 轮询（低成本的 L4 方案）或在前面加一层
Nginx `upstream` / 云 LB —— **后端本身不感知**自己在 LB 后面。

---

## 为什么数据在 `/disk` 而不是 `/opt`

这台服务器有两块盘：

| 挂载点 | 容量 | 用途 |
|---|---|---|
| `/` | 38G（已用 65%） | 系统盘，**Docker overlay 也在吃** |
| `/disk` | 196G（仅用 4%） | 数据盘 |

且 **`/www` 与 `/disk/www` 是同一个目录**（inode 相同）——
宝塔早就把网站数据放数据盘了。

判据：`ls -ldi /www /disk/www` 比 inode。

词库 26MB 无所谓，但**音频缓存会持续膨胀**（每词两个 WAV 约 30KB，10 万词 ≈ 3GB），
放系统盘迟早撑爆。`/opt/dictionary` 留了软链指向 `/disk/www/dictionary`。

---

## 目录布局

```
/disk/www/dictionary/
├── app.py             # 单文件服务
├── config.json        # 词库路径、后端列表、监听端口
├── dictionary.service # systemd unit
├── lexicon.db         # SQLite（26MB，可重新生成）
├── audio/             # espeak-ng 缓存（持续增长）
└── build_lexicon.py / import_ecdict.py / import_examples.py

/etc/systemd/system/dictionary.service   # systemd
/www/server/panel/vhost/nginx/dictionary.xsheep.cn.conf  # nginx
/www/server/panel/vhost/cert/dictionary.xsheep.cn/      # 证书
```

---

## 排障

```bash
# 服务状态与日志
systemctl status dictionary
journalctl -u dictionary -f

# 看请求有没有真到后端
tail -f /www/wwwlogs/dictionary.xsheep.cn.log

# 后端直连（绕过 nginx，判断是哪一层的问题）
curl -s http://127.0.0.1:8788/healthz | python3 -m json.tool
```

### 几个容易踩的坑

**1. 宝塔的 nginx 日志在 `/www/wwwlogs/`，没有 `/var/log/nginx/`**

写错会让 `nginx -t` 失败、**配置加载不上、所有站点一起挂**（不是只这一个站）。

**2. ssh 客户端会往 stdout 打 post-quantum 警告**

```
WARNING: connection is not using a post-quantum key exchange method
```

所有 `$(ssh_cmd ...)` 取值比对**永远不相等**。脚本里用
`clean()` 过滤 + `awk '{print $1}'` 取列。**部署脚本的头号坑。**

**3. 传 SQLite 前必须 checkpoint**

本地服务还开着（WAL 未落盘）就 scp，远端会报
`database disk image is malformed`、服务起不来。
脚本已在上传前强制 `wal_checkpoint(TRUNCATE)` + 删 `-wal`/`-shm`。

**4. 远程命令里绝不能出现英文撇号 `'`**

会被截断整段、静默跑一半。

**5. 验证必须带 SNI**

```bash
curl -sk --resolve dictionary.xsheep.cn:443:61.184.12.111 https://dictionary.xsheep.cn/
```

只发 `-H Host:` 不发 SNI 会落默认 vhost 返回 400（易误判"没生效"）。
**「源站本机自测通过」≠「公网可用」** —— 在错误的机器上 curl 回环也会返回 200。

**6. 看部署日志用 `head` 不是 `tail`**

关键段（校验 / 传输）在前半段，比后半段（验收）更重要。

---

## 鸿蒙客户端部署

见 `../README.md` 第一节。要点：

- 构建必须 **JDK 21**，且 `JAVA_HOME` 用 Windows 反斜杠形式
- `build-profile.json5` 从 `.template` 拷贝后填自己的签名
- 代理提醒功能需要手动签名 + AGC 审核过的 Profile，
  且**必须先调用 `requestEnableNotification` 取得用户通知授权**
  （当前代码里还没调用，不做的话会静默降级成进程内通知）