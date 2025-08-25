#!/usr/bin/env bash
set -euo pipefail

MODELS_DIR="$HOME/Library/Application Support/IntPerInt/Models"
LLAMA_REPO="/tmp/llama.cpp"
BUILD_DIR="$LLAMA_REPO/build"

mkdir -p "$MODELS_DIR"

# timeout wrapper: prefer gtimeout, fallback to python
run_with_timeout() {
  local seconds="$1"; shift
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "${seconds}s" "$@"
  else
    python3 - <<'PY' "$seconds" "$@"
import subprocess, sys, shlex
secs = int(sys.argv[1])
cmd = sys.argv[2:]
try:
    p = subprocess.Popen(cmd)
    p.wait(timeout=secs)
    sys.exit(p.returncode)
except subprocess.TimeoutExpired:
    p.kill()
    try:
        p.wait(timeout=2)
    except Exception:
        pass
    # emulate timeout exit code 124
    sys.exit(124)
PY
  fi
}

MODEL_URL=${1:-}
if [ -z "${MODEL_URL}" ]; then
  read -p "ダウンロードする .gguf の URL を入力してください（Enter で中断）: " MODEL_URL
  if [ -z "$MODEL_URL" ]; then
    echo "中断：モデル URL が指定されていません。"
    exit 0
  fi
fi

