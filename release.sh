#!/usr/bin/env bash
# 构建 4 个分发包:
#   - CodexQuota-<v>-universal.dmg / .zip  （arm64 + x86_64）
#   - CodexQuota-<v>-arm64.dmg     / .zip  （Apple Silicon 专用，体积更小）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="CodexQuota"
BUNDLE_ID="com.local.codexquota"
VERSION_FILE="$ROOT/VERSION"

# 版本号每一位最大 9，从 PATCH 起进位（9.9.9 之后回到 0.0.0）
bump_version() {
  local v="$1"
  local IFS='.'
  read -r MA MI PA <<<"$v"
  MA=${MA:-0}; MI=${MI:-0}; PA=${PA:-0}
  PA=$((PA + 1))
  if [ "$PA" -gt 9 ]; then PA=0; MI=$((MI + 1)); fi
  if [ "$MI" -gt 9 ]; then MI=0; MA=$((MA + 1)); fi
  if [ "$MA" -gt 9 ]; then MA=0; fi
  echo "$MA.$MI.$PA"
}

# 用法:
#   ./release.sh           → 读 VERSION，递增后写回，作为本次版本
#   ./release.sh 1.2.3     → 直接用 1.2.3，并写回 VERSION
if [ ! -f "$VERSION_FILE" ]; then
  echo "0.0.0" > "$VERSION_FILE"
fi
CURRENT="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [ $# -ge 1 ] && [ -n "$1" ]; then
  VERSION="$1"
else
  VERSION="$(bump_version "$CURRENT")"
fi
echo "$VERSION" > "$VERSION_FILE"
echo "==> 版本: $CURRENT → $VERSION"

DIST="$ROOT/dist"
rm -rf "$DIST"
mkdir -p "$DIST"

# 准备图标（一次即可）
ICON_SRC="$ROOT/assets/AppIcon.icns"
if [ ! -f "$ICON_SRC" ] || [ "$ROOT/scripts/make_icon.swift" -nt "$ICON_SRC" ]; then
  echo "==> 生成图标"
  rm -rf "$ROOT/assets/AppIcon.iconset"
  swift "$ROOT/scripts/make_icon.swift" "$ROOT/assets" >/dev/null
  iconutil -c icns "$ROOT/assets/AppIcon.iconset" -o "$ICON_SRC"
fi

# 先把两个架构都构建一次（universal 需要两个，arm64 需要一个）
echo "==> 构建 arm64"
swift build -c release --triple arm64-apple-macosx13.0 >/dev/null
ARM_BIN="$(swift build -c release --triple arm64-apple-macosx13.0 --show-bin-path)/$APP_NAME"

echo "==> 构建 x86_64"
swift build -c release --triple x86_64-apple-macosx13.0 >/dev/null
X86_BIN="$(swift build -c release --triple x86_64-apple-macosx13.0 --show-bin-path)/$APP_NAME"

# 给定 binary 源文件 + 变体名，生成 .app + dmg + zip
make_bundle() {
  local variant="$1"      # universal | arm64
  local app_dir="$DIST/$APP_NAME-$variant.app"
  local contents="$app_dir/Contents"
  local macos="$contents/MacOS"
  local res="$contents/Resources"

  rm -rf "$app_dir"
  mkdir -p "$macos" "$res"

  if [ "$variant" = "universal" ]; then
    lipo -create -output "$macos/$APP_NAME" "$ARM_BIN" "$X86_BIN"
  else
    cp "$ARM_BIN" "$macos/$APP_NAME"
  fi
  cp "$ICON_SRC" "$res/AppIcon.icns"

  cat > "$contents/Info.plist" <<PLIST
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
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

  codesign --force --deep --sign - "$app_dir" >/dev/null 2>&1 || true

  # 给 .app 改成不带 variant 的标准名（让用户拖到 /Applications 后只叫 CodexQuota）
  local staged="$DIST/stage-$variant"
  rm -rf "$staged"; mkdir -p "$staged"
  cp -R "$app_dir" "$staged/$APP_NAME.app"

  # ZIP
  local zip_path="$DIST/$APP_NAME-$VERSION-$variant.zip"
  ditto -c -k --keepParent "$staged/$APP_NAME.app" "$zip_path"

  # DMG（带 /Applications 拖拽链接）
  local dmg_path="$DIST/$APP_NAME-$VERSION-$variant.dmg"
  ln -s /Applications "$staged/Applications"
  hdiutil create -volname "$APP_NAME-$variant" -srcfolder "$staged" \
    -ov -format UDZO -fs HFS+ "$dmg_path" >/dev/null

  rm -rf "$staged" "$app_dir"

  echo "    生成: $(basename "$zip_path") + $(basename "$dmg_path")"
}

echo "==> 打包 universal"
make_bundle universal

echo "==> 打包 arm64 (Apple Silicon)"
make_bundle arm64

echo
echo "==> 产物:"
( cd "$DIST" && ls -lh CodexQuota-*.dmg CodexQuota-*.zip 2>/dev/null \
    | awk '{printf "    %-40s %s\n", $NF, $5}' )

echo
echo "提示: ad-hoc 签名（未公证），首次运行被 Gatekeeper 拦截时:"
echo "      右键 .app → 打开，或 系统设置 → 隐私与安全性 → 仍要打开"
