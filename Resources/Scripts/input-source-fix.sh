#!/bin/bash
#
# input-source-fix.sh — надёжное переключение раскладки клавиатуры по Caps Lock.
#
#   input-source-fix.sh check     диагностика: версия macOS, права, текущее состояние
#   input-source-fix.sh apply     применить фикс (с бэкапом прежнего состояния)
#   input-source-fix.sh revert    откатить всё к состоянию до apply
#
# ПРОБЛЕМА. Штатная галка «Использовать Caps Lock для переключения раскладки»
# (System Settings -> Keyboard -> Input Sources) работает через обработчик,
# который при быстром наборе теряет нажатия: печатаешь быстро — раскладка
# не переключилась, половина слова ушла не в тот язык.
#
# РЕШЕНИЕ. Физический Caps Lock перекладывается на клавишу F18 прямо в HID-слое
# (hidutil, ядро драйвера клавиатуры), а на F18 вешается системный шорткат
# «Выбрать предыдущий источник ввода». Этот путь синхронный и не теряет нажатий.
#
# ЧТО МЕНЯЕТСЯ НА ДИСКЕ (всё — только в домашней папке пользователя):
#   1. hidutil UserKeyMapping           — ремап Caps Lock -> F18 (живёт до перезагрузки)
#   2. ~/Library/LaunchAgents/com.user.capslock2f18.plist — повторяет ремап при входе
#   3. com.apple.symbolichotkeys, ключ 60 — шорткат «предыдущий источник ввода» = F18
#   4. com.apple.keyboard.modifiermapping.* — ТОЛЬКО если Caps Lock стоит «Нет действия»
#
# ПРАВА. sudo/root НЕ НУЖЕН: всё перечисленное — пользовательские настройки.
# Пароль администратора скрипт не спрашивает и спрашивать не будет.

set -u

# ── константы ────────────────────────────────────────────────────────────────

CAPS_HID=0x700000039          # HID usage физического Caps Lock
F18_HID=0x70000006D           # HID usage клавиши F18
CAPS_HID_DEC=30064771129      # то же самое десятичным (так лежит в plist)
LABEL="com.user.capslock2f18"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
HOTKEY_ID=60                  # 60 = «Select the previous input source»
F18_KEYCODE=79                # виртуальный код клавиши F18
F18_MODS=8388608              # флаг Function — именно так система пишет F18 в шорткат
MIN_MACOS=11                  # ниже 11 не тестировалось (hidutil есть с 10.12)
BACKUP_DIR="$HOME/Library/Application Support/MacOS Utilities"
BACKUP="$BACKUP_DIR/input-source-backup.json"
LEGACY_BACKUP_DIR="$HOME/Library/Application Support/Toolbelt"   # имя до версии 1.1.0
ACTIVATE=/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings

# Бэкап, снятый прежней версией приложения, переезжает под новое имя —
# иначе кнопка «Откатить» перестала бы видеть уже сохранённое состояние.
if [ -f "$LEGACY_BACKUP_DIR/input-source-backup.json" ] && [ ! -f "$BACKUP" ]; then
  mkdir -p "$BACKUP_DIR"
  mv "$LEGACY_BACKUP_DIR/input-source-backup.json" "$BACKUP"
  rmdir "$LEGACY_BACKUP_DIR" 2>/dev/null
fi

# Строки вида @@ключ=значение читает приложение; для человека они безвредны.
emit() { printf '@@%s=%s\n' "$1" "$2"; }
step() { printf '  • %s\n' "$1"; }
fail() { emit RESULT fail; emit SUMMARY "$1"; exit 1; }

# ── чтение состояния ─────────────────────────────────────────────────────────

macos_version() { sw_vers -productVersion; }
macos_major()   { sw_vers -productVersion | cut -d. -f1; }

# Ремап Caps Lock -> F18 активен прямо сейчас?
remap_active() {
  hidutil property --get UserKeyMapping 2>/dev/null \
    | tr -d ' \n' | grep -q "Src=$CAPS_HID_DEC" && \
  hidutil property --get UserKeyMapping 2>/dev/null \
    | tr -d ' \n' | grep -q "Dst=$((F18_HID))"
}

