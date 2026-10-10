#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
导入 ECDICT 的**中文释义**与语言学标注，合并进词典 SQLite。

## 授权（这份数据与 OEWN 是两套不同的许可，必须分开标注）
ECDICT (https://github.com/skywind3000/ECDICT)
    License: MIT, Copyright (c) 2025 Linwei

⚠️ **本项目只取它的中文字段，不取英文字段。** 理由与取舍见 THIRD-PARTY-NOTICES.md：
  · ✅ 取 `translation`（中文释义，75 万条）—— 这是整个词库里最难从别处
    合法获得的部分，而 MIT 允许闭源使用，对免费服务最安全
  · ✅ 取 `tag`（考纲标签 gk/cet4/cet6/ielts/toefl）、`collins`/`oxford`（星级）
  · ❌ **不取** `definition`（英文释义）—— 其上游是商业词典站
    （TheFreeDictionary / linguee / Babylon 等），授权链断裂。
    英文释义走 OEWN（CC BY 4.0，来源链清晰）
  · ❌ **不取** `audio`（实测全空）

## 音标转换：ECDICT 用旧 ASCII 音标 → 转成标准 IPA
ECDICT 的 `phonetic` 混用 ASCII 与旧式国际音标（ә/ɒ/є/ɡ/ɔ/ɑ…），
直接显示给学生看不规范。本脚本按映射表统一成 IPA。

用法:
    python3 import_ecdict.py --csv data/ecdict.csv --db lexicon.db
"""

import argparse
import csv
import os
import sqlite3
import sys

csv.field_size_limit(10 ** 9)

# ---------------------------------------------------------------------------
# 音标映射：ECDICT → IPA
# ---------------------------------------------------------------------------
# 旧式国际音标 → 现代 IPA
PHONETIC_MAP = {
    # ⚠️⚠️ **schwa 必须映射回 IPA 的 ə，绝不能"纠正"成 a**。这是一次真实的翻车：
    #   ECDICT 里 'prɪzn(prison) 词尾的 ә(U+04D9) 表示**弱读/轻音**。
    #   我最初图"统一"写成  ә→a，结果转出 ˈprɪzn —— 词尾的轻音整个丢了，
    #   学生照着读会读成「prizn」，是**主动教错**。
    #   正确：ә(U+04D9，西里尔 schwa) → ə(U+0259，IPA schwa)。
    #   同理 `u` 在这类音标里也常表弱读，不要动它。
    'ә': 'ə',    # 西里尔 schwa → IPA schwa（**不是 a**）
    'ə': 'ə',    # IPA schwa 保持
    'ɒ': 'ɒ',    # 英式 lot 音
    'є': 'e',    # є → e
    'ё': 'e',    # ё 俄式 e
    'ɡ': 'ɡ',    # IPA 脚本 g
    'і': 'ɪ',    # і 旧式小写 i → ɪ
    'у': 'ʊ',    # у 俄式 u
    'х': 'h',    # х 俄式 kh
    'γ': 'ɡ',    # γ 希腊 gamma → ɡ
    'η': 'ŋ',    # η → ŋ
    'σ': 's',    # σ → s
    'φ': 'f',    # φ → f
    'ǝ': 'ə',    # 倒 e → schwa
}

# ⚠️ **`i`/`u` 在 ECDICT 音标里常表弱读**（'prɪzn 的ɪ 是正式的ɪ；
#    但 'bju:tiful 里词尾 l 前不该塞 ə）。
#    这里**只做 IPA 规范化，不做读音纠正** —— 宁可保守，
#    也不能把学生引到错误读音上。
MARK_MAP = {
    # ⚠️ **必须把 ASCII 的 `'`（U+0027）映射成 IPA 的 `ˈ`（U+02C8）**。
    #    ECDICT 全用 ASCII 撇号表重音（如 `'hæpi`），不转就不是 IPA。
    "'": 'ˈ',
    'ˈ': 'ˈ',  # 主重音
    'ˌ': 'ˌ',  # 次重音
    'ʹ': 'ˈ',  # 修饰字母 apostrophe → 主重音
    'ˊ': 'ˈ',  # 尖音符
    '^': '',          # 旧式重音符号，IPA 里不用
    '.': '',          # 旧式音节点
    ':': 'ː',  # 长音符号
    ';': '',          # 分音符，IPA 不用
    ',': 'ˈ',  # 旧式次重音 → IPA 次重音
    ' ': ' ',
    '(': '',
    ')': '',
    '/': '',
    '[': '',
    ']': '',
    '\\': '',
    '-': '',
    '?': '',
    '@': '',
    '\xa0': ' ',     # 不换行空格
}

# 多字符组合（先于单字符处理）
PHONETIC_PAIRS = [
    ('tʃ', '\x01'),   # 用占位符保护，不做替换（本来就已经是 IPA）
    ('dʒ', '\x02'),
]


# ---------------------------------------------------------------------------
# ECDICT 的 CSV 里，字段内的换行是**字面的两个字符** `\` + `n`，
# 不是真正的换行符 0x0A。实测 type 词条：
#   真换行 0 个、字面 \n 序列 3 个
#   → 直接入库会让前端 split('\n') 拿不到数组，整条释义挤成一行
# 所以入库前统一转成真换行。
# ⚠️ 只转释义与例句这类"我们确定是转义换行"的字段；
#    音标/词性等字段不能动（里面没有换行语义）。
LITERAL_NL = '\\n'


def normalize_definition(raw: str) -> str:
    """把字面 \\n 序列转成真换行，顺带清掉 CR。"""
    if not raw:
        return ''
    return raw.replace(LITERAL_NL, '\n').replace('\r\n', '\n').replace('\r', '\n').strip()


def to_ipa(src: str) -> str:
    """把 ECDICT 的音标转成规范 IPA。"""
    if not src:
        return ''
    s = src.strip().strip('/').strip()
    # 先把本来就是 IPA 的双字符辅音换成占位符保护，避免被单字符规则拆坏
    for a, b in PHONETIC_PAIRS:
        s = s.replace(a, b)
    out = []
    for ch in s:
        if ch == '\x01':
            out.append('tʃ')
            continue
        if ch == '\x02':
            out.append('dʒ')
            continue
        if ch in PHONETIC_MAP:
            out.append(PHONETIC_MAP[ch])
        elif ch in MARK_MAP:
            out.append(MARK_MAP[ch])
        else:
            out.append(ch)
    r = ''.join(out)
    # 压缩连续空格、去首尾空格
    while '  ' in r:
        r = r.replace('  ', ' ')
    return r.strip()


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--csv', required=True, help='ecdict.csv 路径')
    ap.add_argument('--db', required=True, help='目标 lexicon.db')
    args = ap.parse_args()

    if not os.path.exists(args.csv):
        sys.stderr.write('找不到 %s\n' % args.csv)
        sys.exit(1)
    if not os.path.exists(args.db):
        sys.stderr.write('找不到 %s（先用 build_lexicon.py 生成）\n' % args.db)
        sys.exit(1)

    db = sqlite3.connect(args.db)
    cur = db.cursor()

    # 中文释义单独一张表，**与 OEWN 英文释义物理隔离**。
    # 这样万一 ECDICT 上游来源被质疑，只需 drop 这张表换掉，
    # 英文释义与例句（CC BY 4.0）完全不受影响。
    cur.execute('''CREATE TABLE IF NOT EXISTS zh (
        word       TEXT PRIMARY KEY,
        definition TEXT NOT NULL,
        phonetic   TEXT,          -- 已转 IPA
        pos        TEXT,
        collins    INTEGER,       -- 柯林斯星级 1-5
        oxford     INTEGER,       -- 牛津 3000 标记
        tag        TEXT,          -- 考纲标签
        exchange   TEXT,          -- 屈折变化
        license    TEXT NOT NULL DEFAULT 'MIT'
    )''')
    cur.execute('CREATE INDEX IF NOT EXISTS idx_zh_tag ON zh(tag)')

    n = 0
    n_zh = 0
    batch = []
    sys.stderr.write('读取 %s ...\n' % args.csv)
    with open(args.csv, encoding='utf-8', newline='') as f:
        for row in csv.DictReader(f):
            n += 1
            word = (row.get('word') or '').strip().lower()
            tr = (row.get('translation') or '').strip()
            if not word or not tr:
                continue
            # 只保留**在 OEWN 里也存在**的词 —— 避免引入一堆无英文释义的孤立词条，
            # 也让两个来源的覆盖率统计有意义。
            exists = cur.execute(
                'SELECT 1 FROM entry WHERE word = ? LIMIT 1', (word,)
            ).fetchone()
            if not exists:
                continue

            def num(key):
                v = (row.get(key) or '').strip()
                try:
                    return int(v) if v else None
                except ValueError:
                    return None

            batch.append((
                word,
                normalize_definition(tr),
                to_ipa(row.get('phonetic') or ''),
                (row.get('pos') or '').split('/')[0][:8] if row.get('pos') else '',
                num('collins'),
                num('oxford'),
                (row.get('tag') or '').strip()[:120],
                normalize_definition(row.get('exchange') or '')[:200],
            ))
            n_zh += 1
            if len(batch) >= 5000:
                cur.executemany(
                    'INSERT OR REPLACE INTO zh'
                    '(word,definition,phonetic,pos,collins,oxford,tag,exchange) '
                    'VALUES(?,?,?,?,?,?,?,?)', batch)
                batch = []
                sys.stderr.write('  ... %d 行 / 已写入 %d\r' % (n, n_zh))
            if n % 500000 == 0:
                sys.stderr.write('\n')
    if batch:
        cur.executemany(
            'INSERT OR REPLACE INTO zh'
            '(word,definition,phonetic,pos,collins,oxford,tag,exchange) '
            'VALUES(?,?,?,?,?,?,?,?)', batch)

    db.commit()
    total = cur.execute('SELECT COUNT(*) FROM zh').fetchone()[0]
    both = cur.execute(
        'SELECT COUNT(*) FROM entry e JOIN zh z ON e.word = z.word').fetchone()[0]
    db.execute('VACUUM')
    db.close()
    sys.stderr.write('\n完成：\n')
    sys.stderr.write('  CSV 行数 %d\n' % n)
    sys.stderr.write('  中文释义 %d 条\n' % n_zh)
    sys.stderr.write('  表内总计 %d 条\n' % total)
    sys.stderr.write('  中英同时命中 %d 条（%.1f%% of OEWN）\n'
                     % (both, 100.0 * both / 128019))


if __name__ == '__main__':
    main()