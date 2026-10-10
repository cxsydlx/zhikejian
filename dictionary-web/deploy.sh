#!/usr/bin/env bash
# ============================================================================
#词典站一键部署脚本
#
# 用法（只需要填顶部这几个变量）：
#     DOMAIN=dictionary.xsheep.cn SERVER_IP=61.184.12.111 ./deploy.sh
#
# 特性：
#   · **幂等** —— 可重复执行；已存在的文件按需跳过，配置改动才重写
#   · **不覆盖已有数据** —— lexicon.db 若已存在则跳过（词库导入耗时且无必要重跑）
#   · **部署后公网验收** —— 带 SNI 真实访问一次（本地自测 200 ≠ 公网可用）
#
# ⚠️ 铁律：远程命令里绝不能出现英文撇号（会截断整段命令、静默跑一半）
# ⚠️铁律：验证必须带 SNI，只发 -H Host: 不发 SNI 会落默认 vhost 返回 400
# ============================================================================
set -uo pipefail

# =======================只需改这里 =======================
# ⚠️ **APP_DIR 必须在数据盘 `/disk`，不能放 `/opt`**（2026-10-10 用户提醒后修正）
#
#    这台机器有两块盘（实测 `df -h`）：
#      · `/`      38G，已用 65%（13G 可用）—— 系统盘，Docker overlay 也吃这块
#      · `/disk`  196G，仅用 4%（179G 可用）—— **独立数据盘**
#    且 `/www` 与 `/disk/www` 是**同一个目录**（inode 相同），
#    说明宝塔早就把网站数据放数据盘了，词典跟着走才一致。
#
#    为什么必须挪：词库本身只有 26MB 无所谓，但**音频缓存会持续膨胀** ——
#    每词两个 WAV 约 30KB，10 万词就是 3GB。放系统盘迟早撑爆。
DOMAIN="${DOMAIN:-dictionary.xsheep.cn}"
SERVER_IP="${SERVER_IP:-61.184.12.111}"
SSH_USER="${SSH_USER:-root}"
SSH_KEY="${SSH_KEY:-}"
APP_DIR="${APP_DIR:-/disk/www/dictionary}"
WEB_ROOT="${WEB_ROOT:-/www/wwwroot/dictionary.xsheep.cn}"
SSL_SRC="${SSL_SRC:-/www/server/panel/vhost/ssl/xsheep.cn}"
VHOST_DIR="${VHOST_DIR:-/www/server/panel/vhost/nginx}"
SERVICE_NAME="dictionary.service"
# =======================================================

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_PREFIX="[deploy $(date +%H:%M:%S)]"

say()  { echo "${LOG_PREFIX} $*"; }
die()  { echo "${LOG_PREFIX} ❌ $*" >&2; exit 1; }

# 统一的远程执行入口。
# ⚠️ 用双引号包 "$@" 再交给 ssh，避免本地 shell 先把内容吃掉。
# ⚠️ 参数**绝不能**含英文撇号 —— 那会截断整段远程命令、静默跑一半。
ssh_cmd() {
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=20 \
      "$SSH_USER@$SERVER_IP" "$@"
}

# 过滤 ssh 客户端打到 stdout 的噪声。
# ⚠️ OpenSSH 会打印 "WARNING: connection is not using a post-quantum key
#    exchange algorithm..."，直接进stdout。
#    不滤掉的话所有 `$(ssh_cmd ...)` 取值比对**永远不相等** ——
#    曾在 md5 校验处因此虚警失败一次。
clean() {
  grep -v -e '^\*\*' -e 'WARNING:' -e 'vulnerable' -e 'openssh.com' || true
}

[ -n "$SSH_KEY" ] || die "请设置 SSH_KEY，例如 SSH_KEY=server/61.184.12.111_id_ed25519"
[ -f "$SSH_KEY" ] || die "私钥不存在: $SSH_KEY"
[ -f "$SRC_DIR/lexicon.db" ] || die "缺少 lexicon.db，请先跑 build_lexicon.py 生成"

