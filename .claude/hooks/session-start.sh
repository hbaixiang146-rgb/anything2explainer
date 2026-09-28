#!/bin/bash
# SessionStart hook — 只在 Claude Code on the web（CLAUDE_CODE_REMOTE=true）执行，本地会话直接跳过。
# 1. 把本 repo 链接成用户级 skill：~/.claude/skills/anything2explainer
# 2. 装 skill 依赖：ffmpeg / zsh（scripts/*.sh 用 zsh）/ rsync（new_project.sh）/ espeak-ng（kokoro 英文 G2P）
#    与 Python 包：numpy pillow scipy（QC 脚本）、soundfile edge-tts kokoro-onnx（配音）
# 3. 下载 kokoro-onnx 模型（GitHub releases），把渲染 / 配音用的环境变量写进 $CLAUDE_ENV_FILE
# 4. huggingface.co 可达时再装 torch 版 kokoro（英文默认引擎）并预热权重；不可达时它装了也跑不动，跳过
# 幂等：已装的跳过；stdout 会进会话上下文，所以只在最后输出一行摘要。
set -euo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

REPO="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"
warn() { echo "session-start: $*" >&2; }
reachable() { curl -s -o /dev/null --max-time 5 "$1"; }
pip_install() {
  python3 -m pip install -q --no-cache-dir "$@" >&2 \
    || python3 -m pip install -q --no-cache-dir --break-system-packages "$@" >&2
}

EDGE_OK=0; reachable https://speech.platform.bing.com/ && EDGE_OK=1
HF_OK=0; reachable https://huggingface.co/ && HF_OK=1

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

if ! python3 -c 'import numpy, PIL, scipy, soundfile, edge_tts, kokoro_onnx' >/dev/null 2>&1; then
  pip_install numpy pillow scipy soundfile 'edge-tts>=7.2.0' kokoro-onnx
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

# torch 版 kokoro：misaki G2P，支持 tts_build.py 的 PRONOUNCE 读音覆写。torch 优先装 CPU 版
# （download.pytorch.org）；该主机不可达时退回 PyPI 版，后者带 CUDA 依赖：实测下载 ≈3GB、装完 ≈5.3GB、约 3 分钟，
# 之后随容器快照缓存。
# 预热一次合成，把 kokoro 权重、am_liam 声音与 spaCy 英文模型拉进缓存。失败只告警，不阻断会话。
if [ "$HF_OK" = 1 ] && ! python3 -c 'import kokoro' >/dev/null 2>&1; then
  { python3 -c 'import torch' >/dev/null 2>&1 \
      || { reachable https://download.pytorch.org/whl/cpu/ && pip_install torch --index-url https://download.pytorch.org/whl/cpu; } \
      || pip_install torch; } \
    && pip_install kokoro \
    && python3 -c "from kokoro import KPipeline; list(KPipeline(lang_code='a')('Hello.', voice='am_liam'))" >&2 \
    || warn "torch kokoro install or warm-up failed; English falls back to TTS_ENGINE=kokoro_onnx"
fi
KOKORO_OK=0; [ "$HF_OK" = 1 ] && python3 -c 'import kokoro' >/dev/null 2>&1 && KOKORO_OK=1

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

# TTS_ENGINE=auto 的默认是 中文→edge、英文→kokoro；哪条走不通就在摘要里给出替代
msg="anything2explainer: skill linked, deps ready"
[ -n "$BROWSER" ] && msg+=", REMOTION_BROWSER_EXECUTABLE set"
overrides=()
[ "$EDGE_OK" = 1 ] \
  || overrides+=("zh: speech.platform.bing.com blocked, edge-tts unusable → TTS_ENGINE=kokoro_onnx KOKORO_ONNX_VOICE=zm_yunxi KOKORO_ONNX_LANG=cmn")
[ "$KOKORO_OK" = 1 ] \
  || overrides+=("en: torch kokoro unavailable$([ "$HF_OK" = 1 ] || echo ' (huggingface.co blocked)') → TTS_ENGINE=kokoro_onnx (am_liam preset)")
if [ ${#overrides[@]} -gt 0 ]; then
  joined=$(printf '%s; ' "${overrides[@]}")
  msg+=". TTS overrides: ${joined%; }"
else
  msg+=". TTS_ENGINE=auto works for zh and en"
fi
echo "$msg"
