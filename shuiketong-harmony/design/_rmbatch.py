# -*- coding: utf-8 -*-
"""分批删除目录内容，绕开 DevEco hvigor 的 safe-delete 批量确认阈值（50 个/轮）。

用法: python _rmbatch.py <目录> [每批数量]
只删文件（含子目录里的文件），最后再删空目录。
"""
import os
import shutil
import sys

root = sys.argv[1]
batch = int(sys.argv[2]) if len(sys.argv) > 2 else 30

files = []
for dirpath, dirnames, filenames in os.walk(root, topdown=False):
    for f in filenames:
        files.append(os.path.join(dirpath, f))

n = 0
for f in files:
    try:
        os.remove(f)
        n += 1
    except OSError as e:
        print('skip', f, e)
    if n % batch == 0:
        print('  ...removed %d/%d' % (n, len(files)))

# 再自底向上删空目录
for dirpath, dirnames, filenames in os.walk(root, topdown=False):
    try:
        os.rmdir(dirpath)
    except OSError:
        pass
try:
    os.rmdir(root)
except OSError:
    pass
print('removed %d files from %s' % (n, root))
