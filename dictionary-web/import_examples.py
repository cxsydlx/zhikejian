#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
导入 Tatoeba 例句（简体中文↔英语），让每个词条带**双语例句**。

## 授权（CC BY 2.0 FR 的署名义务必须履行）
数据来自 manythings.org 整理的 Tatoeba 语料：
    https://www.manythings.org/anki/cmn-eng.zip
    原始项目：https://tatoeba.org
    许可：**CC-BY 2.0 FR**（法国 CC BY 2.0）

⚠️ **CC-BY 的硬性义务是「署名作者」**，不是只署个来源名。
   好在 manythings 的每行第 3 列**已经带好归属信息**，例如：
     Hi.\\t嗨。\\tCC-BY 2.0 (France) Attribution: tatoeba.org #538123 (CM) & #891077 (Martha)
   本脚本把第 3 列**原样存库**，前端必须展示 —— 否则就是侵权。

## 为什么用它
- OEWN 自带例句只覆盖 30.6%（且 computer / dictionary 这类高频词反而没有）
- ECDICT 的 `detail` 字段**实测几乎是空的**（25 万行仅 1 条），官方README 也写"待添加"
- Tatoeba 是例句的标准开源来源，且是**双语**（英+中），对学生价值最高

## 为什么只取「含中文翻译」的句子
Tatoeba 英文库有719 万句，但**只有一部分有中文翻译**（本包 32028 对）。
只取这个包 = 只用有人工翻译的句子，避免"英文例句 + 机翻中文"的低质量组合。

用法:
    python3 import_examples.py --zip data/cmn-eng.zip --db lexicon.db
"""

import argparse
import collections
import io
import json
import os
import re
import sqlite3
import sys
import zipfile

# 每词最多保留的例句数（避免库膨胀，也够看了）
MAX_PER_WORD = 4
# 例句长度上限（vp/字符），太长的句子对查词场景没用
MAX_LEN = 120

_WORD_RE = re.compile(r"[A-Za-z][A-Za-z\-']*")


def extract_words(sentence: str):
    """从英文句子里提取所有单词（去标点、小写）。"""
    out = []
    for m in _WORD_RE.finditer(sentence):
        w = m.group(0).lower().strip("'-")
        if 1 < len(w) <= 24:
            out.append(w)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--zip', required=True, help='cmn-eng.zip 路径')
    ap.add_argument('--db', required=True, help='目标 lexicon.db')
    args = ap.parse_args()

    if not os.path.exists(args.zip):
        sys.stderr.write('找不到 %s\n' % args.zip)
        sys.exit(1)

    zf = zipfile.ZipFile(args.zip)
    inner = None
    for n in zf.namelist():
        if n.endswith('.txt') and 'about' not in n:
            inner = n
            break
    if inner is None:
        sys.stderr.write('压缩包里没找到数据文件\n')
        sys.exit(1)

    raw = zf.read(inner).decode('utf-8')
    lines = [l for l in raw.split('\n') if l.strip()]
    sys.stderr.write('读入句对 %d\n' % len(lines))

    # word -> [(en, zh, attribution), ...]
    bucket = collections.defaultdict(list)
    skipped_bad = 0
    for line in lines:
        parts = line.split('\t')
        if len(parts) < 3:
            skipped_bad += 1
            continue
        en, zh, attribution = parts[0].strip(), parts[1].strip(), parts[2].strip()
        if not en or not zh:
            skipped_bad += 1
            continue
        if len(en) > MAX_LEN:
            continue
        for w in extract_words(en):
            bucket[w].append((en, zh, attribution))

    sys.stderr.write('覆盖英文词 %d 个（丢弃 %d 条格式异常）\n'
                     % (len(bucket), skipped_bad))

    db = sqlite3.connect(args.db)
    cur = db.cursor()
    # ⚠️ **必须存 attribution**。CC-BY 2.0 FR 要求署名到句子作者，
    #    只在页脚写一句 "来自 Tatoeba" 不满足许可条件。
    cur.execute('''CREATE TABLE IF NOT EXISTS example (
        word        TEXT NOT NULL,
        en          TEXT NOT NULL,
        zh          TEXT NOT NULL,
        attribution TEXT NOT NULL,
        PRIMARY KEY (word, en)
    )''')

    rows = []
    for w, items in bucket.items():
        # 同一句可能重复命中，去重后取前 MAX_PER_WORD
        seen = set()
        kept = 0
        for en, zh, at in items:
            if en in seen:
                continue
            seen.add(en)
            rows.append((w, en, zh, at))
            kept += 1
            if kept >= MAX_PER_WORD:
                break

    cur.executemany(
        'INSERT OR REPLACE INTO example(word, en, zh, attribution) VALUES(?,?,?,?)',
        rows)
    db.commit()

    total = cur.execute('SELECT COUNT(*) FROM example').fetchone()[0]
    words = cur.execute('SELECT COUNT(DISTINCT word) FROM example').fetchone()[0]
    # 与中英词条的交集才是真正能显示例句的
    hit = cur.execute(
        'SELECT COUNT(*) FROM (SELECT DISTINCT e.word FROM example e '
        'JOIN zh z ON e.word = z.word)').fetchone()[0]
    db.execute('VACUUM')
    db.close()

    sys.stderr.write('\n完成：\n')
    sys.stderr.write('  例句条目 %d 条\n' % total)
    sys.stderr.write('  覆盖单词 %d 个\n' % words)
    sys.stderr.write('  与中文释义交集 %d 个（%.1f%% of 107998）\n'
                     % (hit, 100.0 * hit / 107998))


if __name__ == '__main__':
    main()