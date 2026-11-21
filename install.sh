#!/bin/bash
# AI Session Viewer をビルドし、macOS の Applications フォルダへインストールするスクリプト
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="AISessionViewer"
BUNDLE_NAME="${APP_NAME}.app"
BUILT_APP="${SCRIPT_DIR}/mac/native/${BUNDLE_NAME}"

DEST_DIR="/Applications"
OPEN_AFTER=false
UNINSTALL=false
SKIP_BUILD=false
CUSTOM_DEST=false

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --user          ~/Applications にインストールする (デフォルトは /Applications)
  --dest <dir>    任意のディレクトリにインストールする
  --no-build      ビルドをスキップして既存の .app をコピーする
  --open          インストール後にアプリを起動する
  --uninstall     インストール済みの AISessionViewer.app を削除する
  -h, --help      このヘルプを表示する
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      DEST_DIR="${HOME}/Applications"
      CUSTOM_DEST=true
      shift
      ;;
    --dest)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "Error: --dest にはディレクトリを指定してください" >&2
        exit 1
      fi
      DEST_DIR="$2"
      CUSTOM_DEST=true
      shift 2
      ;;
    --no-build)
      SKIP_BUILD=true
      shift
      ;;
    --open)
      OPEN_AFTER=true
      shift
      ;;
    --uninstall)
      UNINSTALL=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: 不明なオプション: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$UNINSTALL" == "true" ]]; then
  removed=false
  if [[ "$CUSTOM_DEST" == "true" ]]; then
    targets=("${DEST_DIR}/${BUNDLE_NAME}")
  else
    targets=("/Applications/${BUNDLE_NAME}" "${HOME}/Applications/${BUNDLE_NAME}")
  fi
  for target in "${targets[@]}"; do
    if [[ -d "$target" ]]; then
      rm -rf "$target"
      echo "🗑️  削除しました: $target"
      removed=true
    fi
  done
  if [[ "$removed" == "false" ]]; then
    echo "インストール済みの ${BUNDLE_NAME} は見つかりませんでした。"
  fi
  echo "ℹ️  お気に入りデータ (~/Library/Application Support/ai-session-viewer/) は保持されます。"
  exit 0
fi

# 1. ビルド
if [[ "$SKIP_BUILD" == "false" ]]; then
  if ! command -v swiftc >/dev/null 2>&1; then
    echo "Error: swiftc が見つかりません。Xcode Command Line Tools をインストールしてください:" >&2
    echo "  xcode-select --install" >&2
    exit 1
  fi
  echo "🔨 ${BUNDLE_NAME} をビルドしています..."
  "${SCRIPT_DIR}/mac/native/build.sh"
fi

if [[ ! -d "$BUILT_APP" ]]; then
  echo "Error: ビルド成果物が見つかりません: $BUILT_APP" >&2
  exit 1
fi

# 2. インストール先の決定 (/Applications に書き込めない場合は ~/Applications へフォールバック)
if [[ "$CUSTOM_DEST" == "false" && ! -w "$DEST_DIR" ]]; then
  echo "ℹ️  ${DEST_DIR} への書き込み権限がないため、${HOME}/Applications にインストールします。"
  DEST_DIR="${HOME}/Applications"
fi

mkdir -p "$DEST_DIR"
TARGET_APP="${DEST_DIR}/${BUNDLE_NAME}"

# 同じインストール先から起動中の古いプロセスがあれば完全パス一致で終了して差し替える
TARGET_BIN="${TARGET_APP}/Contents/MacOS/${APP_NAME}"
MATCH_PIDS="$(ps -axo pid=,command= | awk -v target="$TARGET_BIN" '{pid=$1; $1=""; sub(/^[ \t]+/, ""); if ($0 == target) print pid}')"
if [[ -n "$MATCH_PIDS" ]]; then
  echo "ℹ️  起動中の ${APP_NAME} (${TARGET_APP}) を終了して更新します..."
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done <<< "$MATCH_PIDS"
  sleep 0.5
fi

# 3. コピー (既存バンドルを安全に差し替え)
TMP_APP="${DEST_DIR}/.${BUNDLE_NAME}.tmp.$$"
rm -rf "$TMP_APP"
cp -R "$BUILT_APP" "$TMP_APP"
rm -rf "$TARGET_APP"
mv "$TMP_APP" "$TARGET_APP"

echo "✅ インストール完了: ${TARGET_APP}"
echo "   起動コマンド: open \"${TARGET_APP}\""

if [[ "$OPEN_AFTER" == "true" ]]; then
  open "$TARGET_APP"
fi
