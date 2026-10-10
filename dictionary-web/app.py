#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
词典后端服务 —— 单文件、零第三方依赖（只用Python 3.8 标准库）。

## 为什么不用 Flask/FastAPI
服务器 Python 3.8.10 且不保证有 pip 包；`mcadmin` 那套也是单文件 http.server。
本服务用 `http.server` + `ThreadingHTTPServer`，并发靠线程。

## 版权与合规（改代码前先读这段）
- 英文释义来自 **Open English WordNet**（CC BY 4.0，派生自 Princeton WordNet）
  → 展示端**必须**同时署名两者，见`/api/v1/licenses`
- **绝对不提供全库下载**（CSV/JSON 批量导出）。
  CC BY-SA 第 4 条会把"纳入相当部分内容的数据库并对外分发"认定为改用素材，
  触发 ShareAlike 义务。逐词检索展示不属于该情形。
- 用户改释义走 `PUT /api/v1/word`，必须带 `licenseAgree: true`，
  落库时记`created_at` + `submitter` + `license`（CC BY-SA 第 3(a) 条要求
  "表明是否曾修改"，这两个字段就是举证材料）。
- 发音由**服务端 espeak-ng 自己合成**（英音 en-gb / 美音 en-us），
  不使用任何第三方真人录音，零授权风险。

## 多实例 / 负载均衡（用户要求：预留入口，支持查负载与切换）
`config.json` 的 `backends[]` 是一个后端列表，可写多台：
    "backends": [
      {"id":"61",   "host":"127.0.0.1","port":8788, "weight":1, "enabled":true},
      {"id":"184",  "host":"10.0.0.5", "port":8788, "weight":1, "enabled":false}
    ]
- 加机器 = 加一行配置 + 加一条 DNS 记录，**不改本文件代码**
- `GET /healthz` 返回本机负载 + 逐个探测各 backend
- `GET /api/v1/backends` 供前端展示"当前节点"，配合 `X-Dict-Backend` 响应头
  与 `dict_backend` cookie 做**粘性会话**，将来可加"手动切换节点"UI

用法:
    python3 app.py --config /opt/dictionary/config.json