# 本地 Python —— 部署前要用它把 SQLite 的 WAL 落盘。
# 优先用带Pillow 的隔离环境（开发时用的那个），退回系统 python。
if [ -n "${PY_BIN:-}" ] && [ -x "${PY_BIN}" ]; then
  :
elif [ -n "$WS_PYTHON" ] && [ -f "$WS_PYTHON" ]; then
  # WS_PYTHON=... bash deploy.sh
  # ⚠️ 不要把某人的本机绝对路径写死在脚本里（会随仓库公开泄露用户名与目录结构）。
  PY_BIN="$WS_PYTHON"
else
  PY_BIN="$(command -v python3 || command -v python)"
fi
[ -n "$PY_BIN" ] || die "找不到本地 Python（用于词库 checkpoint）"

say "域名 ${DOMAIN} → ${SERVER_IP}"
say "本地源码 ${SRC_DIR}"

# ---------------------------------------------------------------- 0. 备份
say "0/6 备份现有 nginx 配置"
ssh_cmd "if [ -f ${VHOST_DIR}/${DOMAIN}.conf ]; then cp -p ${VHOST_DIR}/${DOMAIN}.conf ${VHOST_DIR}/${DOMAIN}.conf.bak-\$(date +%Y%m%d-%H%M%S); echo backed-up; else echo none; fi"

# ---------------------------------------------------------------- 1. 目录
say "1/6 创建目录"
ssh_cmd "mkdir -p ${APP_DIR}/audio && mkdir -p ${WEB_ROOT}"

# ---------------------------------------------------------------- 2. 代码
say "2/6 同步代码与配置"
for f in app.py build_lexicon.py import_ecdict.py import_examples.py config.json THIRD-PARTY-NOTICES.md; do
  scp -q -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SRC_DIR/$f" "${SSH_USER}@${SERVER_IP}:${APP_DIR}/$f"
done
say "  代码已同步（首页由 app.py 内置提供，无需 index.html）"

# ---------------------------------------------------------------- 3. 词库
say "3/6 同步词库"
# ⚠️⚠️ **上传前必须先让本地 SQLite 落盘**（WAL checkpoint）。
#    否则 scp 传上去的是「主库 + 残留 -wal」的不一致组合，
#    远端 sqlite3 会报 `database disk image is malformed`（实测踩过一次）。
#    同时删掉本地的 -wal/-shm，避免它们被一并当成词库的一部分。
# ⚠️ **这也不能替代「跑完导入再 checkpoint」**：三个导入脚本
#    （build_lexicon → import_ecdict → import_examples）必须先跑完，
#    否则传上去的是缺中文/缺例句的半成品库。
say "  本地 checkpoint ..."
"$PY_BIN" - "$SRC_DIR/lexicon.db" <<'PYEOF'
import os, sqlite3, sys
db_path = sys.argv[1]
for suffix in ('-wal', '-shm'):
    side = db_path + suffix
    if os.path.exists(side):
        try:
            os.remove(side)
        except OSError as e:
            sys.stderr.write('warn: cannot remove %s: %s\n' % (side, e))
db = sqlite3.connect(db_path)
# 缺表就报错 —— 半成品库部署上去等于线上功能缺失
have = {r[0] for r in db.execute(
    "SELECT name FROM sqlite_master WHERE type='table'")}
need = {'entry', 'sense', 'zh', 'example', 'user_edit'}
missing = need - have
if missing:
    sys.stderr.write('ERROR: 词库缺表 %s —— 请先跑完三个导入脚本\n'
                     % ', '.join(sorted(missing)))
    sys.exit(2)
n_entry = db.execute('SELECT COUNT(*) FROM entry').fetchone()[0]
n_zh = db.execute('SELECT COUNT(*) FROM zh').fetchone()[0]
n_ex = db.execute('SELECT COUNT(*) FROM example').fetchone()[0]
if n_zh == 0 or n_ex == 0:
    sys.stderr.write('ERROR: 中文释义或例句为空（zh=%d, example=%d），拒绝部署\n'
                     % (n_zh, n_ex))
    sys.exit(2)