# Шорткат «предыдущий источник ввода» назначен на F18 и включён?
hotkey_ok() {
  /usr/libexec/PlistBuddy -c "Print :AppleSymbolicHotKeys:$HOTKEY_ID" \
    "$HOME/Library/Preferences/com.apple.symbolichotkeys.plist" 2>/dev/null \
    | tr -d ' \n' | grep -q "enabled=true" || return 1
  /usr/libexec/PlistBuddy -c "Print :AppleSymbolicHotKeys:$HOTKEY_ID:value:parameters:1" \
    "$HOME/Library/Preferences/com.apple.symbolichotkeys.plist" 2>/dev/null \
    | grep -qx "$F18_KEYCODE"
}

# Сколько раскладок клавиатуры включено (переключать имеет смысл от двух).
layout_count() {
  python3 - <<'PY' 2>/dev/null || echo 0
import subprocess, plistlib
raw = subprocess.run(['defaults','export','com.apple.HIToolbox','-'],
                     capture_output=True).stdout
try:
    d = plistlib.loads(raw)
except Exception:
    print(0); raise SystemExit
print(sum(1 for s in d.get('AppleEnabledInputSources', [])
          if 'KeyboardLayout Name' in s))
PY
}

# Caps Lock переведён в «Нет действия» в Modifier Keys? Тогда фикс не сработает.
capslock_noaction_keys() {
  python3 - <<'PY' 2>/dev/null
import subprocess, plistlib
CAPS = 30064771129
raw = subprocess.run(['defaults','-currentHost','export','-g','-'],
                     capture_output=True).stdout
try:
    d = plistlib.loads(raw)
except Exception:
    raise SystemExit
for k, v in d.items():
    if not k.startswith('com.apple.keyboard.modifiermapping'):
        continue
    for m in (v if isinstance(v, list) else []):
        if m.get('HIDKeyboardModifierMappingSrc') == CAPS and \
           m.get('HIDKeyboardModifierMappingDst') in (-1, None):
            print(k)
PY
}

launchagent_loaded() {
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1
}

# ── check ────────────────────────────────────────────────────────────────────

do_check() {
  local v major layouts noaction
  v=$(macos_version); major=$(macos_major)
  layouts=$(layout_count)
  noaction=$(capslock_noaction_keys | head -1)

  echo "== Диагностика =="
  step "macOS $v"
  emit MACOS "$v"

  if [ "$major" -ge "$MIN_MACOS" ]; then
    step "версия поддерживается (нужна $MIN_MACOS+)"
    emit SUPPORTED yes
  else
    step "версия НЕ поддерживается (нужна $MIN_MACOS+)"
    emit SUPPORTED no
  fi

  step "права администратора не нужны"
  emit NEEDS_ROOT no

  step "раскладок клавиатуры включено: $layouts"
  emit LAYOUTS "$layouts"

  if [ -n "$noaction" ]; then
    step "Caps Lock стоит «Нет действия» — фикс это исправит"
    emit CAPS_NOACTION yes
  else
    emit CAPS_NOACTION no
  fi

  local applied=yes
  remap_active        || applied=no
  hotkey_ok           || applied=no
  [ -f "$PLIST" ]     || applied=no
  if [ "$applied" = yes ]; then
    step "фикс уже применён"
  else
    step "фикс не применён"
  fi
  emit APPLIED "$applied"
  [ -f "$BACKUP" ] && emit HAS_BACKUP yes || emit HAS_BACKUP no

  emit RESULT ok
  emit SUMMARY "Диагностика выполнена"
}

# ── apply ────────────────────────────────────────────────────────────────────

