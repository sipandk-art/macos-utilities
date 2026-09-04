#!/usr/bin/env bash
#
# build-app.sh — собирает Toolbelt.app и DMG для распространения.
#
#   ./scripts/build-app.sh          собрать .app в build/
#   ./scripts/build-app.sh --dmg    собрать .app и упаковать в dist/Toolbelt-<версия>.dmg
#
# Приложение подписывается ad-hoc подписью (`codesign -s -`). Для личного
# использования и раздачи через GitHub этого достаточно; для магазина нужен
# сертификат разработчика и нотаризация.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Toolbelt"
BUNDLE_ID="com.sipandk.toolbelt"
VERSION="${VERSION:-1.0.0}"
BUILD="$PWD/build"
APP="$BUILD/$APP_NAME.app"
DIST="$PWD/dist"

echo "==> Сборка бинарника (release, universal)"
swift build -c release --arch arm64 --arch x86_64

echo "==> Иконка"
rm -rf "$BUILD/AppIcon.iconset"
mkdir -p "$BUILD"
swift scripts/make-icon.swift
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"

echo "==> Сборка бандла $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/apple/Products/Release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Скрипты кладутся плоско в Resources: приложение читает их оттуда и для
# запуска, и для показа исходника по кнопке «Показать весь скрипт».
cp Resources/Scripts/*.sh "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>           <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>            <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundleVersion</key>               <string>$VERSION</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>        <string>13.0</string>
    <key>NSHumanReadableCopyright</key>      <string>MIT License</string>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>       <true/>
</dict>
</plist>
EOF

plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Подпись (ad-hoc)"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> Готово: $APP"

if [ "${1:-}" = "--dmg" ]; then
  echo "==> Упаковка DMG"
  mkdir -p "$DIST"
  DMG="$DIST/$APP_NAME-$VERSION.dmg"
  STAGE="$BUILD/dmg"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  # Ярлык на /Applications, чтобы приложение переносили мышью прямо из окна DMG.
  ln -s /Applications "$STAGE/Applications"
  cp README.md "$STAGE/ПРОЧТИ МЕНЯ.md"

  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
  echo "==> Готово: $DMG ($(du -h "$DMG" | cut -f1))"
fi
