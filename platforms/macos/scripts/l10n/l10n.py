#!/usr/bin/env python3
"""界面多语言流水线：收集 → 翻译 → 检查。编译时由 build-phase.sh 调用，也可手动跑。

  l10n.py collect   把编译器提取的界面文字（.stringsdata）同步进 Localizable.xcstrings；
                    守护进程（Go）的中文句式收进 Daemon.xcstrings（见 daemon_collect.py）
  l10n.py translate 给翻译表里缺的语言补译（优先 GPT：ChatGPT 自带的 codex CLI；其次 claude CLI；都没有就跳过）
  l10n.py check     有缺译、或代码里有绕开翻译表的中文 → 报出每一处；--strict 时以失败退出

stringsdata 的位置由环境变量 L10N_STRINGSDATA_ROOT 指定（编译时 = 本次构建的中间产物目录），
也可用 --stringsdata-root 传入。
"""
import argparse, json, os, re, subprocess, sys, collections

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from wrap_literals import tokenize, line_col, SKIP_BEFORE, CJK  # noqa: E402

MACOS = os.path.dirname(os.path.dirname(HERE))
SRC = os.path.join(MACOS, 'WgSense')
WIDGET = os.path.join(MACOS, 'WgSenseWidget')
CATALOG = os.path.join(SRC, 'Localizable.xcstrings')
DAEMON_CATALOG = os.path.join(SRC, 'Daemon.xcstrings')  # 守护进程句式，见 daemon_collect.py
# 两张表走同一套翻译与检查；load()/save()/missing() 作用于“当前表”。
CURRENT = CATALOG
CONTEXT = {
    CATALOG: 'Strings are app UI labels, buttons and status lines.',
    DAEMON_CATALOG: ('Strings are message templates from the background service (log lines and status/error '
                     'messages shown in the app). Keep log keywords like trusted=, state=, service=, interval= '
                     'and bracketed tags like [tunnel] unchanged.'),
}
ALLOWLIST = os.path.join(HERE, 'allowlist.txt')
GLOSSARY = os.path.join(HERE, 'glossary.json')
SOURCE_LANG = 'zh-Hans'
LANGS = ['en', 'zh-Hant', 'ja', 'ko', 'ru', 'fa', 'ar', 'tr', 'vi']
LANG_NAMES = {'en': 'English', 'zh-Hant': 'Traditional Chinese (Taiwan)', 'ja': 'Japanese', 'ko': 'Korean',
              'ru': 'Russian', 'fa': 'Persian', 'ar': 'Arabic', 'tr': 'Turkish', 'vi': 'Vietnamese'}
SPEC = re.compile(r'%(?:\d+\$)?(?:@|lld|ld|d|lf|f|\.\d+f|llu|lu|u|%)')


def stringsdata_files(root):
    out = []
    for r, _, fs in os.walk(root):
        out += [os.path.join(r, f) for f in fs if f.endswith('.stringsdata')]
    return out


def load():
    return json.load(open(CURRENT))


def save(d):
    # 与 Xcode 写出的格式一致（缩进 2、" : " 分隔），保留原有顺序，避免无意义的大 diff。
    with open(CURRENT, 'w') as f:
        f.write(json.dumps(d, ensure_ascii=False, indent=2, sort_keys=False, separators=(',', ' : ')) + '\n')


def glossary():
    if not os.path.exists(GLOSSARY):
        return {}
    return {k: v for k, v in json.load(open(GLOSSARY)).items() if not k.startswith('_')}


def glossary_violations(key, lang, value, terms=None):
    """原文含术语、译文却没用规定译名 → 返回违反的术语列表。"""
    terms = glossary() if terms is None else terms
    return [t for t, tr in terms.items() if t in key and tr.get(lang) and tr[lang] not in value]


def needs_translation(key, entry):
    if entry.get('shouldTranslate') is False:
        return False
    return bool(CJK.search(key))


# ---------- collect ----------