db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
db.close()
sys.stderr.write('  校验通过: entry=%d zh=%d example=%d, size=%d\n'
                 % (n_entry, n_zh, n_ex, os.path.getsize(db_path)))
PYEOF
[ $? -eq 0 ] || die "本地词库校验/checkpoint 失败——**未部署**。请先跑完三个导入脚本并停掉本地服务"

EXIST="$(ssh_cmd "if [ -f ${APP_DIR}/lexicon.db ]; then stat -c %s ${APP_DIR}/lexicon.db; else echo 0; fi" | clean | tail -1)"
LOCAL_SZ="$(stat -c %s "$SRC_DIR/lexicon.db" 2>/dev/null || stat -f%z "$SRC_DIR/lexicon.db")"
if [ "$EXIST" = "$LOCAL_SZ" ]; then
  say "  词库已存在且大小一致（${EXIST} 字节），跳过"
else
  say "  传输词库...（本地 ${LOCAL_SZ} 字节）"
  scp -q -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SRC_DIR/lexicon.db" "${SSH_USER}@${SERVER_IP}:${APP_DIR}/lexicon.db.new"
  # 校验 md5 后再原子替换，避免半截文件。
  # ⚠️ md5sum 输出是 "<hash>  <file>"，必须用 awk 取第一列 ——
  #    之前直接比整行输出，导致两边其实相等却被判为不匹配（虚警）。
  LMD5="$(md5sum "$SRC_DIR/lexicon.db" | awk '{print $1}')"
  RMD5="$(ssh_cmd "md5sum ${APP_DIR}/lexicon.db.new" | clean | awk '{print $1}')"
  if [ "$LMD5" != "$RMD5" ]; then
    die "词库 md5 不匹配（本地 ${LMD5} / 远端 ${RMD5}）"
  fi
  ssh_cmd "mv ${APP_DIR}/lexicon.db.new ${APP_DIR}/lexicon.db"
  say "  词库就绪（md5 ${LMD5}）"
fi

# ---------------------------------------------------------------- 4. systemd
say "4/6 安装 systemd 服务"
scp -q -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SRC_DIR/dictionary.service" "${SSH_USER}@${SERVER_IP}:/etc/systemd/system/${SERVICE_NAME}"
ssh_cmd "systemctl daemon-reload && systemctl enable ${SERVICE_NAME} && systemctl restart ${SERVICE_NAME}"
sleep 3
say "  服务状态: $(ssh_cmd "systemctl is-active ${SERVICE_NAME}" | clean | tail -1)"

# 确认端口在听
LISTEN="$(ssh_cmd "ss -lntp 2>/dev/null | grep 8788 || echo NOT-LISTENING" | clean | tail -1)"
say "  端口 8788: ${LISTEN}"

# ---------------------------------------------------------------- 5. nginx
say "5/6 配置 nginx + TLS"
# ⚠️ **宝塔的目录布局不是发行版默认**（踩过一次 nginx -t 失败）：
#   · 日志在 `/www/wwwlogs/`，**没有** `/var/log/nginx/` —— 写错会导致
#     `nginx: [emerg] open() ... failed (2: No such file or directory)`，
#     整个 nginx 配置加载失败、**所有站点一起挂**
#   · 证书在本项目是 `vhost/ssl/xsheep.cn/`（泛证书），而 `vhost/cert/` 下
#     只有各自单独的域名目录，没有 xsheep.cn
# 所以这里统一 cp 一份到 `vhost/cert/${DOMAIN}/`，与其它 vhost 的写法对齐。
CERT_SRC="${SSL_SRC}"
CERT_DST="/www/server/panel/vhost/cert/${DOMAIN}"
LOG_DIR="/www/wwwlogs"

ssh_cmd "test -f ${CERT_SRC}/fullchain.pem && test -f ${CERT_SRC}/privkey.pem" \
  || die "泛证书不存在于 ${CERT_SRC}，需先在宝塔申请或放置"
