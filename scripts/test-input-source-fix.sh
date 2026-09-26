#!/bin/bash
#
# test-input-source-fix.sh — проверка скрипта Caps Lock, не меняющая систему.
#
#   /bin/bash scripts/test-input-source-fix.sh
#
# Скрипт подключается через source во временную «домашнюю папку», а defaults
# и hidutil подменяются заготовками — настройки пользователя не трогаются.
# В конце одна живая проверка `check`: она только читает состояние системы.

set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/Resources/Scripts/input-source-fix.sh"
REAL_HOME=$HOME
TMPHOME=$(mktemp -d) || exit 1
FAKEBIN=$(mktemp -d) || exit 1
trap 'rm -rf "$TMPHOME" "$FAKEBIN"' EXIT

failures=0
check() {
  if [ "$2" = "$3" ]; then echo "  PASS $1"
  else echo "  FAIL $1: получили «$2», ждали «$3»"; failures=$((failures + 1)); fi
}

echo "== зависимости"
# Без инструментов разработчика /usr/bin/python3 — заглушка, которая
# открывает окно «установите Command Line Tools». Скрипт не должен её звать.
check "нет вызовов python" "$(grep -v '^[[:space:]]*#' "$SCRIPT" | grep -cwE 'python3?')" 0

# ── заготовки вместо системы ─────────────────────────────────────────────────

export HOME="$TMPHOME"
mkdir -p "$HOME/Library/Preferences" "$HOME/Library/LaunchAgents"

# Словарь переназначения клавиш в том виде, как его печатает `defaults read`
# (число -1 система берёт в кавычки).
mapping_text() {
  printf '(\n'
  for dict in "$@"; do
    printf '        {\n'
    printf '%s\n' "$dict" | tr '|' '\n' | sed 's/^/        /; s/$/;/'
    printf '    },\n'
  done
  printf ')\n'
}
CAPS_TO_NONE='HIDKeyboardModifierMappingDst = "-1"|HIDKeyboardModifierMappingSrc = 30064771129'
CAPS_NO_DST='HIDKeyboardModifierMappingSrc = 30064771129'
CAPS_TO_CTRL='HIDKeyboardModifierMappingDst = 30064771300|HIDKeyboardModifierMappingSrc = 30064771129'
CAPS_TO_ESC='HIDKeyboardModifierMappingDst = 30064771113|HIDKeyboardModifierMappingSrc = 30064771129'
OPT_TO_NONE='HIDKeyboardModifierMappingDst = "-1"|HIDKeyboardModifierMappingSrc = 30064771298'

defaults() {
  case "$*" in
    "export com.apple.HIToolbox -") cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AppleEnabledInputSources</key>
	<array>
		<dict>
			<key>InputSourceKind</key><string>Keyboard Layout</string>
			<key>KeyboardLayout ID</key><integer>252</integer>
			<key>KeyboardLayout Name</key><string>ABC</string>
		</dict>
		<dict>
			<key>InputSourceKind</key><string>Keyboard Layout</string>
			<key>KeyboardLayout ID</key><integer>19458</integer>
			<key>KeyboardLayout Name</key><string>RussianWin</string>
		</dict>
		<dict>
			<key>Bundle ID</key><string>com.apple.inputmethod.SCIM</string>
			<key>InputSourceKind</key><string>Input Mode</string>
		</dict>
	</array>
</dict>
</plist>
EOF
      ;;
    "-currentHost read -g")
      printf '{\n    AppleFontSmoothing = 0;\n'
      for k in 0-0-0 1452-834-0 1133-49948-0 5-5-0; do
        printf '    "com.apple.keyboard.modifiermapping.%s" =     ' "$k"
        defaults -currentHost read -g "com.apple.keyboard.modifiermapping.$k"
      done
      printf '}\n' ;;
    *modifiermapping.0-0-0)       mapping_text "$CAPS_TO_CTRL" ;;
    *modifiermapping.1452-834-0)  mapping_text "$CAPS_TO_NONE" ;;
    *modifiermapping.1133-49948-0) mapping_text "$CAPS_NO_DST" ;;
    *modifiermapping.5-5-0)       mapping_text "$CAPS_TO_ESC" "$OPT_TO_NONE" ;;
    *) return 1 ;;
  esac
}

