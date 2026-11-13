#!/usr/bin/env python3
"""守护进程（Go）的中文句式 → WgSense/Daemon.xcstrings。

守护进程的日志和接口提示是中文原文；App 显示时按句式认出来再换成当前语言（见 WgDaemonText.swift）。
这里把 Go 源码里每个带中文的字符串字面量收成一条句式：格式动词（%v %s %d %.1f …）统一换成 %@，
供翻译和运行时匹配。源码里删掉的句式标记为过期（保留译文）。
"""
import json, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
MACOS = os.path.dirname(os.path.dirname(HERE))
CORE = os.path.join(os.path.dirname(os.path.dirname(MACOS)), 'core')
CATALOG = os.path.join(MACOS, 'WgSense', 'Daemon.xcstrings')
CJK = re.compile('[一-鿿]')
GO_VERB = re.compile(r'%[-+# 0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?[vTtbcdoOqxXUeEfFgGspw]')
ESCAPES = {'n': '\n', 't': '\t', '"': '"', '\\': '\\', 'r': '\r', "'": "'"}


def go_literals(src):
    """返回 Go 源码里的字符串字面量（已反转义），跳过注释、rune 字面量。"""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith('//', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
        elif src.startswith('/*', i):
            j = src.find('*/', i + 2)
            i = n if j < 0 else j + 2
        elif c == '`':
            j = src.find('`', i + 1)
            if j < 0:
                break
            out.append(src[i + 1:j])
            i = j + 1
        elif c == "'":
            j = i + 1
            while j < n and src[j] != "'":
                j += 2 if src[j] == '\\' else 1
            i = j + 1
        elif c == '"':
            j, buf = i + 1, []
            while j < n and src[j] != '"' and src[j] != '\n':
                if src[j] == '\\' and j + 1 < n:
                    buf.append(ESCAPES.get(src[j + 1], '\\' + src[j + 1]))
                    j += 2
                else:
                    buf.append(src[j])
                    j += 1
            out.append(''.join(buf))
            i = j + 1
        else:
            i += 1
    return out


def template(text):
    """Go 格式串 → 句式键：格式动词换成 %@；单独的 % 转义成 %%（保持 %% 原样）。"""
    parts = re.split(r'(%%|' + GO_VERB.pattern + ')', text)
    key = []
    for p in parts:
        if p == '%%':
            key.append('%%')
        elif p and GO_VERB.fullmatch(p):
            key.append('%@')
        else:
            key.append(p.replace('%', '%%'))
    # 两头的分隔符去掉：Go 常写 reason += "；另放行 %d 个…"，运行时按分隔符拆段后再逐段匹配。
    return ''.join(key).strip().strip('；，、：').strip()  # 只去全角分隔符：半角冒号可能是内容（如 fd77:6773::）


def scan():
    keys = set()
    for root, dirs, files in os.walk(CORE):
        dirs[:] = [d for d in dirs if d not in ('testdata', 'vendor')]
        for f in files:
            if not f.endswith('.go') or f.endswith('_test.go'):
                continue
            for lit in go_literals(open(os.path.join(root, f), encoding='utf-8').read()):
                if not CJK.search(lit):
                    continue
                key = template(lit)
                # 只有格式符、标点、单个字的碎片不收：运行时片段替换会误伤。
                if len(CJK.findall(key)) < 2:
                    continue
                keys.add(key)
    return keys


def collect():
    keys = scan()
    d = json.load(open(CATALOG)) if os.path.exists(CATALOG) else {'sourceLanguage': 'zh-Hans', 'strings': {}, 'version': '1.0'}
    strings = d['strings']
    for key in sorted(keys):
        entry = strings.setdefault(key, {})
        entry['extractionState'] = 'manual'
        entry['comment'] = '守护进程日志 / 接口提示（Go 源码句式）'
    for key, entry in strings.items():
        if key not in keys:
            entry['extractionState'] = 'stale'
    with open(CATALOG, 'w') as f:
        f.write(json.dumps(d, ensure_ascii=False, indent=2, sort_keys=False, separators=(',', ' : ')) + '\n')
    print(f'l10n collect: 守护进程句式 {len(keys)} 条')


if __name__ == '__main__':
    collect()