def collect(root):
    files = stringsdata_files(root)
    if not files:
        print('warning: 没找到 .stringsdata（编译设置 SWIFT_EMIT_LOC_STRINGS 没开？）')
        return
    args = ['xcrun', 'xcstringstool', 'sync', CATALOG]
    if os.environ.get('CONFIGURATION') == 'Release':
        # Release 不编译 #if DEBUG 的调试面板、会剥掉没用到的旧代码，那些文字提取不到；
        # 不标过期，免得 Debug / Release 交替构建时翻译表来回改。
        args.append('--skip-marking-strings-stale')
    for f in files:
        args += ['--stringsdata', f]
    subprocess.run(args, check=True)
    # 不含中文的键（格式串、地址示例、协议名）各语言相同，标记不翻译，免得每次被当成缺译。
    d = load()
    changed = False
    for key, entry in d['strings'].items():
        if not CJK.search(key) and entry.get('shouldTranslate') is not False:
            entry['shouldTranslate'] = False
            changed = True
    if changed:
        save(d)
    print(f'l10n collect: {len(files)} 个源文件已同步，共 {len(d["strings"])} 条')


# ---------- translate ----------

def missing(d):
    """缺译或没按术语表译的条目 → {原文: [语言]}。"""
    terms = glossary()
    out = collections.defaultdict(list)
    for key, entry in d['strings'].items():
        if entry.get('extractionState') == 'stale' or not needs_translation(key, entry):
            continue
        locs = entry.get('localizations', {})
        for lang in LANGS:
            unit = locs.get(lang, {}).get('stringUnit')
            if not unit or not unit.get('value') or unit.get('state') != 'translated' \
                    or glossary_violations(key, lang, unit['value'], terms):
                out[key].append(lang)
    return out


def specs(s):
    return sorted(re.sub(r'\d+\$', '', m) for m in SPEC.findall(s))


CODEX_DEFAULT = '/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex'


def _clean_env():
    # 子进程用干净环境：从 Xcode 或某个 Claude/Codex 会话里调用时，继承来的变量会把 CLI 指到别处。
    return {k: v for k, v in os.environ.items() if not k.startswith(('CLAUDE', 'ANTHROPIC', 'CODEX_'))}


def _translator():
    """翻译后端：优先 GPT（ChatGPT 自带的 codex CLI），其次 claude CLI。返回 (名字, 调用函数) 或 None。"""
    import tempfile
    env = _clean_env()
    codex = os.environ.get('L10N_CODEX') or (CODEX_DEFAULT if os.path.exists(CODEX_DEFAULT) else '') or \
        subprocess.run(['/bin/sh', '-lc', 'command -v codex'], capture_output=True, text=True).stdout.strip()
    if codex:
        def run_codex(prompt):
            with tempfile.TemporaryDirectory() as tmp:
                out = os.path.join(tmp, 'out.txt')
                subprocess.run([codex, 'exec', '--skip-git-repo-check', '--sandbox', 'read-only', '--ephemeral',
                                '-C', tmp, '-c', 'model_reasoning_effort="medium"', '-o', out, prompt],
                               capture_output=True, text=True, timeout=900, env=env, stdin=subprocess.DEVNULL)
                return open(out).read() if os.path.exists(out) else ''
        if '"ok"' in run_codex('Reply with exactly: {"ok":1}'):
            return 'GPT (codex)', run_codex
    claude = subprocess.run(['/bin/sh', '-lc', 'command -v claude'], capture_output=True, text=True).stdout.strip()
    if claude:
        def run_claude(prompt):
            r = subprocess.run([claude, '-p', prompt], capture_output=True, text=True, timeout=900, env=env,
                               stdin=subprocess.DEVNULL)
            return r.stdout
        if '"ok"' in run_claude('Reply with exactly: {"ok":1}'):
            return 'claude', run_claude
    return None


def _glossary_rule(chunk):
    terms = {t: tr for t, tr in glossary().items() if any(t in k for k in chunk)}
    if not terms:
        return ''
    return ('Glossary — product names, MUST be rendered exactly like this in every locale (do not translate '
            'or transliterate them differently): ' + json.dumps(terms, ensure_ascii=False) + '\n')


