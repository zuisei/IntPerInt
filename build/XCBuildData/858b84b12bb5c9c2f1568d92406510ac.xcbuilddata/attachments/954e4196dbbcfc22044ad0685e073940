#!/bin/bash
set -euo pipefail
RUNTIME_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/runtime"
BIN_DIR="$RUNTIME_DIR/bin"
SHARE_DIR="$RUNTIME_DIR/share/llama.cpp"
LIB_DIR="$RUNTIME_DIR/lib"
STAMP="${SCRIPT_OUTPUT_FILE_0:-$RUNTIME_DIR/.bundled-llama.stamp}"
mkdir -p "$BIN_DIR" "$SHARE_DIR" "$LIB_DIR"
# pick executable
EXEC_SRC=""
for p in \
  /opt/homebrew/opt/llama.cpp/bin/llama-cli \
  /opt/homebrew/opt/llama.cpp/bin/llama \
  /usr/local/opt/llama.cpp/bin/llama-cli \
  /usr/local/opt/llama.cpp/bin/llama; do
  if [ -x "$p" ]; then EXEC_SRC="$p"; break; fi
done
if [ -z "$EXEC_SRC" ]; then WH="$(/usr/bin/which llama-cli 2>/dev/null || true)"; [ -n "$WH" ] && EXEC_SRC="$WH"; fi
if [ -z "$EXEC_SRC" ]; then WH="$(/usr/bin/which llama 2>/dev/null || true)"; [ -n "$WH" ] && EXEC_SRC="$WH"; fi
if [ -n "$EXEC_SRC" ]; then
  BASENAME="$(basename "$EXEC_SRC")"
  # dereference symlinks when copying into app bundle
  rsync -aL "$EXEC_SRC" "$BIN_DIR/$BASENAME" || true
  chmod 755 "$BIN_DIR/$BASENAME" || true
fi
# metallib: try exec-local and common locations
CANDS=()
if [ -n "$EXEC_SRC" ]; then
  EXECDIR="$(dirname "$EXEC_SRC")"
  PREFIX="$(dirname "$EXECDIR")"
  CANDS+=("$EXECDIR/default.metallib")
  CANDS+=("$PREFIX/share/llama.cpp/default.metallib")
fi
CANDS+=("/opt/homebrew/opt/llama.cpp/share/llama.cpp/default.metallib")
CANDS+=("/usr/local/opt/llama.cpp/share/llama.cpp/default.metallib")
for m in /opt/homebrew/Cellar/llama.cpp/*/share/llama.cpp/default.metallib /usr/local/Cellar/llama.cpp/*/share/llama.cpp/default.metallib; do
  [ -e "$m" ] && CANDS+=("$m") || true
done
for m in "${CANDS[@]}"; do
  if [ -f "$m" ]; then rsync -aL "$m" "$SHARE_DIR/default.metallib" || true; break; fi
done
# copy libllama.dylib if present to runtime/lib
for L in \
  /opt/homebrew/opt/llama.cpp/lib/libllama.dylib \
  /usr/local/opt/llama.cpp/lib/libllama.dylib; do
  if [ -f "$L" ]; then rsync -aL "$L" "$LIB_DIR/libllama.dylib" || true; chmod 755 "$LIB_DIR/libllama.dylib" || true; break; fi
done
# copy libggml*.dylib into runtime/lib
GGML_DIRS=()
if [ -n "$EXEC_SRC" ]; then
  EXECDIR="$(dirname "$EXEC_SRC")"
  PREFIX="$(dirname "$EXECDIR")"
  GGML_DIRS+=("$PREFIX/lib")
fi
GGML_DIRS+=("/opt/homebrew/opt/llama.cpp/lib")
GGML_DIRS+=("/usr/local/opt/llama.cpp/lib")
for d in "${GGML_DIRS[@]}"; do
  if [ -d "$d" ]; then
    for f in "$d"/libggml*.dylib; do
      [ -f "$f" ] || continue
      base="$(basename "$f")"
      rsync -aL "$f" "$LIB_DIR/$base" || true
      chmod 755 "$LIB_DIR/$base" || true
    done
  fi
done

# fix rpath so bundled exec can find libs without DYLD_LIBRARY_PATH
for exe in "$BIN_DIR/llama-cli" "$BIN_DIR/llama"; do
  if [ -x "$exe" ]; then
    /usr/bin/install_name_tool -add_rpath "@executable_path/../lib" "$exe" 2>/dev/null || true
  fi
done

# codesign bundled binaries to prevent sandbox kill
if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "$EXPANDED_CODE_SIGN_IDENTITY" != "-" ]; then
  for exe in "$BIN_DIR/llama-cli" "$BIN_DIR/llama"; do
    if [ -x "$exe" ]; then
      /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp=none "$exe" 2>/dev/null || true
    fi
  done
  for dylib in "$LIB_DIR"/*.dylib; do
    [ -f "$dylib" ] || continue
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp=none "$dylib" 2>/dev/null || true
  done
fi

# stamp
mkdir -p "$(dirname "$STAMP")"
: > "$STAMP"
exit 0

