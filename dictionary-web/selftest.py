# -*- coding: utf-8 -*-
"""本机接口自测：改释义授权闸门 + 输入校验 + 发音路由。"""
import json
import sys
import urllib.error
import urllib.request

BASE = 'http://127.0.0.1:8789'


def get(path):
    try:
        with urllib.request.urlopen(BASE + path, timeout=8) as r:
            return r.status, json.loads(r.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode('utf-8'))


def put(path, obj):
    req = urllib.request.Request(
        BASE + path, data=json.dumps(obj).encode('utf-8'),
        headers={'Content-Type': 'application/json'}, method='PUT')
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return r.status, json.loads(r.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode('utf-8'))


fails = []


def check(name, cond, detail=''):
    print(('  PASS  ' if cond else '  FAIL  ') + name + ('  ' + detail if detail else ''))
    if not cond:
        fails.append(name)


print('=== 1. 授权闸门：不带licenseAgree 必须被拒 ===')
c, j = put('/api/v1/word', {'word': 'hello', 'definition': 'ni hao'})
check('无 licenseAgree -> 400', c == 400, str(j))
check('错误信息提到授权', 'licenseAgree' in j.get('error', ''), j.get('error', ''))

print()
print('=== 2. 带 licenseAgree 应成功 ===')
c, j = put('/api/v1/word', {
    'word': 'hello', 'definition': 'nihao; da zhaohao',
    'submitter': 'tester', 'licenseAgree': True})
check('带 licenseAgree -> 200', c == 200, str(j))
check('返回 license=CC-BY-SA-4.0', j.get('license') == 'CC-BY-SA-4.0')

print()
print('=== 3. 复查：社区释义 + modified 标记 + 举证字段 ===')
c, j = get('/api/v1/word?w=hello')
check('modified=True', j.get('modified') is True)
ue = j.get('userEdit') or {}
check('释义已保存', ue.get('definition', '').startswith('nihao'))
check('记录了 submitter', ue.get('submitter') == 'tester')
check('记录了时间戳', isinstance(ue.get('createdAt'), int) and ue['createdAt'] > 1600000000)
check('记录了 license', ue.get('license') == 'CC-BY-SA-4.0')

print()
print('=== 4. 输入校验 ===')
c, j = get('/api/v1/word?w=123abc')
check('数字开头 -> 400', c == 400, str(j))
c, j = get('/api/v1/word?w=' + 'a' * 60)
check('超长 -> 400', c == 400)
c, j = get('/api/v1/word')
check('缺参数 -> 400', c == 400)
c, j = put('/api/v1/word', {'word': 'ok', 'definition': '', 'licenseAgree': True})
check('空释义 -> 400', c == 400)

print()
print('=== 5. 离线词表接口须限内网（本机算内网，应放行） ===')
c, j = get('/api/v1/words')
check('内网可拉离线词表', c == 200 and j.get('count', 0) > 100000,
      'count=%s' % j.get('count'))

print()
print('=== 6. 发音（本机无 espeak-ng，应优雅降级为 503） ===')
c, _ = get('/api/v1/word/hello/audio?accent=gb')
check('无 espeak-ng -> 503（不是 500）', c == 503, 'HTTP %s' % c)

print()
print('=== 7. 授权清单接口 ===')
c, j = get('/api/v1/licenses')
check('licenses 可读', c == 200 and len(j.get('licenses', [])) >= 4)
names = [x['name'] for x in j.get('licenses', [])]
check('含 Open English WordNet', 'Open English WordNet' in names)
check('含 Princeton WordNet（CC BY 要求双署名）', 'Princeton WordNet' in names)
check('含 espeak-ng', 'espeak-ng' in names)

print()
print('=== 8. 批量查词 ===')
c, j = get('/api/v1/batch?w=happy,sad,notaword,water')
check('批量返回 200', c == 200)
check('命中 3 个', j.get('count') == 3, 'count=%s' % j.get('count'))

print()
print('=== 9. 首页可访问 ===')
try:
    with urllib.request.urlopen(BASE + '/', timeout=8) as r:
        html = r.read().decode('utf-8')
    check('首页 200 且含授权声明', 'Open English WordNet' in html)
    check('首页含 Princeton 署名', 'Princeton' in html)
except Exception as e:
    check('首页可访问', False, repr(e))

print()
print('=' * 50)
print('失败 %d 项' % len(fails))
for f in fails:
    print('  - ' + f)
sys.exit(1 if fails else 0)