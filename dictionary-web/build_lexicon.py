#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 Open English WordNet (OEWN) 导入成词典 SQLite。

## 授权（必须保留，这是合规凭据）
Open English WordNet
  来源:   https://github.com/globalwordnet/english-wordnet
  许可:   CC BY 4.0（派生自 Princeton WordNet，**须同时署名两者**）
  原文:   "This resource is derived from Princeton WordNet under the WordNet
           License and further developed under the Creative Commons
           Attribution 4.0 International License. You may share and adapt
           this resource providing attribution is given to both Princeton
           WordNet and the Open English Wordnet team."

⚠️ **本脚本不改写释义内容**，只做格式转换（提取 → 入库）。
   若日后人工修改了 `sense.definition`，必须按 CC BY-SA/Wikimedia 惯例
   标注"是否作过修改"（本项目对 CC BY-SA 来源适用）。

## 为什么不用 PyYAML
服务器是 Python 3.8 且不保证有 PyYAML；OEWN 的 YAML 是一个**受限子集**
（等深两层 + 列表项 + 单行标量），用 stdlib 逐行解析更快、零依赖、更可控。

用法:
    python3 build_lexicon.py --zip oewn.zip --out lexicon.db [--limit N]
"""

import argparse
import io
import os
import sqlite3
import sys
import zipfile

# ---------------------------------------------------------------------------
# schema
# ---------------------------------------------------------------------------
SCHEMA = """
PRAGMA journal_mode=WAL;

-- 英文词条（来自 entries-*.yaml：词性、音标、义项→synset 映射）
CREATE TABLE IF NOT EXISTS entry (
    word        TEXT PRIMARY KEY,
    pos         TEXT,                -- 词性：n / v / a / r / s
    ipa         TEXT,                -- 音标（IPA）
    ipa_variant TEXT,                -- 音标变体（英/美）
    senses_json TEXT                 -- JSON: [{"synset":"...","rank":1}, ...]
);

-- 义项释义（来自 noun.*.yaml / verb.*.yaml 等按语义域分的文件）
CREATE TABLE IF NOT EXISTS sense (
    synset   TEXT PRIMARY KEY,
    pos      TEXT,
    gloss    TEXT,                   -- 英文释义（可能有多个分号分句）
    examples TEXT                    -- JSON 数组
);

-- 用户改写层（CC BY-SA 4.0 授权，见 API PUT /api/v1/word）
CREATE TABLE IF NOT EXISTS user_edit (
    word       TEXT PRIMARY KEY,
    definition TEXT NOT NULL,
    note       TEXT,
    submitter  TEXT,
    created_at INTEGER NOT NULL,
    -- ⚠️ 举证材料：CC BY-SA 4.0 第 3(a) 条要求"表明是否曾修改"
    license    TEXT NOT NULL DEFAULT 'CC-BY-SA-4.0'
);

-- 词频/考纲标签（来自 ECDICT 的**语言学标注字段**，不含释义）
-- ⚠️ 刻意**不导入** ECDICT 的 translation / collins / oxford：
--    那三项的授权链断裂（上游是商业词典站），MIT 保不住。
CREATE TABLE IF NOT EXISTS tag (
    word TEXT NOT NULL,
    kind TEXT NOT NULL,              -- 'collins' / 'oxford' / 'tag' / 'bnc'
    val  TEXT NOT NULL,
    PRIMARY KEY (word, kind)
);