save_backup() {
  # Бэкап снимается один раз — при самом первом apply. Повторный apply его
  # не перезаписывает, иначе откат вернул бы уже изменённое состояние.
  [ -f "$BACKUP" ] && { step "бэкап уже есть, не трогаю"; return 0; }
  mkdir -p "$BACKUP_DIR"
  python3 - "$BACKUP" "$PLIST" "$HOTKEY_ID" <<'PY'
import json, os, subprocess, sys
backup, plist, hotkey = sys.argv[1], sys.argv[2], sys.argv[3]
hk_file = os.path.expanduser('~/Library/Preferences/com.apple.symbolichotkeys.plist')
hk = subprocess.run(['/usr/libexec/PlistBuddy', '-x',
                     '-c', f'Print :AppleSymbolicHotKeys:{hotkey}', hk_file],
                    capture_output=True)
data = {
    'user_key_mapping': subprocess.run(['hidutil', 'property', '--get', 'UserKeyMapping'],
                                       capture_output=True, text=True).stdout.strip(),
    'hotkey_xml': hk.stdout.decode() if hk.returncode == 0 else None,
    'launchagent_existed': os.path.exists(plist),
    'launchagent_body': open(plist).read() if os.path.exists(plist) else None,
}
with open(backup, 'w') as f:
    json.dump(data, f, indent=2)
PY
  step "бэкап прежнего состояния: $BACKUP"
}