def _prompt(chunk):
    return (
        'You localize a macOS network utility (WireGuard VPN client + mihomo proxy dashboard). '
        + CONTEXT.get(CURRENT, '') + ' '
        'Source language is Simplified Chinese. Translate each source string into these locales: '
        + ', '.join(f'{l} ({LANG_NAMES[l]})' for l in LANGS) + '.\n'
        'Rules: keep it as short as the source (UI labels, buttons, status lines); keep technical terms '
        '(VPN, WireGuard, mihomo, DNS, IP, fake-ip, TUN, iperf3, op, daemon, GEO, SSH, Wi-Fi) unchanged; '
        'keep every format specifier exactly (%@, %lld, %lf, %%) — if word order must change use positional '
        'forms like %1$@ %2$lld; keep punctuation style natural for the target language; '
        'keep symbols/arrows/emoji as-is. Do not run any tools or read files.\n'
        + _glossary_rule(chunk) +
        'Return ONLY a JSON object: {"<source>": {"<locale>": "<translation>", ...}, ...} with exactly the '
        'given sources as keys.\n\nSources:\n' + json.dumps(chunk, ensure_ascii=False))


def translate(batch_size=40, workers=4):
    from concurrent.futures import ThreadPoolExecutor, as_completed
    todo = missing(load())
    if not todo:
        print('l10n translate: 没有缺译')
        return 0
    backend = _translator()
    if not backend:
        print(f'warning: 有 {len(todo)} 条缺译，但本机没有可用的翻译后端（ChatGPT 的 codex 或已登录的 claude CLI），跳过自动翻译')
        return len(todo)
    name, run = backend
    keys = list(todo)
    chunks = [keys[i:i + batch_size] for i in range(0, len(keys), batch_size)]
    print(f'l10n translate: 用 {name} 翻译 {len(keys)} 条，分 {len(chunks)} 批')
    done = 0

    def one(chunk):
        text = run(_prompt(chunk))
        m = re.search(r'\{.*\}', text, re.S)
        if not m:
            return chunk, None, f'没有返回 JSON：{text[:160]!r}'
        try:
            return chunk, json.loads(m.group(0)), None
        except json.JSONDecodeError as e:
            return chunk, None, f'JSON 解析失败：{e}'

    finished = 0
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for fut in as_completed([pool.submit(one, c) for c in chunks]):
            chunk, result, err = fut.result()
            finished += 1
            if err:
                print(f'warning: 一批翻译失败（{err}），留给下次')
                continue
            d = load()
            for key in chunk:
                tr = result.get(key) or {}
                locs = d['strings'].setdefault(key, {}).setdefault('localizations', {})
                for lang in todo[key]:
                    v = tr.get(lang)
                    if not isinstance(v, str) or not v.strip():
                        continue
                    if specs(v) != specs(key):
                        print(f'warning: 格式符不一致，丢弃 [{lang}] {key!r} → {v!r}')
                        continue
                    if glossary_violations(key, lang, v):
                        print(f'warning: 没按术语表译，丢弃 [{lang}] {key!r} → {v!r}')
                        continue
                    locs[lang] = {'stringUnit': {'state': 'translated', 'value': v}}
                    done += 1
            save(d)
            print(f'l10n translate: {finished}/{len(chunks)} 批完成')
    left = missing(load())
    print(f'l10n translate: 补译 {done} 项，仍缺 {len(left)} 条')
    return len(left)


# ---------- check ----------

def allowlist():
    if not os.path.exists(ALLOWLIST):
        return set()
    return {l.split('#')[0].strip() for l in open(ALLOWLIST) if l.split('#')[0].strip()}


