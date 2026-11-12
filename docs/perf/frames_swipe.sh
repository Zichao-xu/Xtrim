#!/bin/zsh
# frames.sh <label>：启动 App（代理页）→ 前台 → 滚动 10s 同时记录帧间隔
SP=/private/tmp/claude-502/-Users-adams/e49ae08d-980e-4cf5-9912-fdccfe806f57/scratchpad
pkill -f "/Applications/Xtrim.app/Contents/MacOS/Xtrim"; sleep 1; rm -f /tmp/wgsense-frames.txt
open -n /Applications/Xtrim.app --args -WgSenseInitialTab proxy -WgSenseFrameProbe 13
sleep 2.5; osascript -e 'tell application id "com.wgsense.macos" to activate'; sleep 0.8
$SP/swipe 11; sleep 2
echo "[$1] $(cat /tmp/wgsense-frames.txt 2>/dev/null)"
