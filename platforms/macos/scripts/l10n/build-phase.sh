#!/bin/sh
# Xcode 构建阶段（编译之后、打包资源之前）：收集界面文字 → 发版构建自动补译 → 检查。
# Debug：只提示（预览构建不被卡住）；Release：有缺译或绕开翻译表的写法就让构建失败，混用的版本发不出去。
set -e
L10N="$SRCROOT/scripts/l10n/l10n.py"
# 只看本配置的提取结果（Debug/Release 分开，免得混进另一套旧行号）
export L10N_STRINGSDATA_ROOT="$CONFIGURATION_TEMP_DIR"
/usr/bin/python3 "$L10N" collect
if [ "$CONFIGURATION" = "Release" ]; then
  [ "${L10N_AUTO_TRANSLATE:-1}" = "1" ] && /usr/bin/python3 "$L10N" translate || true
  /usr/bin/python3 "$L10N" check --strict
else
  /usr/bin/python3 "$L10N" check
fi