"""

import argparse
import json
import os
import re
import socket
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from http.cookies import SimpleCookie

APP_VERSION = '1.0.0'
LOG_LOCK = threading.Lock()

# 词性代码 → (英文, 中文)
POS_LABEL = {
    'n': ('noun', '名词'),
    'v': ('verb', '动词'),
    'a': ('adjective', '形容词'),
    'r': ('adverb', '副词'),
    's': ('adjective', '形容词'),
}

# ECDICT 的 `tag` 字段 → 中文可读标签（学生向，考纲等级是刚需）
TAG_ZH = {
    'zk': '中考',
    'gk': '高考',
    'cet4': '四级',
    'cet6': '六级',
    'ky': '考研',
    'ielts': '雅思',
    'toefl': '托福',
    'grel': 'GRE',
}

# ⚠️ **两套来源的授权不同，署名必须分开，不能合并成一个字符串**。
#    英文释义 = OEWN(CC BY 4.0，须双署名 Princeton)；中文释义 = ECDICT(MIT)。
SOURCES = [
    {'field': 'senses', 'label': '英文释义',
     'source': 'Open English WordNet', 'license': 'CC BY 4.0',
     'modified': False,
     'note': '派生自 Princeton WordNet，须同时署名两者；本站未作修改'},
    {'field': 'definitionZh', 'label': '中文释义',
     'source': 'ECDICT', 'license': 'MIT',
     'modified': False,
     'note': '音标已由旧式ASCII 规范化为 IPA（仅符号规范化，不改读音）'},
]

# 只有英文释义（该词在 ECDICT 里没有中文条目）
SOURCES_EN_ONLY = [SOURCES[0]]


def log(msg):
    """带时间戳的 stderr 日志（systemd 会收进 journal）。"""
    with LOG_LOCK:
        sys.stderr.write('[%s] %s\n' % (time.strftime('%Y-%m-%d %H:%M:%S'), msg))
        sys.stderr.flush()


# ===========================================================================
# 词库
# ===========================================================================
class Lexicon(object):
    """SQLite 只读连接池（每线程一个连接，SQLite 不适合跨线程共享）。"""

    def __init__(self, path):
        self.path = path
        self._local = threading.local()
        self._all = []

    def conn(self):
        c = getattr(self._local, 'conn', None)
        if c is None:
            c = sqlite3.connect(self.path, timeout=8)
            c.row_factory = sqlite3.Row
            self._local.conn = c
        return c

    def lookup(self, word):
        """返回词条 dict；查不到返回 None。"""
        db = self.conn()
        row = db.execute(
            'SELECT word, pos, ipa, ipa_variant, senses_json FROM entry WHERE word = ?',
            (word,)
        ).fetchone()
        zh = db.execute(
            'SELECT definition, phonetic, pos, collins, oxford, tag, exchange '
            'FROM zh WHERE word = ?', (word,)
        ).fetchone()
        if row is None and zh is None:
            return None

        # ---- 英文释义（OEWN, CC BY 4.0）----
        senses = []
        pos_en, pos_zh = '', ''
        ipa = ''
        if row is not None:
            ipa = row['ipa']
            pos_en, pos_zh = POS_LABEL.get(row['pos'], (row['pos'], row['pos']))
            for s in json.loads(row['senses_json']):
                sr = db.execute(
                    'SELECT gloss, examples FROM sense WHERE synset = ?',
                    (s['synset'],)
                ).fetchone()
                gloss = sr['gloss'] if sr else None
                if not gloss:
                    continue
                try:
                    ex = json.loads(sr['examples']) if sr else []
                except Exception:
                    ex = []
                senses.append({
                    'rank': s['rank'],
                    'synset': s['synset'],
                    'gloss': gloss,
                    'examples': ex,
                })

        # ---- 中文释义（ECDICT, MIT）+ 考纲标签 ----
        # ⚠️ 两套来源**物理隔离**（entry/sense 表 vs zh 表），授权也不同，
        #    所以 source 要分开报，不能合并成一个字符串 ——
        #    前端页脚要按来源分别署名。
        zh_def = zh['definition'] if zh else ''
        # 考纲标签转中文可读名（来自 ECDICT 的 tag 字段）
        # ⚠️ tag 是**空格分隔的多值**（如 "zk gk ielts"），
        #    之前用 TAG_ZH.get(整串) 精确匹配 → 永远取不到（全空）。
        #    必须 split 逐个查。
        tags = []
        if zh and zh['tag']:
            for raw in (zh['tag'] or '').split():
                key = raw.strip()
                if len(key) > 0:
                    tags.append(TAG_ZH.get(key, key))
        return {
            'word': word,
            'pos': (zh['pos'] if zh and zh['pos'] else (row['pos'] if row else '')),
            'posLabel': pos_en,
            'posLabelZh': pos_zh,
            # ⚠️ 音标优先用 **ECDICT 的**：实测它的覆盖率更高
            #    （如 water 在 OEWN 里音标是空的，ECDICT 有 ˈwɒːtə），
            #    且已规范化为 IPA。OEWN 的作为兜底。
            'ipa': (zh['phonetic'] if zh and zh['phonetic'] else ipa),
            'ipaVariant': row['ipa_variant'] if row else None,
            'senses': senses,
            'definitionZh': zh_def,
            # 双语例句（Tatoeba, CC-BY 2.0 FR）——**必须带署名**，
            # 只写"来自 Tatoeba"不满足 CC-BY 的署名义务。
            'examples': self.examples_of(word),
            # 考纲标签（gk/cet4/cet6/ielts/toefl/grel）
            'tags': tags,
            # 星级：柯林斯 1-5、牛津 3000 标记
            'collins': zh['collins'] if zh else None,
            'oxford': (bool(zh['oxford']) if zh and zh['oxford'] else None),
            # 屈折变化（复数/过去式等），对学生有用
            'exchange': zh['exchange'] if zh else None,
            'sources': SOURCES if zh_def else SOURCES_EN_ONLY,
        }

    def examples_of(self, word):
        """取该词的双语例句（Tatoeba）。

        ⚠️ `attribution` 是 **CC-BY 2.0 FR 的硬性要求** —— 必须署名到句子作者
        （manythings 的数据里已带好 Tatoeba ID 与用户名），前端必须展示。
        """
        db = self.conn()
        rows = db.execute(
            'SELECT en, zh, attribution FROM example WHERE word = ? LIMIT 3',
            (word,)
        ).fetchall()
        return [{'en': r['en'], 'zh': r['zh'], 'attribution': r['attribution']}
                for r in rows]

    def user_edit(self, word):
        db = self.conn()
        r = db.execute(
            'SELECT definition, note, submitter, created_at, license '
            'FROM user_edit WHERE word = ?', (word,)
        ).fetchone()
        if r is None:
            return None
        return {
            'definition': r['definition'],
            'note': r['note'],
            'submitter': r['submitter'],
            'createdAt': r['created_at'],
            'license': r['license'],
        }

    def save_edit(self, word, definition, note, submitter):
        """写用户改释义。返回 (ok, msg)。"""
        if not definition or not definition.strip():
            return False, '释义不能为空'
        if len(definition) > 4000:
            return False, '释义过长（上限 4000 字符）'
        db = self.conn()
        db.execute(
            'INSERT OR REPLACE INTO user_edit'
            '(word, definition, note, submitter, created_at, license) '
            'VALUES (?,?,?,?,?,?)',
            (word, definition.strip(), (note or '').strip()[:200],
             (submitter or '').strip()[:64], int(time.time()), 'CC-BY-SA-4.0')
        )
        db.commit()
        return True, ''

    def log_query(self, word, hit):
        try:
            db = self.conn()
            db.execute('INSERT INTO query_log(word, hit, ts) VALUES (?,?,?)',
                       (word, 1 if hit else 0, int(time.time())))
            db.commit()
        except Exception:
            pass

    def stats(self):
        db = self.conn()
        n_entry = db.execute('SELECT COUNT(*) c FROM entry').fetchone()['c']
        n_sense = db.execute('SELECT COUNT(*) c FROM sense').fetchone()['c']
        n_edit = db.execute('SELECT COUNT(*) c FROM user_edit').fetchone()['c']
        n_query = db.execute('SELECT COUNT(*) c FROM query_log').fetchone()['c']
        # `zh` / `example` 表可能不存在（若没跑对应导入脚本）
        try:
            n_zh = db.execute('SELECT COUNT(*) c FROM zh').fetchone()['c']
        except sqlite3.OperationalError:
            n_zh = 0
        try:
            n_ex = db.execute('SELECT COUNT(*) c FROM example').fetchone()['c']
            n_exw = db.execute('SELECT COUNT(DISTINCT word) c FROM example').fetchone()['c']
        except sqlite3.OperationalError:
            n_ex = 0
            n_exw = 0
        return {
            'entries': n_entry,
            'senses': n_sense,
            'zhDefinitions': n_zh,
            'examples': n_ex,
            'exampleWords': n_exw,
            'userEdits': n_edit,
            'queries': n_query,
        }

    def hot_words(self, limit=20):
        db = self.conn()
        rows = db.execute(
            'SELECT word, COUNT(*) c FROM query_log WHERE hit=1 '
            'GROUP BY word ORDER BY c DESC LIMIT ?', (limit,)
        ).fetchall()
        return [{'word': r['word'], 'count': r['c']} for r in rows]

    def all_words(self):
        """全部单词列表（只给鸿蒙端做离线包，不对外公开下载）。

        ⚠️ 这个接口**只允许来自内网/已登记客户端**（见 handler 里的 is_trusted）。
        对外暴露它= 提供词库批量导出，会触发 CC BY-SA 的数据库条款。
        """
        if self._all:
            return self._all
        db = self.conn()
        self._all = [r['word'] for r in db.execute('SELECT word FROM entry ORDER BY word')]
        return self._all


# ===========================================================================
# 发音（espeak-ng 自己合成 —— 零第三方录音，零授权风险）
# ===========================================================================
class Audio(object):
    def __init__(self, cache_dir, enabled=True):
        self.dir = cache_dir
        self.enabled = enabled and shutil_which('espeak-ng')
        self.lock = threading.Lock()
        if not os.path.isdir(self.dir):
            os.makedirs(self.dir)

    def path_for(self, word, accent):
        return os.path.join(self.dir, '%s.%s.wav' % (safe_name(word), accent))

    def synth(self, word, accent='us'):
        """合成并缓存。返回 (绝对路径, mimetype) 或 (None, err)。"""
        if not self.enabled:
            return None, 'espeak-ng 不可用'
        if accent not in ('us', 'gb'):
            return None, 'accent 只能是 gb / us'
        target = self.path_for(word, accent)
        if os.path.exists(target) and os.path.getsize(target) > 44:
            return target, 'audio/wav'
        # 并发下同一单词可能被同时合成；用锁串行化（espeak-ng 本身很快）
        with self.lock:
            if os.path.exists(target) and os.path.getsize(target) > 44:
                return target, 'audio/wav'
            tmp = target + '.tmp'
            # ⚠️ 只用 espeak-ng 的**原生音色**（gmw/en, en-GB 等）。
            #    绝不能用 MBROLA（`mb/*`、`us-mbrola-*`）—— 那些音色文件是
            #    非商业授权，见 http://github.com/numediart/MBROLA-voices
            #    的 data/en1 说明。本项目只传 -v en-gb / -v en-us，天然规避。
            try:
                subprocess.run(
                    ['espeak-ng', '-v', 'en-gb' if accent == 'gb' else 'en-us',
                     '-w', tmp, word],
                    check=True, timeout=10,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
            except Exception as e:
                if os.path.exists(tmp):
                    os.remove(tmp)
                return None, '合成失败: %s' % e
            if not os.path.exists(tmp) or os.path.getsize(tmp) <= 44:
                if os.path.exists(tmp):
                    os.remove(tmp)
                return None, '合成结果为空'
            os.replace(tmp, target)
        return target, 'audio/wav'


def safe_name(s):
    return re.sub(r'[^A-Za-z0-9._-]', '_', s)[:80]


def shutil_which(name):
    for p in os.environ.get('PATH', '').split(os.pathsep):
        full = os.path.join(p, name)
        if os.path.isfile(full) and os.access(full, os.X_OK):
            return full
    return None


# ===========================================================================
# 负载均衡 / 多后端
# ===========================================================================
class Backends(object):
    """按权重轮询选择后端 + 健康探测。"""

    def __init__(self, conf):
        self.items = [b for b in conf.get('backends', []) if b.get('enabled', True)]
        self.health = conf.get('health', {})
        self.by_id = {b['id']: b for b in self.items}
        self._i = 0
        self._lock = threading.Lock()
        self._status = {}

    def pick(self):
        if not self.items:
            return None
        with self._lock:
            b = self.items[self._i % len(self.items)]
            self._i += 1
        return b

    def probe(self, b, timeout=None):
        t = timeout or self.health.get('timeout_sec', 3)
        try:
            s = socket.create_connection((b['host'], int(b['port'])), timeout=t)
            s.close()
            return True
        except Exception:
            return False

    def status(self):
        out = []
        for b in self.items:
            ok = self.probe(b)
            self._status[b['id']] = ok
            out.append({
                'id': b['id'],
                'host': b['host'],
                'port': b['port'],
                'weight': b.get('weight', 1),
                'healthy': ok,
            })
        return out


def load_stats():
    """本机负载（读/proc，不额外依赖）。"""
    info = {}
    try:
        with open('/proc/loadavg') as f:
            info['loadavg'] = f.read().split()[:3]
        st = os.statvfs('/')
        info['diskTotalGB'] = round(st.f_blocks * st.f_frsize / 1073741824.0, 1)
        info['diskUsedGB'] = round((st.f_blocks - st.f_bfree) * st.f_frsize / 1073741824.0, 1)
    except Exception:
        pass
    try:
        with open('/proc/meminfo') as f:
            for line in f:
                if line.startswith('MemTotal:'):
                    info['memTotalMB'] = int(line.split()[1]) // 1024
                elif line.startswith('MemAvailable:'):
                    info['memAvailableMB'] = int(line.split()[1]) // 1024
    except Exception:
        pass
    return info


# ===========================================================================
# HTTP
# ===========================================================================
class Handler(BaseHTTPRequestHandler):
    server_version = 'DictSrv/' + APP_VERSION
    # 由 serve() 注入
    cfg = None
    lex = None
    audio = None
    bk = None
    instance_id = 'unknown'

    # ---- 基础响应 ----
    def _send(self, code, body=b'', ctype='application/json; charset=utf-8', extra=None):
        if isinstance(body, str):
            body = body.encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('X-Dict-Instance', self.instance_id)
        self.send_header('X-Dict-Version', APP_VERSION)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, PUT, OPTIONS')
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def _json(self, obj, code=200, extra=None):
        self._send(code, json.dumps(obj, ensure_ascii=False), extra=extra)

    def _err(self, code, msg):
        self._json({'ok': False, 'error': msg}, code)

    def log_message(self, fmt, *args):
        # 接管默认日志（默认往 stderr 打，很吵）
        log('%s %s' % (self.address_string(), fmt % args))

    def do_OPTIONS(self):
        self._send(204, b'')

    # ---- 工具 ----
    def _sticky_backend(self, q):
        """粘性会话：URL 带 backend=<id> 时钉到该节点，否则用 cookie，再否则轮询。

        这是"预留负载均衡入口"的落地方式 —— 前端要能**主动切换节点**。
        """
        b = q.get('backend', [None])[0]
        if b and b in self.bk.by_id:
            return b
        try:
            ck = SimpleCookie(self.headers.get('Cookie', ''))
            if 'dict_backend' in ck and ck['dict_backend'].value in self.bk.by_id:
                return ck['dict_backend'].value
        except Exception:
            pass
        return None

    def is_trusted(self):
        """内网判定—— 给鸿蒙端拉离线词表用。

        ⚠️ 离线包接口 `/api/v1/words` 若对外开放 = 提供词库批量导出，
        会触发 CC BY-SA 4.0 第 4 条的数据库条款。故限制在同机/内网。
        """
        host = self.client_address[0]
        return (host in ('127.0.0.1', '::1') or
                host.startswith('10.') or host.startswith('192.168.') or
                re.match(r'^172\.(1[6-9]|2\d|3[01])\.', host))

    # ---- 路由 ----
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        p = u.path.rstrip('/') or '/'

        try:
            if p == '/' or p == '/index.html':
                return self._send(200, INDEX_HTML, 'text/html; charset=utf-8')
            if p == '/healthz':
                return self._json({
                    'ok': True,
                    'instance': self.instance_id,
                    'version': APP_VERSION,
                    'uptimeSec': int(time.time() - START_TS),
                    'load': load_stats(),
                    'backends': self.bk.status(),
                })
            if p == '/api/v1/word':
                return self.api_word(q)
            # 发音：/api/v1/word/<word>/audio?accent=gb|us
            if p.startswith('/api/v1/word/') and p.endswith('/audio'):
                mid = p[len('/api/v1/word/'):-len('/audio')]
                return self.api_audio(urllib.parse.unquote(mid), q)
            if p == '/api/v1/batch':
                return self.api_batch(q)
            if p == '/api/v1/words':
                if not self.is_trusted():
                    return self._err(403, '离线词表接口仅限内网访问')
                return self._json({'ok': True, 'count': len(self.lex.all_words()),
                                   'words': self.lex.all_words()})
            if p == '/api/v1/stats':
                return self._json({'ok': True, 'stats': self.lex.stats(),
                                   'hot': self.lex.hot_words(20)})
            if p == '/api/v1/licenses':
                return self._json({'ok': True, 'licenses': LICENSES})
            if p == '/api/v1/backends':
                return self._json({'ok': True, 'instance': self.instance_id,
                                   'backends': self.bk.status()})
            return self._err(404, 'not found')
        except Exception as e:
            log('GET %s 异常: %r' % (self.path, e))
            return self._err(500, 'internal error: %s' % e)

    def do_HEAD(self):
        self.do_GET()

    def do_POST(self):
        return self._err(405, 'use PUT')

    def do_PUT(self):
        u = urllib.parse.urlparse(self.path)
        p = u.path.rstrip('/') or '/'
        if p != '/api/v1/word':
            return self._err(404, 'not found')
        try:
            n = int(self.headers.get('Content-Length') or 0)
            if n <= 0:
                return self._err(400, 'empty body')
            if n > 20000:
                return self._err(413, 'payload too large')
            data = json.loads(self.rfile.read(n).decode('utf-8'))
        except Exception as e:
            return self._err(400, 'bad json: %s' % e)

        # ⚠️ 提交改释义前必须显式同意授权条款 ——
        #    CC BY-SA 4.0 第 3(a) 条要求"表明是否曾修改"，
        #    用户勾选同意这件事本身就是我们留存的举证材料之一。
        if not data.get('licenseAgree'):
            return self._err(400, '必须先同意授权条款（licenseAgree=true）')

        word = (data.get('word') or '').strip().lower()
        if not word or not re.match(r'^[a-z][a-z \-]{0,40}$', word):
            return self._err(400, 'word 不合法')

        ok, msg = self.lex.save_edit(
            word, data.get('definition', ''),
            data.get('note', ''), data.get('submitter', ''))
        if not ok:
            return self._err(400, msg)
        log('用户改释义: %s by %s' % (word, data.get('submitter') or '(匿名)'))
        return self._json({'ok': True, 'word': word,
                           'license': 'CC-BY-SA-4.0'})

    # ---- API 实现 ----
    def api_word(self, q):
        raw = (q.get('w') or q.get('word') or [''])[0]
        word = raw.strip().lower()
        if not word:
            return self._err(400, 'missing w')
        if not re.match(r'^[a-z][a-z \-]{0,40}$', word):
            return self._err(400, 'word 不合法（只接受英文字母与连字符）')

        ent = self.lex.lookup(word)
        self.lex.log_query(word, ent is not None)

        pinned = self._sticky_backend(q)
        extra = {'X-Dict-Backend': pinned or 'local'} if pinned else None

        if ent is None:
            # 只有用户改写也算命中
            ue = self.lex.user_edit(word)
            if ue is None:
                return self._json({'ok': True, 'word': word, 'found': False,
                                    'userEdit': None}, extra=extra)
            return self._json({'ok': True, 'word': word, 'found': True,
                                'userEdit': ue, 'entry': None}, extra=extra)

        return self._json({
            'ok': True,
            'word': word,
            'found': True,
            'entry': ent,
            'userEdit': self.lex.user_edit(word),
            # 客户端据此知道该词条的来源与是否被改过
            'modified': self.lex.user_edit(word) is not None,
        }, extra=extra)

    def api_audio(self, word, q):
        """发音：服务端 espeak-ng 合成并缓存。

        ⚠️ 只用 espeak-ng **原生音色**（-v en-gb / -v en-us），
        绝不用 MBROLA（那些音色数据是非商用授权）。
        """
        word = (word or '').strip().lower()
        accent = (q.get('accent') or ['us'])[0].lower()
        if not word or not re.match(r'^[a-z][a-z \-]{0,40}$', word):
            return self._err(400, 'word 不合法')
        path, mime = self.audio.synth(word, accent)
        if not path:
            return self._err(503, mime)
        try:
            with open(path, 'rb') as f:
                data = f.read()
        except Exception as e:
            return self._err(500, 'read audio failed: %s' % e)
        # 音频可长期缓存（内容不变），但**必须**带 Content-Length
        self._send(200, data, mime, extra={
            'Cache-Control': 'public, max-age=604800',
            'X-Dict-Audio-Accent': accent,
        })

    def api_batch(self, q):
        words = (q.get('w') or q.get('words') or [''])[0]
        arr = [w.strip().lower() for w in words.split(',') if w.strip()]
        arr = arr[:50]
        if not arr:
            return self._err(400, 'missing w')
        out = []
        for w in arr:
            e = self.lex.lookup(w)
            if e:
                out.append(e)
        return self._json({'ok': True, 'count': len(out), 'entries': out})


START_TS = time.time()

# ===========================================================================
# 授权清单（页脚与 /api/v1/licenses 都用它，保证与代码实际来源一致）
# ===========================================================================
LICENSES = [
    {
        'name': 'Open English WordNet',
        'license': 'CC BY 4.0',
        'url': 'https://github.com/globalwordnet/english-wordnet',
        'attribution': 'derived from Princeton WordNet; attribution required to BOTH',
        'usedFor': '英文释义、例句',
        'modified': False,
    },
    {
        'name': 'Princeton WordNet',
        'license': 'WordNet License',
        'url': 'https://wordnet.princeton.edu/license-and-commercial-use',
        'attribution': '版权始终归普林斯顿；不得用Princeton 名义做广告宣传',
        'usedFor': 'OEWN 的上游来源',
        'modified': False,
    },
    {
        'name': 'ECDICT（仅取中文字段）',
        'license': 'MIT',
        'url': 'https://github.com/skywind3000/ECDICT',
        'attribution': 'Copyright (c) 2025 Linwei',
        'usedFor': '中文释义、考纲标签、屈折变化',
        'modified': False,
        'scopeNote': ('本站**只用它的中文字段**（translation/tag/exchange），'
                      '不用 definition（英文释义）—— 后者上游为商业词典站，授权链断裂。'
                      '音标由旧式 ASCII 规范化为 IPA，仅符号替换，不改读音。'),
    },
    {
        'name': 'Tatoeba（仅中文↔英语例句）',
        'license': 'CC BY 2.0 FR',
        'url': 'https://tatoeba.org',
        'attribution': '每条例句均带句子ID 与作者用户名，页面须逐条展示',
        'usedFor': '双语例句（英 + 中）',
        'modified': False,
        'scopeNote': ('取自 manythings.org 整理的 cmn-eng.zip（32028 句对，'
                      '均为有人工翻译的句子）。CC-BY 2.0 FR 的署名义务是'
                      '**署名到句子作者**，仅在页脚写一句"来自 Tatoeba"不满足要求。'),
    },
    {
        'name': 'espeak-ng',
        'license': 'GPL-3.0-or-later（软件）',
        'url': 'https://github.com/espeak-ng/espeak-ng',
        'attribution': '以独立进程调用，不链接其代码，故 GPL 不传染本项目',
        'usedFor': '英音(en-gb)/美音(en-us)发音合成',
        'modified': False,
    },
    {
        'name': '用户提交的释义',
        'license': 'CC BY-SA 4.0',
        'url': 'https://creativecommons.org/licenses/by-sa/4.0/',
        'attribution': '由提交者授权，保留时间戳与提交者标识',
        'usedFor': '词条改写层',
        'modified': True,
    },
]

# ⚠️ 刻意**不包含** ECDICT 的释义：其上游为商业词典站（TheFreeDictionary /
# linguee / Babylon 等），MIT 许可无法覆盖作者本就不拥有的内容，授权链断裂。
_NOTE_ECDICT = (
    '本站英文释义不使用 ECDICT 的 translation 字段 —— 其上游为商业词典站，'
    'MIT 许可无法覆盖原作者不拥有的内容。仅参考其词频/词性等语言学标注字段。'
)


INDEX_HTML = '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>词典 · dictionary.xsheep.cn</title>
<style>
:root{--bg:#f7f8fa;--card:#fff;--fg:#1c1c1e;--sub:#6b6b70;--acc:#0a59f7;--line:#e5e5ea}
@media(prefers-color-scheme:dark){:root{--bg:#000;--card:#1c1c1e;--fg:#f2f2f7;--sub:#98989f;--line:#38383a}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
.wrap{max-width:640px;margin:0 auto;padding:24px 16px 64px}
h1{font-size:24px;margin:0 0 4px}
.sub{color:var(--sub);font-size:14px;margin-bottom:20px}
form{display:flex;gap:8px;margin-bottom:24px}
input{flex:1;padding:12px 14px;font-size:16px;border:1px solid var(--line);border-radius:10px;background:var(--card);color:var(--fg)}
button{padding:12px 20px;font-size:16px;border:0;border-radius:10px;background:var(--acc);color:#fff;font-weight:500}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:18px;margin-bottom:12px}
.w{font-size:22px;font-weight:600}
.ipa{color:var(--sub);font-family:ui-monospace,Menlo,monospace;margin-left:8px}
.pos{display:inline-block;font-size:12px;padding:2px 8px;border-radius:99px;background:var(--line);color:var(--sub);margin-left:8px}
ol{padding-left:22px;margin:12px 0 0}
li{margin-bottom:10px}
.ex{color:var(--sub);font-size:14px;font-style:italic;margin-top:2px}
.audio{margin:12px 0}
.audio button{padding:8px 14px;font-size:14px;margin-right:8px;background:var(--card);color:var(--acc);border:1px solid var(--line)}
/* 考纲标签 */
.tags{margin-top:10px;display:flex;flex-wrap:wrap;gap:6px}
.tag{font-size:12px;padding:3px 9px;border-radius:99px;background:var(--acc);color:#fff;font-weight:500}
.stars{margin-top:8px;font-size:12px;color:var(--sub)}
.stars span{margin-right:12px}
/* 中文释义 —— 主要用途，放最显眼 */
.zh{margin:14px 0;padding:14px;border-radius:10px;background:var(--bg);border-left:3px solid var(--acc)}
.zrow{display:flex;gap:10px;margin-bottom:6px;align-items:baseline}
.zrow:last-child{margin-bottom:0}
.zpos{flex:0 0 auto;font-size:13px;color:var(--acc);font-weight:600;min-width:44px}
.zdef{flex:1;font-size:15px;line-height:1.7}
/* 英文释义区（次要） */
.ensec{margin-top:16px;padding-top:12px;border-top:1px solid var(--line);font-size:12px;color:var(--sub);letter-spacing:.05em}
/* 双语例句 */
.ex2{margin-top:10px;padding:10px 12px;border-radius:8px;background:var(--bg)}
.exen{font-size:14px;color:var(--fg);line-height:1.6}
.exzh{font-size:14px;color:var(--fg);margin-top:2px}
/* ⚠️ 署名 —— CC-BY 2.0 FR 的硬性要求，不可隐藏、不可省略 */
.exat{font-size:11px;color:var(--sub);margin-top:6px;word-break:break-all}
.ue{border-left:3px solid var(--acc);padding-left:12px;margin-top:14px}
footer{margin-top:32px;padding-top:16px;border-top:1px solid var(--line);color:var(--sub);font-size:13px}
footer a{color:var(--acc)}
code{background:var(--line);padding:1px 5px;border-radius:4px;font-size:13px}
</style>
</head>
<body>
<div class="wrap">
<h1>词典</h1>
<div class="sub">英汉词典 · __INSTANCE__ · <a href="/api/v1/licenses" style="color:var(--acc)">授权信息</a></div>
<form onsubmit="go(event)">
  <input id="w" placeholder="输入英文单词" autocomplete="off" autocapitalize="off" spellcheck="false" autofocus>
  <button type="submit">查询</button>
</form>
<div id="r"></div>
<footer>
  <p><b>英文释义</b>来自 <a href="https://github.com/globalwordnet/english-wordnet" target="_blank" rel="noopener">Open English WordNet</a>
     （CC BY 4.0，派生自 <a href="https://wordnet.princeton.edu/" target="_blank" rel="noopener">Princeton WordNet</a>），
     本站未作修改。<b>中文释义</b>来自 <a href="https://github.com/skywind3000/ECDICT" target="_blank" rel="noopener">ECDICT</a>
     （MIT，Copyright © 2025 Linwei），音标已规范化为 IPA。</p>
  <p>发音由 <a href="https://github.com/espeak-ng/espeak-ng" target="_blank" rel="noopener">espeak-ng</a> 服务端合成，非第三方录音。
     例句来自 <a href="https://tatoeba.org" target="_blank" rel="noopener">Tatoeba</a>（CC BY 2.0 FR），每条均在下方标注作者。
     词条改写内容由提交者以 CC BY-SA 4.0 授权。</p>
  <p>本站为非商业公益服务。释义仅供学习参考；商用或大规模分发前请自行确认上述授权。</p>
</footer>
</div>
<script>
function esc(s){const d=document.createElement('div');d.textContent=s;return d.innerHTML}
async function go(e){
  e.preventDefault();
  const w=document.getElementById('w').value.trim().toLowerCase();
  if(!w)return;
  const r=document.getElementById('r');
  r.innerHTML='<div class="card">查询中…</div>';
  try{
    const res=await fetch('/api/v1/word?w='+encodeURIComponent(w));
    const j=await res.json();
    if(!j.found){r.innerHTML='<div class="card">未找到 <b>'+esc(w)+'</b></div>';return}
    let h='';
    if(j.entry){
      const e=j.entry;
      // 词头：单词 + 音标 + 考纲标签
      h+='<div class="card"><div class="w">'+esc(e.word)+
         (e.ipa?'<span class="ipa">/'+esc(e.ipa)+'/</span>':'')+
         (e.posLabelZh?'<span class="pos">'+esc(e.posLabelZh)+'</span>':'')+'</div>';

      // 考纲标签 —— 对学生最有用（中考/高考/四级/六级/考研/雅思/托福）
      if(e.tags&&e.tags.length){
        h+='<div class="tags">';
        for(const t of e.tags) h+='<span class="tag">'+esc(t)+'</span>';
        h+='</div>';
      }
      // 星级
      if(e.collins||e.oxford){
        h+='<div class="stars">';
        if(e.collins) h+='<span>柯林斯 '+('★'.repeat(e.collins))+'</span>';
        if(e.oxford) h+='<span>牛津3000</span>';
        h+='</div>';
      }

      h+='<div class="audio"><button onclick="play(\\''+esc(e.word)+'\\',\\'gb\\')">英音</button>'+
         '<button onclick="play(\\''+esc(e.word)+'\\',\\'us\\')">美音</button></div>';

      // ⭐ 中文释义放最前面 —— 这是英汉词典的主要用途
      if(e.definitionZh){
        const zh=e.definitionZh.split('\\n');
        h+='<div class="zh">';
        for(const line of zh){
          if(!line.trim()) continue;
          // 按「\\n」分出的每一行形如 "n. 水, 雨水..." 或 "[计] 计算机"
          const m=line.match(/^(\\[.*?\\]\\s*)?([^\\s\\[]+?\\.)(.*)$/);
          if(m){
            h+='<div class="zrow"><span class="zpos">'+esc(m[1]?m[1]+m[2]:m[2])+
               '</span><span class="zdef">'+esc((m[3]||'').trim())+'</span></div>';
          }else{
            h+='<div class="zrow"><span class="zdef">'+esc(line.trim())+'</span></div>';
          }
        }
        h+='</div>';
      }

      // 双语例句（Tatoeba）—— CC-BY 2.0 FR 要求**逐条署名**，故必须展示 attribution
      if(e.examples&&e.examples.length){
        h+='<div class="ensec">例句</div>';
        for(const x of e.examples){
          h+='<div class="ex2"><div class="exen">'+esc(x.en)+'</div>'+
             '<div class="exzh">'+esc(x.zh)+'</div>'+
             '<div class="exat">'+esc(x.attribution)+'</div></div>';
        }
      }

      // 英文释义与例句
      if(e.senses&&e.senses.length){
        h+='<div class="ensec">英文释义</div><ol>';
        for(const s of e.senses){
          h+='<li>'+esc(s.gloss);
          if(s.examples&&s.examples.length)h+='<div class="ex">e.g. '+esc(s.examples[0])+'</div>';
          h+='</li>';
        }
        h+='</ol>';
      }
      h+='</div>';
    }
    if(j.userEdit){
      h+='<div class="card"><b>社区释义</b><div class="ue">'+esc(j.userEdit.definition)+'</div>'+
         '<div class="ex">由 '+(j.userEdit.submitter?esc(j.userEdit.submitter):'匿名')+
         ' 提交 · '+esc(j.userEdit.license)+'</div></div>';
    }
    r.innerHTML=h;
  }catch(err){r.innerHTML='<div class="card">出错了：'+esc(err.message)+'</div>'}
}
function play(w,accent){
  new Audio('/api/v1/word/'+encodeURIComponent(w)+'/audio?accent='+accent).play();
}
</script>
</body>
</html>
'''


# ===========================================================================
# 启动
# ===========================================================================
def serve(cfg):
    base = os.path.dirname(os.path.abspath(cfg.get('__file__', 'app.py')))
    # ⚠️ **必须先把配置里的相对路径解析成绝对路径**，再做 chdir。
    #    原来在创建 Lexicon 之前就 `os.chdir('/tmp')`，导致 `./lexicon.db`
    #    被解析成 `/tmp/lexicon.db` → 启动即报 no such table。
    #    （服务器上 espeak-ng 的工作目录也不能含撇号，所以仍要 chdir /tmp，
    #    但那必须发生在所有相对路径都固化之后。）
    lex_path = cfg['lexicon']
    if not os.path.isabs(lex_path):
        lex_path = os.path.normpath(os.path.join(base, lex_path))
    audio_dir = cfg.get('audio_dir') or 'audio'
    if not os.path.isabs(audio_dir):
        audio_dir = os.path.normpath(os.path.join(base, audio_dir))

    lex = Lexicon(lex_path)
    audio = Audio(audio_dir)
    bk = Backends(cfg)

    Handler.cfg = cfg
    Handler.lex = lex
    Handler.audio = audio
    Handler.bk = bk
    Handler.instance_id = cfg.get('instance_id', 'unknown')

    # espeak-ng 需要一个**不含撇号**的绝对路径作为工作目录（避免远端命令转义问题）
    os.chdir('/tmp')

    port = int(cfg.get('listen', {}).get('port', 8788))
    host = cfg.get('listen', {}).get('host', '0.0.0.0')

    # 预热：把常用词的两种发音先合成好，避免首次查询等待
    if audio.enabled and cfg.get('warmup', True):
        warm = cfg.get('warmup_words', [])[:200]
        log('预热发音 %d 词...' % len(warm))
        for w in warm:
            for a in ('gb', 'us'):
                audio.synth(w, a)

    srv = ThreadingHTTPServer((host, port), Handler)
    srv.daemon_threads = True
    st = lex.stats()
    log('=' * 52)
    log('实例 %s  v%s  监听 %s:%d' % (Handler.instance_id, APP_VERSION, host, port))
    log('词库: %d 词条 / %d 义项  (%s)' % (st['entries'], st['senses'], lex_path))
    log('发音: %s' % ('espeak-ng 已启用' if audio.enabled else '不可用（查词仍可用，无发音）'))
    log('后端: %s' % ', '.join('%s:%s' % (b['id'], b['port']) for b in bk.items))
    log('=' * 52)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        log('收到中断，退出')
    finally:
        srv.server_close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--config', default='config.json')
    args = ap.parse_args()
    with open(args.config, 'r', encoding='utf-8') as f:
        cfg = json.load(f)
    cfg['__file__'] = os.path.abspath(args.config)
    serve(cfg)


if __name__ == '__main__':
    main()