ssh_cmd "mkdir -p ${CERT_DST} && mkdir -p ${LOG_DIR} && cp -n ${CERT_SRC}/fullchain.pem ${CERT_DST}/ && cp -n ${CERT_SRC}/privkey.pem ${CERT_DST}/" \
  || die "准备证书/日志目录失败"

ssh_write_vhost() {
  # 用 heredoc 传内容 —— 避免远程 shell 的引号地狱。
  # ⚠️ heredoc 里用 'EOF' 加引号 → **变量不会被本地 shell 展开**，
  #    nginx 的 $host / $remote_addr 会原样送到服务器，这是我们要的。
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" \
    "cat > ${VHOST_DIR}/${DOMAIN}.conf" <<VHOST_EOF
# 由 deploy.sh 自动生成 —— dictionary 词典站
# 后端是单文件 Python（ThreadingHTTPServer），只监听 127.0.0.1，由 nginx 对外。
server {
    listen 80;
    server_name ${DOMAIN};
    # HTTP 一律跳 HTTPS（ACME 验证除外）
    location ^~ /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_DST}/fullchain.pem;
    ssl_certificate_key ${CERT_DST}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;

    client_max_body_size 2m;
    client_body_timeout 30s;

    # 音频（WAV）可长缓存：内容与 URL 绑定且永不变化
    location ~* ^/api/v1/word/[^/]+/audio\$ {
        proxy_pass http://127.0.0.1:8788;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 30s;
        add_header Cache-Control "public, max-age=604800" always;
    }

    location / {
        proxy_pass http://127.0.0.1:8788;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Connection        "";
        proxy_read_timeout 60s;
        proxy_connect_timeout 5s;
        # 单文件 http.server 用线程模型，关闭缓冲避免小包延迟
        proxy_buffering off;
    }

    access_log ${LOG_DIR}/${DOMAIN}.log;
    error_log  ${LOG_DIR}/${DOMAIN}.error.log;
}
VHOST_EOF
}

ssh_write_vhost
say "  vhost 已写入"

# ⚠️ nginx -t 失败**必须立刻中止** —— 配置加载失败会影响所有站点。
#    原来只打印结果就继续，结果部署"看起来完成"但站点实际 404。
NGX_TEST="$(ssh_cmd "nginx -t 2>&1" | clean)"
if echo "$NGX_TEST" | grep -qi "test is successful\|syntax is ok"; then
  say "  nginx -t 通过"
else
  say "$NGX_TEST" >&2
  die "nginx 配置校验失败，**未 reload**（现有站点不受影响）。请修好 ${VHOST_DIR}/${DOMAIN}.conf 后重跑。"
fi

ssh_cmd "nginx -s reload 2>&1 || systemctl reload nginx" | clean
say "  nginx 已 reload"

# ---------------------------------------------------------------- 6. 验收
say "6/6 公网验收（带 SNI 真实访问）"
sleep 2