-- 查词日志（用于统计热门词，将来可做缓存预热）
CREATE TABLE IF NOT EXISTS query_log (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    word    TEXT NOT NULL,
    hit     INTEGER NOT NULL,
    ts      INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_log_word ON query_log(word);

CREATE INDEX IF NOT EXISTS idx_entry_pos  ON entry(pos);
CREATE INDEX IF NOT EXISTS idx_tag_word   ON tag(word);
"""

# 词性代码 → 英文/中文标签
POS_LABEL = {
    'n': ('noun', '名词'),
    'v': ('verb', '动词'),
    'a': ('adjective', '形容词'),
    'r': ('adverb', '副词'),
    's': ('adjective', '形容词'),
}

# 语义域文件名 → 中文标签（用于给释义分类，展示时更好读）
DOMAIN_LABEL = {
    'noun.act': '行为', 'noun.animal': '动物', 'noun.artifact': '物品',
    'noun.attribute': '属性', 'noun.body': '身体', 'noun.cognition': '认知',
    'noun.communication': '交流', 'noun.event': '事件', 'noun.feeling': '情感',
    'noun.food': '食物', 'noun.group': '群体', 'noun.location': '地点',
    'noun.motive': '动机', 'noun.object': '对象', 'noun.person': '人',
    'noun.phenomenon': '现象', 'noun.plant': '植物', 'noun.possession': '财物',
    'noun.process': '过程', 'noun.quantity': '数量', 'noun.relation': '关系',
    'noun.shape': '形状', 'noun.state': '状态', 'noun.substance': '物质',
    'noun.time': '时间',
    'verb.body': '身体动作', 'verb.change': '变化', 'verb.cognition': '认知',
    'verb.communication': '交流', 'verb.competition': '竞争', 'verb.consumption': '消耗',
    'verb.contact': '接触', 'verb.creation': '创造', 'verb.emotion': '情感',
    'verb.motion': '运动', 'verb.perception': '感知', 'verb.possession': '占有',
    'verb.social': '社交', 'verb.stative': '状态', 'verb.weather': '天气',
    # ⚠️ 形容词 / 副词的释义**全在这两个聚合文件里**（不是按语义域分的）。
    #    最初把它们当"关系文件"跳过了，结果 `happy` / `beautiful` 这类最常查的词
    #    全都没有释义 —— 85643 义项里一条形容词都没有。必须收进来。
    'adj.all': '性质', 'adv.all': '状态',
}


def unquote(s):
    """去掉 YAML 单引号（OEWN 里 id 字段常用单引号包住 % 之类）。"""
    s = s.strip()
    if len(s) >= 2 and s[0] == "'" and s[-1] == "'":
        return s[1:-1].replace("''", "'")
    return s


def parse_entries(text):
    """
    解析 entries-*.yaml：
        H-bomb:              <- 顶层键 = 单词（无缩进）
          n:                 <- 第二层键 = 词性
            pronunciation:   <- 第三层
            - value: ˈhæzˌmæt
              variety: US
            sense:
            - id: ...
              synset: 03558428-n
    返回 {word: {'pos':..., 'ipa':..., 'variety':..., 'senses':[(synset,rank)]}}
    """
    out = {}
    word = None
    pos = None
    block = None          # 当前在处理 pronunciation 还是 sense
    ipa = None
    variety = None
    senses = []
    rank = 0

    def flush():
        """遇到下一个顶层词时落盘当前词条。"""
        nonlocal word, pos, ipa, variety, senses, rank
        if word and pos:
            prev = out.get(word)
            cur = {'pos': pos, 'ipa': ipa, 'variety': variety, 'senses': list(senses)}
            if prev is None:
                out[word] = cur
            else:
                # 同一个单词有多个词性（如 water: n/v/adjective）。
                # entry表的主键是 word，所以**保留第一个词性**，
                # 把后续词性的义项并进来 —— 否则会丢义项。
                prev['senses'] = prev['senses'] + cur['senses']
                if not prev['ipa'] and cur['ipa']:
                    prev['ipa'] = cur['ipa']
                    prev['variety'] = cur['variety']
        word = None
        pos = None
        ipa = None
        variety = None
        senses = []
        rank = 0

    for raw in text.split('\n'):
        if not raw.strip() or raw.lstrip().startswith('#'):
            continue

        indent = len(raw) - len(raw.lstrip(' '))
        line = raw.strip()

        if indent == 0:
            flush()
            word = unquote(line.rstrip(':'))
            rank = 0
            continue

        if word is None:
            continue

        # 第二层：词性（n / v / a / r / s）
        if indent == 2 and pos is None and not line.startswith('- '):
            cand = unquote(line.rstrip(':'))
            if cand in POS_LABEL:
                pos = cand
            block = None
            continue

        if pos is None:
            continue

        # ⚠️ 与 sense 文件同理：**列表项与父键同缩进**。
        #   pronunciation:            ← indent 4
        #   - value: ˈhæzˌmæt         ← indent 4  ← 同级！
        #   sense:                    ← indent 4
        #   - id: ...                 ← indent 4  ← 同级！
        #     synset: xxx             ← indent 6（列表项的子字段）
        if indent == 4:
            if line.startswith('- '):
                if block == 'sense':
                    rank += 1
                    senses.append([None, rank])
                elif block == 'pronunciation':
                    # `- value: xxx` 与 `- variety: xxx` 可能同级连写
                    inner = line[2:]
                    if ':' in inner:
                        k2, v2 = inner.split(':', 1)
                        k2 = k2.strip()
                        if k2 == 'value':
                            ipa = unquote(v2)
                        elif k2 == 'variety':
                            variety = unquote(v2)
                continue
            block = line.rstrip(':')
            if block == 'pronunciation':
                ipa = None
                variety = None
            continue

        if indent >= 6:
            if block == 'pronunciation' and line.startswith('variety:'):
                variety = unquote(line.split(':', 1)[1])
            elif block == 'sense' and line.startswith('synset:') and senses:
                senses[-1][0] = unquote(line.split(':', 1)[1])
            continue

    flush()
    # 只保留真正挂上 synset 的义项
    for w in list(out.keys()):
        clean = [s for s in out[w]['senses'] if s[0]]
        if not clean:
            del out[w]
        else:
            out[w]['senses'] = clean
    return out


def parse_senses(text):
    """
    解析 noun.*.yaml / verb.*.yaml：
        05619057-n:                <- 顶层键 = synset
          definition:             <- 第二层
          - text...; text...
          example:
          - his mind wandered
          partOfSpeech: n
    返回 {synset: {'pos':..., 'gloss':..., 'examples':[...]}}
    """
    out = {}
    syn = None
    key = None
    buf = []
    examples = []
    pos = None

    def save():
        """把当前 synset 落盘。用独立函数而不是 flush，
        因为 `key` 会被 example/partOfSpeech 覆盖，
        等到下一个顶层键才判断就来不及了。"""
        if not syn or not buf:
            return
        g = ' '.join(x.strip() for x in buf if x.strip())
        if g:
            out[syn] = {
                'pos': pos,
                'gloss': g,
                'examples': list(examples),
            }

    for raw in text.split('\n'):
        if not raw.strip() or raw.lstrip().startswith('#'):
            continue
        indent = len(raw) - len(raw.lstrip(' '))
        line = raw.strip()

        if indent == 0:
            save()                      # 上一个 synset 收尾
            syn = unquote(line.rstrip(':'))
            key = None
            pos = None
            buf = []
            examples = []
            continue
        if syn is None:
            continue
        # ⚠️ OEWN 的列表项与父键**同缩进（都是 2 空格）**，不是更深的子级：
        #      definition:            ← indent 2
        #      - that which is ...    ← indent 2  ← 同级！
        #      - the seat of ...      ← indent 4  （多行释义的续行）
        # 所以必须**先判列表项**，再判键名，否则 `- xxx` 会被当成新键。
        if indent >= 2 and line.startswith('- '):
            val = unquote(line[2:])
            if key == 'definition':
                buf.append(val)
            elif key == 'example':
                examples.append(val)
            continue
        if indent == 2:
            # 进入新键：若上一个键是 definition，先落盘
            if key == 'definition':
                save()
            key = line.rstrip(':')
            if key == 'example':
                # example 之前必须已保存 definition
                examples = []
            continue
        if indent >= 4:
            # 释义续行（折行的第二行），并入当前键
            if key == 'definition' and line:
                buf.append(line)
            elif line.startswith('partOfSpeech:'):
                pos = line.split(':', 1)[1].strip()
            continue
    save()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--zip', required=True, help='OEWN 仓库 zip（GitHub codeload 下载）')
    ap.add_argument('--out', required=True, help='输出 SQLite 路径')
    ap.add_argument('--limit', type=int, default=0, help='只导入前 N 个词（调试用）')
    args = ap.parse_args()

    zf = zipfile.ZipFile(args.zip)
    names = zf.namelist()

    # ---- 1. 释义：按语义域的 *.*.yaml ----
    sys.stderr.write('[1/3] 解析释义 (sense)...\n')
    all_senses = {}
    for n in names:
        base = os.path.basename(n)
        if not base.endswith('.yaml'):
            continue
        stem = base[:-5]
        # ⚠️ `adj.` / `adv.` **不是关系文件**，它们是形容词/副词的释义库，
        #    必须收进来（见 DOMAIN_LABEL 里的说明）。
        if stem.startswith('entries-'):
            continue
        if '.' not in stem:
            continue
        domain = stem
        if domain not in DOMAIN_LABEL:
            continue
        try:
            text = zf.read(n).decode('utf-8')
        except Exception as e:
            sys.stderr.write('  ! 跳过 %s: %s\n' % (base, e))
            continue
        got = parse_senses(text)
        for k, v in got.items():
            v['domain'] = DOMAIN_LABEL[domain]
        all_senses.update(got)
    sys.stderr.write('      义项 %d 条\n' % len(all_senses))

    # ---- 2. 词条：entries-*.yaml ----
    sys.stderr.write('[2/3] 解析词条 (entry)...\n')
    all_entries = {}
    for n in sorted(names):
        base = os.path.basename(n)
        if not base.startswith('entries-') or not base.endswith('.yaml'):
            continue
        text = zf.read(n).decode('utf-8')
        got = parse_entries(text)
        all_entries.update(got)
    sys.stderr.write('      词条 %d 个\n' % len(all_entries))

    if args.limit:
        keep = set(sorted(all_entries.keys())[:args.limit])
        all_entries = {k: v for k, v in all_entries.items() if k in keep}

    # ---- 3. 建库 ----
    sys.stderr.write('[3/3] 写入 SQLite: %s\n' % args.out)
    if os.path.exists(args.out):
        os.remove(args.out)
    db = sqlite3.connect(args.out)
    db.executescript(SCHEMA)

    import json
    n_s = 0
    for syn, v in all_senses.items():
        db.execute(
            'INSERT OR REPLACE INTO sense(synset,pos,gloss,examples) VALUES(?,?,?,?)',
            (syn, v.get('pos'), v.get('gloss'), json.dumps(v.get('examples', []), ensure_ascii=False)))
        n_s += 1

    n_e = 0
    skipped = 0
    for word, v in all_entries.items():
        senses = [{'synset': s[0], 'rank': s[1]} for s in v['senses']]
        if not senses:
            skipped += 1
            continue
        db.execute(
            'INSERT OR REPLACE INTO entry(word,pos,ipa,ipa_variant,senses_json) VALUES(?,?,?,?,?)',
            (word, v.get('pos'), v.get('ipa'), v.get('variety'),
             json.dumps(senses, ensure_ascii=False)))
        n_e += 1

    db.commit()
    db.execute('VACUUM')
    db.close()

    sys.stderr.write('\n完成:\n')
    sys.stderr.write('  词条 %d（跳过无义项 %d）\n' % (n_e, skipped))
    sys.stderr.write('  义项 %d\n' % n_s)
    sys.stderr.write('  文件 %.1f MB\n' % (os.path.getsize(args.out) / 1048576.0))


if __name__ == '__main__':
    main()