#!/usr/bin/env bash
set -euo pipefail

# 构建 + 打包成 .app
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="CodexQuota"
BUNDLE_ID="com.local.codexquota"
APP_DIR="$ROOT/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

# 版本号只读，不递增。本地构建额外加 -dev 后缀，避免和发布版混淆。
VERSION_FILE="$ROOT/VERSION"
RELEASE_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || echo 0.0.0)"
SHORT_VERSION="${RELEASE_VERSION}-dev"
BUILD_VERSION="$(date +%Y%m%d%H%M)"
RELAUNCH_AFTER_BUILD=0

if [ "${1-}" = "--relaunch" ]; then
  RELAUNCH_AFTER_BUILD=1
fi

quit_running_app() {
  if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    return
  fi

  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  for _ in {1..30}; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      return
    fi
    sleep 0.1
  done

  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  for _ in {1..30}; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      return
    fi
    sleep 0.1
  done
}

echo "==> swift build -c release"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
[ -f "$BIN" ] || { echo "未找到二进制 $BIN"; exit 1; }

echo "==> 组装 $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RES"
cp "$BIN" "$MACOS/$APP_NAME"

# 生成/拷贝图标
ICON_SRC="$ROOT/assets/AppIcon.icns"
if [ ! -f "$ICON_SRC" ] || [ "$ROOT/scripts/make_icon.swift" -nt "$ICON_SRC" ]; then
  echo "==> 生成图标"
  rm -rf "$ROOT/assets/AppIcon.iconset"
  swift "$ROOT/scripts/make_icon.swift" "$ROOT/assets" >/dev/null
  iconutil -c icns "$ROOT/assets/AppIcon.iconset" -o "$ICON_SRC"
fi
cp "$ICON_SRC" "$RES/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>Codex 额度</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 给二进制做 ad-hoc 签名（Apple Silicon 必需）
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "==> 完成: $APP_DIR"
if [ "$RELAUNCH_AFTER_BUILD" -eq 1 ]; then
  echo "==> 重启运行中的 $APP_NAME"
  quit_running_app
  open -n "$APP_DIR"
  echo "已启动: $APP_DIR"
else
  echo "运行: open $APP_DIR"
  echo "或:   ./bundle.sh --relaunch"
fi