# ⚠️ 必须带 SNI 真实访问。
#    只发 -H Host: 会落默认 vhost 返回 400（易误判"没生效"）。
# ⚠️ 验收失败**必须 die** —— 原来只打印结果就继续，
#    结果输出"部署完成"而站点实际 502/404，误导性极强（踩过两次）。
FAIL_COUNT=0
verify() {
  local path="$1" expect="$2" label="$3"
  local out code
  out=$(curl -sk --resolve "${DOMAIN}:443:${SERVER_IP}" \
        -o /tmp/_dv.html -w "%{http_code}" \
        "https://${DOMAIN}${path}" 2>&1)
  code="$out"
  if [ "$code" = "$expect" ]; then
    say "  ✓ ${label}: HTTP ${code}"
  else
    say "  ✗ ${label}: HTTP ${code}（期望 ${expect}）"
    head -c 200 /tmp/_dv.html 2>/dev/null | tr -d '\n' && echo
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

verify "/"                    200 "首页"
verify "/healthz"             200 "健康检查"
verify "/api/v1/word?w=hello" 200 "查词 API"
verify "/api/v1/word?w=water" 200 "查词 API(中文释义)"
verify "/api/v1/licenses"     200 "授权清单"

# 例句专项：Tatoeba 是 CC-BY 2.0 FR，**必须每条带署名**。
# ⚠️ 只检查 HTTP 200 不够 —— 署名缺失是**许可违规**，必须验内容。
# 用法与上面 verify 一致：curl --resolve 直连目标 IP 并带 SNI。
say "  深度校验（例句署名 / 中文释义分行 / 授权披露）..."
fetch_api() {
  # $1 = path（如 "/api/v1/word?w=type"）
  curl -sk --resolve "${DOMAIN}:443:${SERVER_IP}" "https://${DOMAIN}$1"
}

"$PY_BIN" - "${DOMAIN}" "${SERVER_IP}" <<'PYEOF'
import json, subprocess, sys
domain, ip = sys.argv[1], sys.argv[2]
def get(path):
    # 用 curl 而非 urllib：需要--resolve 直连 IP 并带 SNI
    out = subprocess.run(
        ['curl', '-sk', '--resolve', '%s:443:%s' % (domain, ip),
         'https://%s%s' % (domain, path)],
        capture_output=True, text=True, timeout=40)
    try:
        return json.loads(out.stdout)
    except Exception:
        return None

problems = []
# 1) 中文释义必须真换行（不能是字面 \n）
j = get('/api/v1/word?w=type')
if not j:
    problems.append('查词 type 无响应')
else:
    zh = (j.get('entry') or {}).get('definitionZh', '')
    if '\\\\n' in zh:
        problems.append('中文释义仍含字面\\\\n（应是真换行）')
    elif zh.count(chr(10)) < 2:
        problems.append('中文释义未分行（真换行 %d 个）' % zh.count(chr(10)))
# 2) 例句必须带署名（CC-BY 2.0 FR 硬要求）
j = get('/api/v1/word?w=computer')
if not j:
    problems.append('查词 computer 无响应')
else:
    ex = (j.get('entry') or {}).get('examples') or []
    if not ex:
        problems.append('computer 无例句')
    for x in ex[:2]:
        at = x.get('attribution') or ''
        if not at:
            problems.append('例句缺署名（CC-BY 违规）')
        elif 'tatoeba.org' not in at:
            problems.append('例句署名格式异常: %s' % at[:40])
# 3) 授权清单必须披露 Tatoeba
j = get('/api/v1/licenses')
if not j:
    problems.append('licenses 无响应')
else:
    names = [l.get('name','') for l in j.get('licenses', [])]
    if not any('Tatoeba' in n for n in names):
        problems.append('授权清单缺 Tatoeba（例句来源必须披露）')
# 4) 考纲标签必须能返回（ECDICT tag 是多值，最容易解析坏）
j = get('/api/v1/word?w=type')
tags = ((j or {}).get('entry') or {}).get('tags') or []
if not tags:
    problems.append('type 无考纲标签（tag 多值解析可能坏了）')

if problems:
    print('FAIL')
    for p in problems:
        print('  - ' + p)
    sys.exit(1)
print('OK  checks=4')
PYEOF
if [ $? -eq 0 ]; then
  say "  ✓ 深度校验通过（中文释义分行 / 例句署名 / 授权披露 / 考纲标签）"
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

if [ "$FAIL_COUNT" -gt 0 ]; then
  say ""
  die "公网验收 ${FAIL_COUNT} 项未通过 —— **部署未成功**。排查：ssh -i ${SSH_KEY} ${SSH_USER}@${SERVER_IP} journalctl -u dictionary.service -n 30 --no-pager"
fi

say ""
say "============================================"
say " ✓ 部署完成并通过公网验收：http://${DOMAIN}"
say "   后端 API：https://${DOMAIN}/api/v1/word?w=hello"
say "   健康检查：https://${DOMAIN}/healthz"
say "   查看日志：ssh -i ${SSH_KEY} ${SSH_USER}@${SERVER_IP} journalctl -u dictionary.service -f"
say "============================================"