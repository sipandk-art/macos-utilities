#!/usr/bin/env bash
#
# run-e2e.sh — прогон всех сквозных стендов на тестовом профиле.
#
#   ./scripts/run-e2e.sh
#
# Приложение запускается с --test-profile: у него отдельное хранилище настроек
# (com.sipandk.macosutilities.test) и отдельная папка для файлов. Настройки
# и история буфера установленной копии не трогаются.
#
# Запускать из терминала, у которого есть «Универсальный доступ»: приложение,
# запущенное отсюда, получает разрешения терминала, иначе перехват клавиатуры
# и вставка не заработают.

set -u
cd "$(dirname "$0")/.."

APP="build/MacOS Utilities.app/Contents/MacOS/MacOSUtilities"
SUITE="com.sipandk.macosutilities.test"
TEST_FOLDER="$HOME/Library/Application Support/MacOS Utilities (test)"
PATTERN="MacOSUtilities --test-profile"      # гасим только тестовый экземпляр

# Рабочая копия и тестовая одновременно — это два перехватчика клавиатуры
# (слово правилось бы дважды) и спор за сочетание ⌃⌘V. Не мешаем человеку.
if pgrep -f "/Applications/MacOS Utilities.app/Contents/MacOS/MacOSUtilities" >/dev/null; then
  echo "Запущена установленная копия MacOS Utilities — закройте её (Выйти в меню значка) и повторите."
  exit 2
fi

[ -x "$APP" ] || ./scripts/build-app.sh

DOC="$(mktemp -d)/e2e.txt"
touch "$DOC"

stop_app() { pkill -f "$PATTERN" 2>/dev/null; sleep 1; }

start_app() {        # start_app <ключ=значение>...
  stop_app
  defaults delete "$SUITE" 2>/dev/null
  defaults write "$SUITE" showWindowAtLaunch -bool false
  for pair in "$@"; do
    defaults write "$SUITE" "${pair%%=*}" -bool "${pair#*=}"
  done
  nohup "$APP" --test-profile >/dev/null 2>&1 &
  sleep 5
}

cleanup() {
  stop_app
  defaults delete "$SUITE" 2>/dev/null
  rm -rf "$TEST_FOLDER"
  osascript -e 'tell application "TextEdit" to close every document saving no' >/dev/null 2>&1
  rm -f "$DOC"
}
trap cleanup EXIT

open -a TextEdit "$DOC"
sleep 4

status=0
echo "########## автопереключение: правка на пробеле ##########"
start_app autoSwitchEnabled=true autoSwitchAuto=true
swift scripts/e2e-autoswitch.swift auto || status=1

echo; echo "########## автопереключение: горячее сочетание ##########"
start_app autoSwitchEnabled=true autoSwitchAuto=false
swift scripts/e2e-autoswitch.swift manual || status=1

echo; echo "########## история буфера обмена ##########"
start_app clipboardEnabled=true
swift scripts/e2e-clipboard.swift || status=1

echo
[ "$status" -eq 0 ] && echo "=== ВСЕ СТЕНДЫ ЗЕЛЁНЫЕ ===" || echo "=== ЕСТЬ ПРОВАЛЫ ==="
exit "$status"
