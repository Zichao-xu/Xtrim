#!/usr/bin/env python3
"""一次性迁移：把绕开翻译表的中文字符串字面量改成 String(localized:)。

判定依据（不靠猜）：
  - 编译器提取的 .stringsdata 带每条可翻译文字的行列号；在那些位置上的字面量本来就进翻译表，不动。
  - 注释、比较/匹配/键名等「当标识用」的上下文不动；同一段文字只要在任何地方被当标识用过，全仓都不动，
    交给人工（否则一处翻了、另一处拿中文去比，换语言后行为就变了）。

用法：wrap_literals.py <WgSense 源码目录> <stringsdata 列表文件> [--apply]
不带 --apply 只打印将改动的位置与跳过原因。
"""
import json, os, re, sys, collections

CJK = re.compile('[一-鿿]')

# 字面量前面紧挨着这些 → 当标识用，不翻译。
SKIP_BEFORE = re.compile(
    r'(==|!=|\bcase|\bcase\s+\w+\s*=|\.contains\(|hasPrefix\(|hasSuffix\(|range\(of:|firstRange\(of:|replacingOccurrences\(of:|'
    r'with:|components\(separatedBy:|split\(separator:|forKey:|AppStorage\(|starts\(with:|'
    r'\bverbatim:|String\(localized:|LocalizedStringKey\(|LocalizedStringResource\(|Logger\(|\blog\w*\(|print\(|NSLog\(|'
    r'ShellCommand\.\w+\(|fatalError\(|precondition\w*\(|assert\w*\(|#Preview\(|message:|Regex|try Regex\()\s*$')


def tokenize(src):
    """返回 [(start, end, text, depth)]：每个 "..." 字面量（含插值里嵌套的）在源码中的偏移。跳过注释与多行字面量。"""
    out = []
    i, n = 0, len(src)
    stack = []  # 插值括号深度
    def scan_string(i, depth):
        start = i
        i += 1
        while i < n:
            c = src[i]
            if c == '\\' and i + 1 < n and src[i + 1] == '(':
                # 插值：扫到配对的 )
                i += 2
                level = 1
                while i < n and level:
                    if src[i] == '"':
                        i = scan_string(i, depth + 1)
                        continue
                    if src[i] == '(':
                        level += 1
                    elif src[i] == ')':
                        level -= 1
                    i += 1
                continue
            if c == '\\':
                i += 2
                continue
            if c == '"':
                out.append((start, i + 1, src[start + 1:i], depth))
                return i + 1
            if c == '\n':
                return i
            i += 1
        return i
    while i < n:
        if src.startswith('//', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
            continue
        if src.startswith('/*', i):
            j = src.find('*/', i)
            i = n if j < 0 else j + 2
            continue
        if src.startswith('"""', i):
            j = src.find('"""', i + 3)
            i = n if j < 0 else j + 3
            continue
        if src[i] == '#' and src.startswith('#"', i):
            j = src.find('"#', i + 2)
            i = n if j < 0 else j + 2
            continue
        if src[i] == '"':
            i = scan_string(i, 0)
            continue
        i += 1
    return out


def line_col(src, off):
    line = src.count('\n', 0, off) + 1
    ls = src.rfind('\n', 0, off) + 1
    return line, off - ls + 1, len(src[ls:off].encode()) + 1


def main():
    root, listfile = sys.argv[1], sys.argv[2]
    apply = '--apply' in sys.argv
    extracted = collections.defaultdict(set)  # 文件名 -> {(line, col)}
    for path in open(listfile).read().split():
        d = json.load(open(path))
        name = os.path.splitext(os.path.basename(d.get('source') or path))[0]
        for table in d['tables'].values():
            for e in table:
                loc = e.get('location')
                if not loc:  # App Intents 等元数据条目没有源码位置
                    continue
                extracted[name].add((loc['startingLine'], loc['startingColumn']))

    files = []
    for r, _, fs in os.walk(root):
        for f in fs:
            if f.endswith('.swift'):
                files.append(os.path.join(r, f))

    # 第一遍：找出被当标识用的文字
    identity = set()
    found = []
    for p in files:
        src = open(p).read()
        stem = os.path.basename(p)[:-6]
        for s, e, text, depth in tokenize(src):
            if not CJK.search(text):
                continue
            line, col, bcol = line_col(src, s)
            if (line, col) in extracted[stem] or (line, bcol) in extracted[stem]:
                continue
            before = src[max(0, s - 60):s]
            before = before.split('\n')[-1]
            if SKIP_BEFORE.search(before):
                if not re.search(r'(verbatim:|String\(localized:|LocalizedStringKey\(|LocalizedStringResource\()\s*$', before):
                    identity.add(text)
                found.append((p, s, e, text, 'skip'))
                continue
            found.append((p, s, e, text, 'wrap'))

    report = collections.Counter()
    edits = collections.defaultdict(list)
    for p, s, e, text, kind in found:
        if kind == 'wrap' and text in identity:
            kind = 'identity'
        report[kind] += 1
        if kind == 'wrap':
            edits[p].append((s, e))
        elif kind == 'identity':
            src = open(p).read()
            print(f'IDENTITY {os.path.relpath(p, root)}:{line_col(src, s)[0]}  "{text}"')
    print(dict(report))
    if not apply:
        return
    for p, spans in edits.items():
        src = open(p).read()
        # 从后往前替换；嵌套字面量（插值里的）与外层互不重叠地包裹：内层先于外层处理会改变外层偏移，
        # 所以按起点倒序、并且外层 end 用替换后的长度修正。
        spans.sort(key=lambda x: x[0], reverse=True)
        grow = len('String(localized: ') + len(', bundle: .wgLocalized)')
        done = []
        for s, e in spans:
            e2 = e + grow * sum(1 for a, b in done if a > s and b <= e)
            src = src[:s] + 'String(localized: ' + src[s:e2] + ', bundle: .wgLocalized)' + src[e2:]
            done.append((s, e))
        open(p, 'w').write(src)


if __name__ == '__main__':
    main()