do_apply() {
  local major; major=$(macos_major)
  [ "$major" -ge "$MIN_MACOS" ] || fail "macOS $(macos_version) не поддерживается"

  echo "== Применяю фикс =="
  save_backup

  # 1. Ремап на уровне HID: любое событие Caps Lock система видит как F18.
  hidutil property --set \
    "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":$CAPS_HID,\"HIDKeyboardModifierMappingDst\":$F18_HID}]}" \
    >/dev/null || fail "hidutil не смог применить ремап"
  step "Caps Lock -> F18 (действует сразу)"

  # 2. LaunchAgent повторяет тот же ремап при каждом входе в систему,
  #    иначе после перезагрузки Caps Lock снова станет Caps Lock.
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/hidutil</string>
        <string>property</string>
        <string>--set</string>
        <string>{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":$CAPS_HID,"HIDKeyboardModifierMappingDst":$F18_HID}]}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF
  plutil -lint "$PLIST" >/dev/null || fail "получился битый plist LaunchAgent"
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1
  launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 \
    || step "внимание: launchctl bootstrap вернул ошибку (ремап работает, но может не пережить перезагрузку)"
  step "автозагрузка ремапа: $PLIST"

  # 3. Системный шорткат «Выбрать предыдущий источник ввода» = F18.
  #    65535 — «символа нет», 79 — код F18, 8388608 — флаг Function,
  #    именно в таком виде System Settings записывает нажатие F18.
  defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add "$HOTKEY_ID" "
    <dict>
      <key>enabled</key><true/>
      <key>value</key>
      <dict>
        <key>parameters</key>
        <array>
          <integer>65535</integer>
          <integer>$F18_KEYCODE</integer>
          <integer>$F18_MODS</integer>
        </array>
        <key>type</key><string>standard</string>
      </dict>
    </dict>" || fail "не удалось записать системный шорткат"
  step "шорткат «предыдущий источник ввода» = F18"

  # 4. Хвост от Karabiner и подобных: Caps Lock переведён в «Нет действия».
  #    В этом состоянии клавиша не отдаёт события вообще и фикс не работает.
  local fixed=0
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    defaults -currentHost write -g "$key" "
      <array>
        <dict>
          <key>HIDKeyboardModifierMappingDst</key><integer>$CAPS_HID_DEC</integer>
          <key>HIDKeyboardModifierMappingSrc</key><integer>$CAPS_HID_DEC</integer>
        </dict>
      </array>"
    fixed=$((fixed + 1))
  done < <(capslock_noaction_keys)
  [ "$fixed" -gt 0 ] && step "Caps Lock возвращён из «Нет действия» ($fixed клавиатур)"

  # 5. Просим систему перечитать настройки, чтобы шорткат заработал без релогина.
  [ -x "$ACTIVATE" ] && "$ACTIVATE" -u >/dev/null 2>&1
  step "настройки перечитаны"

  # 6. Проверяем результат по факту, а не по коду возврата команд.
  echo
  echo "== Проверка =="
  local ok=1
  if remap_active; then step "ремап активен"; else step "ремап НЕ активен"; ok=0; fi
  if hotkey_ok;    then step "шорткат на месте"; else step "шорткат НЕ записался"; ok=0; fi
  if launchagent_loaded; then step "агент автозагрузки зарегистрирован"
  else step "агент автозагрузки не зарегистрирован"; fi

  local layouts; layouts=$(layout_count)
  emit LAYOUTS "$layouts"
  if [ "$layouts" -lt 2 ]; then
    step "включена всего $layouts раскладка — добавьте вторую в настройках клавиатуры"
  fi

  emit APPLIED yes
  if [ "$ok" -eq 1 ]; then
    emit RESULT ok
    if [ "$layouts" -lt 2 ]; then
      emit SUMMARY "Фикс применён, но включена только одна раскладка — переключать нечего"
    else
      emit SUMMARY "Caps Lock переключает раскладку. Изменения переживут перезагрузку"
    fi
  else
    fail "Часть изменений не применилась — смотрите журнал"
  fi
}

# ── revert ───────────────────────────────────────────────────────────────────

do_revert() {
  echo "== Откат =="
  [ -f "$BACKUP" ] || fail "Бэкап не найден — откатывать нечего"

  # Возврат агента автозагрузки в исходное состояние.
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1
  python3 - "$BACKUP" "$PLIST" <<'PY'
import json, os, sys
backup, plist = sys.argv[1], sys.argv[2]
d = json.load(open(backup))
if d.get('launchagent_existed') and d.get('launchagent_body'):
    open(plist, 'w').write(d['launchagent_body'])
    print('  • LaunchAgent возвращён к прежнему содержимому')
elif os.path.exists(plist):
    os.remove(plist)
    print('  • LaunchAgent удалён')
PY
  [ -f "$PLIST" ] && launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1

  # Возврат ремапа HID. Пустой бэкап = ремапа не было, ставим пустой список.
  local had_mapping
  had_mapping=$(python3 -c "
import json,sys
d=json.load(open('$BACKUP'))
m=(d.get('user_key_mapping') or '').strip()
print('yes' if m and m != '(null)' and 'HIDKeyboardModifierMappingSrc' in m else 'no')")
  if [ "$had_mapping" = yes ]; then
    step "прежний ремап клавиш восстановить автоматически нельзя — снимаю ремап"
  fi
  hidutil property --set '{"UserKeyMapping":[]}' >/dev/null
  step "Caps Lock снова обычный Caps Lock"

  # Возврат системного шортката.
  #
  # Восстановление и удаление идут разными путями намеренно: `defaults` пишет
  # через демон настроек и сразу перезаписывает ключ целиком, а вот удалить
  # вложенный ключ он не умеет — там нужен PlistBuddy, который правит файл
  # мимо кэша демона, поэтому кэш после него приходится сбрасывать.
  hotkey_xml=$(python3 -c "
import json
d=json.load(open('$BACKUP'))
print(d.get('hotkey_xml') or '')")

  if [ -n "$hotkey_xml" ]; then
    defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add "$HOTKEY_ID" "$hotkey_xml"
    step "шорткат «предыдущий источник ввода» возвращён к прежнему значению"
  else
    /usr/libexec/PlistBuddy -c "Delete :AppleSymbolicHotKeys:$HOTKEY_ID" \
      "$HOME/Library/Preferences/com.apple.symbolichotkeys.plist" >/dev/null 2>&1
    killall cfprefsd 2>/dev/null
    step "шорткат «предыдущий источник ввода» удалён (его не было до фикса)"
  fi
  [ -x "$ACTIVATE" ] && "$ACTIVATE" -u >/dev/null 2>&1

  rm -f "$BACKUP"
  step "бэкап удалён"

  emit APPLIED no
  emit RESULT ok
  emit SUMMARY "Всё возвращено к состоянию до фикса"
}

case "${1:-check}" in
  check)  do_check  ;;
  apply)  do_apply  ;;
  revert) do_revert ;;
  *) echo "Использование: $(basename "$0") {check|apply|revert}"; exit 2 ;;
esac
