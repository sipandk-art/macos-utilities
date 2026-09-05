#!/usr/bin/env bash
#
# build-app.sh — собирает «MacOS Utilities.app» и DMG для распространения.
#
#   ./scripts/build-app.sh          собрать .app в build/
#   ./scripts/build-app.sh --dmg    собрать .app и упаковать в dist/
#
# ПОДПИСЬ. По умолчанию — ad-hoc (`codesign -s -`): работает на своей машине,
# но у скачавшего вызовет предупреждение Gatekeeper. Чтобы подписать по-настоящему,
# задайте переменные окружения:
#
#   SIGN_ID="Developer ID Application: ИМЯ (TEAMID)"   сертификат для раздачи вне App Store
#   NOTARY_PROFILE="имя-профиля"                       профиль notarytool для нотаризации
#
# Пример:
#
#   SIGN_ID="Developer ID Application: SIPAN PETROSIAN (ABCDE12345)" \
#   NOTARY_PROFILE=notary \
#   ./scripts/build-app.sh --dmg
#
# Как эти два значения получить — см. раздел «Подпись и нотаризация» в README.

set -euo pipefail

cd "$(dirname "$0")/.."

PRODUCT="MacOSUtilities"          # имя цели в Package.swift и исполняемого файла
APP_NAME="MacOS Utilities"        # имя бандла и то, что видит пользователь
FILE_STEM="MacOS-Utilities"       # имя файла DMG (без пробелов, чтобы ссылки не ломались)
BUNDLE_ID="com.sipandk.macosutilities"
VERSION="${VERSION:-1.3.2}"
BUILD="$PWD/build"
APP="$BUILD/$APP_NAME.app"
DIST="$PWD/dist"

SIGN_ID="${SIGN_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

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

cp ".build/apple/Products/Release/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT"
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
    <key>CFBundleExecutable</key>            <string>$PRODUCT</string>
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

if [ -n "$SIGN_ID" ]; then
  echo "==> Подпись: $SIGN_ID"
  # --options runtime включает hardened runtime — без него Apple не примет
  # приложение на нотаризацию. Приложение не в песочнице: hidutil, launchctl
  # и defaults из песочницы не работают.
  codesign --force --deep --timestamp --options runtime \
           --sign "$SIGN_ID" "$APP"
else
  echo "==> Подпись: ad-hoc (для раздачи задайте SIGN_ID, см. README)"
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

# Нотаризация самого бандла, а не только DMG. Штамп внутри .app нужен для
# случая, когда приложение уже перенесли в /Applications, а интернета нет:
# без штампа Gatekeeper пойдёт спрашивать вердикт у Apple и не сможет.
if [ -n "$SIGN_ID" ] && [ -n "$NOTARY_PROFILE" ]; then
  echo "==> Нотаризация приложения (несколько минут)"
  ZIP="$BUILD/$PRODUCT-notarize.zip"
  rm -f "$ZIP"
  # ditto сохраняет структуру бандла и подпись; обычный zip их портит.
  /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
fi

echo "==> Готово: $APP"

if [ "${1:-}" = "--dmg" ]; then
  echo "==> Упаковка DMG"
  mkdir -p "$DIST"
  DMG="$DIST/$FILE_STEM-$VERSION.dmg"
  STAGE="$BUILD/dmg"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  # Ярлык на /Applications, чтобы приложение переносили мышью прямо из окна DMG.
  ln -s /Applications "$STAGE/Applications"
  cp README.md "$STAGE/ПРОЧТИ МЕНЯ.md"

  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"

  if [ -n "$SIGN_ID" ]; then
    codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
  fi

  if [ -n "$NOTARY_PROFILE" ]; then
    echo "==> Нотаризация (несколько минут)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    # Штамп кладётся в сам DMG: после него Gatekeeper пропускает приложение
    # даже без интернета у того, кто его открывает.
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
  fi

  echo "==> Готово: $DMG ($(du -h "$DMG" | cut -f1))"
fi