hidutil() {
  printf '(\n        {\n        HIDKeyboardModifierMappingDst = 30064771181;\n        HIDKeyboardModifierMappingSrc = 30064771129;\n    }\n)\n'
}

cat > "$HOME/Library/Preferences/com.apple.symbolichotkeys.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AppleSymbolicHotKeys</key>
	<dict>
		<key>60</key>
		<dict>
			<key>enabled</key><true/>
			<key>value</key>
			<dict>
				<key>parameters</key>
				<array><integer>32</integer><integer>49</integer><integer>262144</integer></array>
				<key>type</key><string>standard</string>
			</dict>
		</dict>
	</dict>
</dict>
</plist>
EOF

# shellcheck source=../Resources/Scripts/input-source-fix.sh
source "$SCRIPT"
printf '<?xml version="1.0"?>\n<!-- «кавычки" & \\ ё -->\n<plist version="1.0"><dict/></plist>\n' > "$PLIST"

echo "== число раскладок"
check "две раскладки, метод ввода не в счёт" "$(layout_count)" 2

echo "== Caps Lock в «Нет действия»"
check "найдены обе такие клавиатуры" "$(capslock_noaction_keys | tr '\n' ' ')" \
  "com.apple.keyboard.modifiermapping.1133-49948-0 com.apple.keyboard.modifiermapping.1452-834-0 "

echo "== копия прежних настроек сохраняет всё как было"
save_backup >/dev/null
check "копия — JSON" "$(head -c 1 "$BACKUP")" "{"
check "ремап" "$(backup_get user_key_mapping)" "$(hidutil)"
check "шорткат" "$(backup_get hotkey_xml)" \
  "$(/usr/libexec/PlistBuddy -x -c 'Print :AppleSymbolicHotKeys:60' "$HOME/Library/Preferences/com.apple.symbolichotkeys.plist")"
check "автозагрузка была" "$(backup_get launchagent_existed)" true
check "файл автозагрузки байт в байт" "$(backup_get launchagent_body)" "$(cat "$PLIST")"

echo "== копия, когда шортката и автозагрузки не было"
rm -f "$BACKUP" "$PLIST" "$HOME/Library/Preferences/com.apple.symbolichotkeys.plist"
save_backup >/dev/null
check "шортката нет" "$(backup_get hotkey_xml)" ""
check "автозагрузки не было" "$(backup_get launchagent_existed)" false
check "файла нет" "$(backup_get launchagent_body)" ""

echo "== копию не записать — ничего не меняется"
out=$(BACKUP_DIR=/nonexistent; BACKUP=/nonexistent/b.json; save_backup 2>&1)
check "отказ до любых изменений" "$(printf '%s\n' "$out" | grep -c '@@RESULT=fail')" 1

echo "== копия прежних версий (JSON с null) читается"
cat > "$BACKUP" <<'EOF'
{
  "user_key_mapping": "(\n)",
  "hotkey_xml": null,
  "launchagent_existed": true,
  "launchagent_body": "<?xml version=\"1.0\"?>\n<plist/>\n"
}
EOF
check "null — пусто" "$(backup_get hotkey_xml)" ""
check "флаг" "$(backup_get launchagent_existed)" true
check "многострочный текст" "$(backup_get launchagent_body)" $'<?xml version="1.0"?>\n<plist/>'
check "пустой ремап" "$(backup_get user_key_mapping)" $'(\n)'

echo "== живая проверка системы (только чтение)"
printf '#!/bin/sh\ntouch "%s/called"\nexit 1\n' "$FAKEBIN" > "$FAKEBIN/python3"
chmod +x "$FAKEBIN/python3"
out=$(HOME="$REAL_HOME" PATH="$FAKEBIN:$PATH" /bin/bash "$SCRIPT" check)
check "check отработал" "$(printf '%s\n' "$out" | grep -c '^@@RESULT=ok$')" 1
check "языков — число" "$(printf '%s\n' "$out" | grep -cE '^@@LAYOUTS=[0-9]+$')" 1
check "python не вызывался" "$([ -e "$FAKEBIN/called" ] && echo да || echo нет)" нет

echo
[ "$failures" -eq 0 ] && echo "ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ" || echo "ПРОВАЛЕНО: $failures"
exit $((failures > 0))