if [[ "$MODEL_URL" =~ ^file:// ]]; then
  SRC_PATH="${MODEL_URL#file://}"
elif [[ "$MODEL_URL" =~ ^/ ]]; then
  SRC_PATH="$MODEL_URL"
else
  SRC_PATH=""
fi

if [ -n "$SRC_PATH" ]; then
  echo "[STEP] ローカルファイルをコピー: $SRC_PATH"
  FNAME=$(basename "$SRC_PATH")
  DEST="$MODELS_DIR/$FNAME"
  if [ "$SRC_PATH" = "$DEST" ]; then
    echo "[INFO] ソースと宛先が同一のためコピーをスキップ: $DEST"
  else
    cp -f "$SRC_PATH" "$DEST"
  fi
else
  FNAME=$(basename "$MODEL_URL")
  DEST="$MODELS_DIR/$FNAME"

  if [ -f "$DEST" ]; then
    echo "[INFO] 既に存在: $DEST"
  else
    echo "[STEP] ダウンロード中..."
    curl -L --fail --progress-bar -o "$DEST" "$MODEL_URL"
    echo "[OK] ダウンロード完了: $DEST"
  fi
fi

echo "[STEP] モデルサイズ:"
ls -lh "$DEST" || true
echo

if [ ! -d "$LLAMA_REPO" ]; then
  echo "[STEP] クローン: llama.cpp -> /tmp/llama.cpp"
  rm -rf "$LLAMA_REPO"
  git clone https://github.com/ggerganov/llama.cpp "$LLAMA_REPO"
else
  echo "[INFO] /tmp/llama.cpp exists, skipping clone"
fi

echo "[STEP] cmake build..."
cd "$LLAMA_REPO"
cmake -B "$BUILD_DIR" -S .
cmake --build "$BUILD_DIR" -j "$(sysctl -n hw.logicalcpu 2>/dev/null || echo 2)"
echo "[OK] ビルド完了. Build dir: $BUILD_DIR"
ls -lah "$BUILD_DIR" | sed -n '1,200p' || true
echo

# detect executable (follow same priority)
EXEC=""
if [ -n "${LLAMACPP_CLI:-}" ] && [ -x "$LLAMACPP_CLI" ]; then EXEC="$LLAMACPP_CLI"; fi
# App Support bin (app-managed)
AS_BIN="$HOME/Library/Application Support/IntPerInt/bin"
if [ -z "$EXEC" ] && [ -x "$AS_BIN/llama-cli" ]; then EXEC="$AS_BIN/llama-cli"; fi
if [ -z "$EXEC" ] && [ -x "$AS_BIN/llama" ]; then EXEC="$AS_BIN/llama"; fi
if [ -z "$EXEC" ] && [ -x "/opt/homebrew/opt/llama.cpp/bin/llama-cli" ]; then EXEC="/opt/homebrew/opt/llama.cpp/bin/llama-cli"; fi
if [ -z "$EXEC" ] && [ -x "/opt/homebrew/opt/llama.cpp/bin/llama" ]; then EXEC="/opt/homebrew/opt/llama.cpp/bin/llama"; fi
if [ -z "$EXEC" ] && [ -x "/opt/homebrew/bin/llama-cli" ]; then EXEC="/opt/homebrew/bin/llama-cli"; fi
if [ -z "$EXEC" ] && [ -x "/usr/local/bin/llama-cli" ]; then EXEC="/usr/local/bin/llama-cli"; fi
if [ -z "$EXEC" ] && [ -x "/opt/homebrew/bin/llama" ]; then EXEC="/opt/homebrew/bin/llama"; fi
if [ -z "$EXEC" ] && [ -x "/usr/local/bin/llama" ]; then EXEC="/usr/local/bin/llama"; fi
if [ -z "$EXEC" ] && [ -x "$BUILD_DIR/bin/llama-cli" ]; then EXEC="$BUILD_DIR/bin/llama-cli"; fi
if [ -z "$EXEC" ] && [ -x "$BUILD_DIR/bin/llama" ]; then EXEC="$BUILD_DIR/bin/llama"; fi
if [ -z "$EXEC" ] && [ -x "$BUILD_DIR/main" ]; then EXEC="$BUILD_DIR/main"; fi
if [ -z "$EXEC" ]; then
  WHICH=$(command -v llama-cli || command -v llama || true)
  if [ -n "$WHICH" ] && [ -x "$WHICH" ]; then EXEC="$WHICH"; fi
fi
if [ -z "$EXEC" ] || [ ! -x "$EXEC" ]; then
  echo "[WARN] 実行ファイルが検出できません。候補:"
  printf '  %s\n' \
    "$LLAMACPP_CLI" \
  "$AS_BIN/llama-cli" \
  "$AS_BIN/llama" \
    "/opt/homebrew/opt/llama.cpp/bin/llama-cli" \
    "/opt/homebrew/opt/llama.cpp/bin/llama" \
    "/opt/homebrew/bin/llama-cli" \
    "/usr/local/bin/llama-cli" \
    "/opt/homebrew/bin/llama" \
    "/usr/local/bin/llama" \
    "$BUILD_DIR/bin/llama-cli" \
    "$BUILD_DIR/bin/llama" \
    "$BUILD_DIR/main"
  exit 2
fi

echo "[INFO] 使用実行バイナリ: $EXEC"

# try patterns
CMD_OK=0
set +e
for args in "-m \"$DEST\" -p \"Hello\" -n 8" \
            "-m \"$DEST\" --prompt \"Hello\" --n_predict 8" \
            "-m \"$DEST\" --prompt \"Hello\" -n 8" \
            "-m \"$DEST\" --prompt \"Hello\" --max-tokens 8" \
            "-m \"$DEST\" -t 1 -n 8"; do
  echo "[TRY] $EXEC $args"
  eval run_with_timeout 10 "$EXEC" $args 2>&1 | sed -n '1,120p'
  rc=$?
  if [ $rc -eq 0 ] || [ $rc -eq 124 ]; then
    CMD_OK=1
    echo "[INFO] コマンド実行OK (rc=$rc): $EXEC $args"
    SUCCESS_ARGS="$args"
    break
  else
    echo "[INFO] 試行失敗 (rc=$rc)"
  fi
done
set -e

if [ $CMD_OK -ne 1 ]; then
  echo "[ERROR] 実行パターンが見つかりませんでした."
  exit 3
fi

echo "[STEP] 成功パターンで30秒間ストリーミング読み取りを試します..."
# run with sample args and capture 30s
eval run_with_timeout 30 "$EXEC" $SUCCESS_ARGS 2>&1 | sed -n '1,200p'

echo "[DONE] 出力サンプル完了."
echo "Models dir:"
ls -lh "$MODELS_DIR"

echo
echo "使い方:"
echo "  非対話: ./intperint_run_test.sh <model-url-or-local-path>"
echo "  例: ./intperint_run_test.sh https://huggingface.co/.../model.gguf"
echo "      ./intperint_run_test.sh /path/to/model.gguf"
