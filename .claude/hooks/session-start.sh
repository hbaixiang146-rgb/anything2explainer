#!/bin/bash
# SessionStart hook — 只在 Claude Code on the web（CLAUDE_CODE_REMOTE=true）执行，本地会话直接跳过。
# 1. 把本 repo 链接成用户级 skill：~/.claude/skills/anything2explainer
# 2. 装 skill 依赖：ffmpeg / zsh（scripts/*.sh 用 zsh）/ rsync（new_project.sh）/ espeak-ng（kokoro 英文 G2P）
#    与 Python 包：numpy pillow scipy（QC 脚本）、soundfile edge-tts kokoro-onnx（配音）
# 3. 下载 kokoro-onnx 模型（GitHub releases），把渲染 / 配音用的环境变量写进 $CLAUDE_ENV_FILE
# 不装 torch 版 kokoro：它的权重在 huggingface.co，云端网络策略常挡；kokoro-onnx 是 tts_build.py 已支持的等价引擎。
# 幂等：已装的跳过；stdout 会进会话上下文，所以只在最后输出一行摘要。
set -euo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

REPO="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"
warn() { echo "session-start: $*" >&2; }

mkdir -p "$HOME/.claude/skills"
ln -sfn "$REPO" "$HOME/.claude/skills/anything2explainer"

missing=()
for bin in ffmpeg zsh rsync espeak-ng; do
  command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
done
if [ ${#missing[@]} -gt 0 ]; then
  export DEBIAN_FRONTEND=noninteractive
  # 个别第三方 PPA 被网络策略挡时 update 只报 warning，主仓库照常可用
  $SUDO apt-get update -qq >&2 || warn "apt-get update reported errors, continuing"
  $SUDO apt-get install -y -qq --no-install-recommends "${missing[@]}" >&2
fi

PY_PKGS=(numpy pillow scipy soundfile 'edge-tts>=7.2.0' kokoro-onnx)
if ! python3 -c 'import numpy, PIL, scipy, soundfile, edge_tts, kokoro_onnx' >/dev/null 2>&1; then
  python3 -m pip install -q "${PY_PKGS[@]}" >&2 \
    || python3 -m pip install -q --break-system-packages "${PY_PKGS[@]}" >&2
fi

KDIR="$HOME/.cache/kokoro-onnx"
KBASE="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
mkdir -p "$KDIR"
for f in kokoro-v1.0.onnx voices-v1.0.bin; do
  [ -s "$KDIR/$f" ] && continue
  if curl -sSfL --retry 3 -o "$KDIR/$f.part" "$KBASE/$f"; then
    mv "$KDIR/$f.part" "$KDIR/$f"
  else
    rm -f "$KDIR/$f.part"; warn "failed to download $f; TTS_ENGINE=kokoro_onnx will not work"
  fi
done

# Remotion 默认从 remotion.media 下载浏览器（常被挡）；容器预装了 Playwright 的 headless shell，模板的
# remotion.config.ts 读到 REMOTION_BROWSER_EXECUTABLE 就改用它（并开 swangle 软件 GL）
BROWSER=$(ls -d /opt/pw-browsers/chromium_headless_shell-*/chrome-linux/headless_shell 2>/dev/null | sort -V | tail -1 || true)

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    [ -n "$BROWSER" ] && echo "export REMOTION_BROWSER_EXECUTABLE=$BROWSER"
    echo "export KOKORO_ONNX_MODEL=$KDIR/kokoro-v1.0.onnx"
    echo "export KOKORO_ONNX_VOICES=$KDIR/voices-v1.0.bin"
    echo "export KOKORO_ONNX_VOICE=am_liam"
  } >> "$CLAUDE_ENV_FILE"
fi

reachable() { curl -s -o /dev/null --max-time 5 "$1"; }
notes=()
reachable https://speech.platform.bing.com/ || notes+=("edge-tts host blocked (speech.platform.bing.com)")
reachable https://huggingface.co/ || notes+=("kokoro weights host blocked (huggingface.co)")
msg="anything2explainer: skill linked, deps ready, kokoro_onnx preset (am_liam)"
[ -n "$BROWSER" ] && msg+=", REMOTION_BROWSER_EXECUTABLE set"
if [ ${#notes[@]} -gt 0 ]; then
  joined=$(printf '%s; ' "${notes[@]}")
  msg+=". Network: ${joined%; } → use TTS_ENGINE=kokoro_onnx (en voice am_liam, zh voice zm_yunxi with KOKORO_ONNX_LANG=cmn)"
fi
echo "$msg"