def code_problems(root):
    """代码里的中文字面量，既不在编译器提取到的位置、也不是 String(localized:)、也不是比较/匹配用法 → 绕开了翻译表。"""
    extracted = collections.defaultdict(set)
    for path in stringsdata_files(root):
        d = json.load(open(path))
        name = os.path.splitext(os.path.basename(d.get('source') or path))[0]
        for table in d['tables'].values():
            for e in table:
                loc = e.get('location')
                if not loc:  # App Intents 等元数据条目没有源码位置
                    continue
                extracted[name].add((loc['startingLine'], loc['startingColumn']))
    allowed = allowlist()
    # Release 下有些代码没被编译/提取（见 collect）：退而按文字判断——翻译表里有这条就算已接入。
    # 精确的按位置判断在每次 Debug 构建里做。
    release = os.environ.get('CONFIGURATION') == 'Release'
    keys = set(load()['strings']) if release else set()
    interp = re.compile(r'\\\((?:[^()]|\([^()]*\))*\)')
    out = []
    for base in (SRC, WIDGET):
        for r, _, fs in os.walk(base):
            for f in fs:
                if not f.endswith('.swift'):
                    continue
                p = os.path.join(r, f)
                src = open(p).read()
                stem = f[:-6]
                for s, e, text, depth in tokenize(src):
                    if not CJK.search(text) or text in allowed:
                        continue
                    line, col, bcol = line_col(src, s)
                    if (line, col) in extracted[stem] or (line, bcol) in extracted[stem]:
                        continue
                    before = src[max(0, s - 60):s].split('\n')[-1]
                    if release and not re.search(r'verbatim:\s*$', before) and \
                            (text in keys or interp.sub('%@', text) in keys or interp.sub('%lld', text) in keys):
                        continue
                    if re.search(r'verbatim:\s*$', before):
                        out.append((p, line, text, 'Text(verbatim:) 直接显示中文，不会被翻译'))
                        continue
                    if re.search(r'String\(localized:\s*$', before) and not src.startswith(', bundle: .wgLocalized', e):
                        out.append((p, line, text, 'String(localized:) 没带 bundle: .wgLocalized，App 内切换语言后要重启才变'))
                        continue
                    if SKIP_BEFORE.search(before):
                        continue
                    out.append((p, line, text, '普通字符串不会被翻译，改成 String(localized: …, bundle: .wgLocalized)'))
    return out


def check(root, strict):
    problems = 0
    for p, line, text, why in code_problems(root):
        print(f'{p}:{line}: {"error" if strict else "warning"}: 绕开翻译表：“{text}” — {why}')
        problems += 1
    global CURRENT
    for cat in (CATALOG, DAEMON_CATALOG):
        CURRENT = cat
        for key, langs in missing(load()).items():
            print(f'{CURRENT}:1: {"error" if strict else "warning"}: 缺译或没按术语表 [{", ".join(langs)}]：“{key}”')
            problems += 1
    CURRENT = CATALOG
    if problems:
        print(f'l10n check: {problems} 处问题'
              + ('（发版构建会失败；先跑 scripts/l10n/l10n.py translate，代码问题可用 wrap_literals.py --apply 批量修）' if strict else ''))
    else:
        print('l10n check: 通过')
    return 1 if (problems and strict) else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', choices=['collect', 'translate', 'check'])
    ap.add_argument('--stringsdata-root', default=os.environ.get('L10N_STRINGSDATA_ROOT'))
    ap.add_argument('--strict', action='store_true')
    a = ap.parse_args()
    if a.cmd in ('collect', 'check') and not a.stringsdata_root:
        ap.error('需要 --stringsdata-root（构建中间产物目录）')
    global CURRENT
    if a.cmd == 'collect':
        collect(a.stringsdata_root)
        import daemon_collect
        daemon_collect.collect()
    elif a.cmd == 'translate':
        left = 0
        for cat in (CATALOG, DAEMON_CATALOG):
            CURRENT = cat
            print(f'l10n translate: {os.path.basename(cat)}')
            left += translate()
        CURRENT = CATALOG
    else:
        sys.exit(check(a.stringsdata_root, a.strict))


if __name__ == '__main__':
    main()
