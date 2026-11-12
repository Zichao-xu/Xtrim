#!/usr/bin/env python3
"""Check public README assets, internal links and release/version consistency."""
from pathlib import Path
from html import unescape
from urllib.parse import unquote, urlsplit
import re
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
errors = []
readme = (ROOT / "README.md").read_text()
project = (ROOT / "platforms/macos/project.yml").read_text()
versions = set(re.findall(r'MARKETING_VERSION: "([^"]+)"', project))
if len(versions) != 1:
    errors.append("App and Widget marketing versions must agree")
version = next(iter(versions), "missing")
release = ROOT / f"docs/releases/v{version}.md"
if not release.is_file() or f"docs/releases/v{version}.md" not in readme:
    errors.append(f"README must link to current release notes v{version}")

links = re.findall(r'!?\[[^\]]*\]\(([^\s)]+)(?:\s+"[^"]*")?\)', readme)
links += re.findall(r'(?:href|src|srcset)="([^"]+)"', readme)
anchors = set(re.findall(r'^#{1,6} (.+)$', readme, re.M))
anchors = {re.sub(r'[^\w\- ]', '', s.lower()).replace(' ', '-') for s in anchors}
local_links = 0
media = set()
for raw in links:
    url = urlsplit(unescape(raw))
    if url.scheme:
        if url.scheme != "https":
            errors.append(f"Unexpected non-HTTPS public link: {raw}")
        continue
    if not url.path:
        if unquote(url.fragment) not in anchors:
            errors.append(f"Missing README section: {raw}")
        continue
    local_links += 1
    path = (ROOT / unquote(url.path)).resolve()
    if not path.is_relative_to(ROOT) or not path.is_file():
        errors.append(f"Missing or outside-repository link: {raw}")
        continue
    if path.suffix.lower() in (".png", ".gif", ".svg"):
        media.add(path)

for path in sorted(media):
    data = path.read_bytes()
    if len(data) > 5 * 1024 * 1024:
        errors.append(f"README asset exceeds 5 MiB: {path.relative_to(ROOT)}")
    if path.suffix == ".png":
        if data[:8] != b'\x89PNG\r\n\x1a\n':
            errors.append(f"Invalid PNG: {path.name}")
            continue
        width, height = struct.unpack('>II', data[16:24])
        # 尺寸下限只针对截图；branding/ 下的字标等品牌资源本就是扁长条
        is_brand = path.relative_to(ROOT).parts[0] == "branding"
        if not is_brand and (width < 640 or height < 200):
            errors.append(f"Screenshot too small: {path.name} {width}x{height}")
    elif path.suffix == ".gif":
        if data[:6] not in (b'GIF87a', b'GIF89a'):
            errors.append(f"Invalid GIF: {path.name}")
    elif path.suffix == ".svg":
        if b'<svg' not in data or b'<script' in data:
            errors.append(f"Invalid or scripted SVG: {path.name}")

if not media:
    errors.append("Product README has no local visual assets")
if readme.count("<details>") != readme.count("</details>"):
    errors.append("Unbalanced README disclosure sections")
for pattern in (r'/Users/[^\s]+', r'(?i)PrivateKey\s*=', r'(?i)PresharedKey\s*='):
    if re.search(pattern, readme):
        errors.append("Personal path or configuration key found in README")

if errors:
    print("README checks failed:\n" + "\n".join(f"- {e}" for e in errors))
    sys.exit(1)
print(f"README checks passed: {local_links} local links, {len(media)} visual assets, v{version}")
