#!/bin/bash
#
# input-source-fix.sh — переключение языка ввода по клавише Caps Lock.
#
#   input-source-fix.sh check     проверка: версия macOS, права, текущее состояние
#   input-source-fix.sh apply     включить (с сохранением прежних настроек)
#   input-source-fix.sh revert    вернуть настройки к тому, что было до включения
#
#   --lang ru|en                  язык сообщений (по умолчанию ru)
#
# ЗАЧЕМ. В macOS есть штатная галка «Использовать Caps Lock для переключения
# раскладки». Она работает через обработчик, который при быстром наборе теряет
# нажатия: печатаешь быстро — язык не переключился, половина слова ушла не туда.
#
# КАК. Физический Caps Lock перекладывается на клавишу F18 прямо в драйвере
# клавиатуры (hidutil), а на F18 вешается системный шорткат «Выбрать предыдущий
# источник ввода». Этот путь синхронный и нажатия не теряет.
#
# ЧТО МЕНЯЕТСЯ НА ДИСКЕ (всё — только в домашней папке пользователя):
#   1. hidutil UserKeyMapping           — ремап Caps Lock -> F18 (живёт до перезагрузки)
#   2. ~/Library/LaunchAgents/com.user.capslock2f18.plist — повторяет ремап при входе
#   3. com.apple.symbolichotkeys, ключ 60 — шорткат «предыдущий источник ввода» = F18
#   4. com.apple.keyboard.modifiermapping.* — ТОЛЬКО если Caps Lock отключён
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

UILANG=ru

# Бэкап, снятый прежней версией приложения, переезжает под новое имя —
# иначе кнопка отмены перестала бы видеть уже сохранённое состояние.
if [ -f "$LEGACY_BACKUP_DIR/input-source-backup.json" ] && [ ! -f "$BACKUP" ]; then
  mkdir -p "$BACKUP_DIR"
  mv "$LEGACY_BACKUP_DIR/input-source-backup.json" "$BACKUP"
  rmdir "$LEGACY_BACKUP_DIR" 2>/dev/null
fi

# ── сообщения ────────────────────────────────────────────────────────────────
#
# Оба языка лежат рядом: так перевод виден вместе с оригиналом и не разъезжается
# с кодом. `t` отдаёт строку, значения подставляются через printf.

t() {
  local ru en
  case "$1" in
    check_head)     ru="== Проверка системы =="            ; en="== System check ==" ;;
    apply_head)     ru="== Включаю =="                     ; en="== Turning on ==" ;;
    revert_head)    ru="== Возвращаю прежние настройки ==" ; en="== Restoring previous settings ==" ;;
    verify_head)    ru="== Проверка результата =="         ; en="== Verifying ==" ;;
    macos)          ru="macOS %s"                          ; en="macOS %s" ;;
    supported)      ru="версия подходит"                   ; en="version is supported" ;;
    unsupported)    ru="версия не подходит, нужна macOS %s или новее"
                    en="version is too old, macOS %s or later is required" ;;
    no_root)        ru="пароль администратора не нужен"    ; en="no administrator password needed" ;;
    layouts)        ru="языков ввода включено: %s"         ; en="input languages enabled: %s" ;;
    caps_off)       ru="клавиша Caps Lock отключена в настройках — включу обратно"
                    en="the Caps Lock key is disabled in Settings — it will be re-enabled" ;;
    is_on)          ru="сейчас включено"                   ; en="currently on" ;;
    is_off)         ru="сейчас выключено"                  ; en="currently off" ;;
    check_done)     ru="Проверка выполнена"                ; en="System check complete" ;;
    backup_kept)    ru="прежние настройки уже сохранены"   ; en="previous settings are already saved" ;;
    backup_saved)   ru="прежние настройки сохранены: %s"   ; en="previous settings saved to: %s" ;;
    remap_done)     ru="Caps Lock теперь работает как переключатель языка"
                    en="Caps Lock now acts as the language switch" ;;
    agent_done)     ru="настройка будет восстанавливаться при каждом входе в систему"
                    en="the setting will be restored at every login" ;;
    agent_warn)     ru="внимание: автозагрузка не зарегистрировалась, после перезагрузки может слететь"
                    en="warning: the login item did not register, the setting may not survive a reboot" ;;
    hotkey_done)    ru="сочетание для смены языка назначено"
                    en="the language-switch shortcut is assigned" ;;
    caps_fixed)     ru="клавиша Caps Lock включена обратно (клавиатур: %s)"
                    en="the Caps Lock key was re-enabled (keyboards: %s)" ;;
    settings_read)  ru="настройки перечитаны"              ; en="settings reloaded" ;;
    ok_remap)       ru="переключение работает"             ; en="switching works" ;;
    bad_remap)      ru="переключение НЕ работает"          ; en="switching does NOT work" ;;
    ok_hotkey)      ru="сочетание на месте"                ; en="the shortcut is in place" ;;
    bad_hotkey)     ru="сочетание не записалось"           ; en="the shortcut was not written" ;;
    ok_agent)       ru="автозагрузка настроена"            ; en="the login item is set up" ;;
    bad_agent)      ru="автозагрузка не настроена"         ; en="the login item is not set up" ;;
    one_layout)     ru="включён только один язык ввода — добавьте второй в настройках клавиатуры"
                    en="only one input language is enabled — add a second one in Keyboard settings" ;;
    sum_ok)         ru="Caps Lock переключает язык. Настройка переживёт перезагрузку"
                    en="Caps Lock switches the language. The setting survives a reboot" ;;
    sum_one_layout) ru="Включено, но язык ввода всего один — переключать нечего"
                    en="Turned on, but there is only one input language — nothing to switch between" ;;
    sum_partial)    ru="Получилось не всё — смотрите журнал"
                    en="Some steps did not apply — see the activity log" ;;
    sum_unsupported) ru="macOS %s не поддерживается"       ; en="macOS %s is not supported" ;;
    err_hidutil)    ru="Не удалось изменить настройки клавиатуры"
                    en="Could not change the keyboard settings" ;;
    err_plist)      ru="Не удалось создать файл автозагрузки"
                    en="Could not create the login item file" ;;
    err_hotkey)     ru="Не удалось назначить сочетание клавиш"
                    en="Could not assign the keyboard shortcut" ;;
    no_backup)      ru="Отменять нечего: сохранённых настроек нет"
                    en="Nothing to undo: no saved settings found" ;;
    agent_restored) ru="файл автозагрузки возвращён к прежнему виду"
                    en="the login item file was restored" ;;
    agent_removed)  ru="файл автозагрузки удалён"          ; en="the login item file was removed" ;;
    remap_dropped)  ru="Caps Lock снова обычный Caps Lock" ; en="Caps Lock is a plain Caps Lock again" ;;
    remap_complex)  ru="прежняя раскладка клавиш была нестандартной — снимаю изменения целиком"
                    en="the previous key mapping was non-standard — removing all changes" ;;
    hotkey_restored) ru="сочетание для смены языка возвращено к прежнему значению"
                     en="the language-switch shortcut was restored to its previous value" ;;
    hotkey_removed) ru="сочетание для смены языка удалено (его не было до включения)"
                    en="the language-switch shortcut was removed (there was none before)" ;;
    backup_dropped) ru="сохранённые настройки больше не нужны и удалены"
                    en="the saved settings are no longer needed and were deleted" ;;
    sum_reverted)   ru="Всё вернулось к тому, что было до включения"
                    en="Everything is back to how it was before" ;;
    *)              ru="$1"                                ; en="$1" ;;
  esac
  [ "$UILANG" = en ] && printf '%s' "$en" || printf '%s' "$ru"
}

# Строки вида @@ключ=значение читает приложение; для человека они безвредны.
emit() { printf '@@%s=%s\n' "$1" "$2"; }
# shellcheck disable=SC2059  # формат приходит из таблицы выше, не извне
step() { local f; f=$(t "$1"); shift; printf '  • '; printf "$f" "$@"; printf '\n'; }
head_() { printf '%s\n' "$(t "$1")"; }
# shellcheck disable=SC2059
fail() { local f; f=$(t "$1"); shift; emit RESULT fail; emit SUMMARY "$(printf "$f" "$@")"; exit 1; }

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

# Сколько языков ввода включено (переключать имеет смысл от двух).
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

# Caps Lock переведён в «Нет действия» в настройках клавиатуры? Тогда не сработает.
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

  head_ check_head
  step macos "$v"
  emit MACOS "$v"

  if [ "$major" -ge "$MIN_MACOS" ]; then
    step supported; emit SUPPORTED yes
  else
    step unsupported "$MIN_MACOS"; emit SUPPORTED no
  fi

  step no_root
  emit NEEDS_ROOT no

  step layouts "$layouts"
  emit LAYOUTS "$layouts"

  if [ -n "$noaction" ]; then
    step caps_off; emit CAPS_NOACTION yes
  else
    emit CAPS_NOACTION no
  fi

  local applied=yes
  remap_active        || applied=no
  hotkey_ok           || applied=no
  [ -f "$PLIST" ]     || applied=no
  [ "$applied" = yes ] && step is_on || step is_off
  emit APPLIED "$applied"
  [ -f "$BACKUP" ] && emit HAS_BACKUP yes || emit HAS_BACKUP no

  emit RESULT ok
  emit SUMMARY "$(t check_done)"
}

# ── apply ────────────────────────────────────────────────────────────────────

save_backup() {
  # Прежние настройки сохраняются один раз — при первом включении. Повторное
  # включение их не перезаписывает, иначе отмена вернула бы уже изменённое.
  [ -f "$BACKUP" ] && { step backup_kept; return 0; }
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
  step backup_saved "$BACKUP"
}

do_apply() {
  local major; major=$(macos_major)
  [ "$major" -ge "$MIN_MACOS" ] || fail sum_unsupported "$(macos_version)"

  head_ apply_head
  save_backup

  # 1. Ремап на уровне драйвера: любое нажатие Caps Lock система видит как F18.
  hidutil property --set \
    "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":$CAPS_HID,\"HIDKeyboardModifierMappingDst\":$F18_HID}]}" \
    >/dev/null || fail err_hidutil
  step remap_done

  # 2. LaunchAgent повторяет тот же ремап при каждом входе в систему,
  #    иначе после перезагрузки Caps Lock снова станет Caps Lock.
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<PLIST_EOF
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
PLIST_EOF
  plutil -lint "$PLIST" >/dev/null || fail err_plist
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1
  launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || step agent_warn
  step agent_done

  # 3. Системный шорткат «Выбрать предыдущий источник ввода» = F18.
  #    65535 — «символа нет», 79 — код F18, 8388608 — флаг Function,
  #    именно в таком виде системные настройки записывают нажатие F18.
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
    </dict>" || fail err_hotkey
  step hotkey_done

  # 4. Хвост от Karabiner и подобных: Caps Lock переведён в «Нет действия».
  #    В этом состоянии клавиша не отдаёт событий вообще и ничего не сработает.
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
  [ "$fixed" -gt 0 ] && step caps_fixed "$fixed"

  # 5. Просим систему перечитать настройки, чтобы всё заработало без релогина.
  [ -x "$ACTIVATE" ] && "$ACTIVATE" -u >/dev/null 2>&1
  step settings_read

  # 6. Проверяем результат по факту, а не по кодам возврата команд.
  echo
  head_ verify_head
  local ok=1
  remap_active && step ok_remap || { step bad_remap; ok=0; }
  hotkey_ok    && step ok_hotkey || { step bad_hotkey; ok=0; }
  launchagent_loaded && step ok_agent || step bad_agent

  local layouts; layouts=$(layout_count)
  emit LAYOUTS "$layouts"
  [ "$layouts" -lt 2 ] && step one_layout

  emit APPLIED yes
  if [ "$ok" -eq 1 ]; then
    emit RESULT ok
    if [ "$layouts" -lt 2 ]; then
      emit SUMMARY "$(t sum_one_layout)"
    else
      emit SUMMARY "$(t sum_ok)"
    fi
  else
    fail sum_partial
  fi
}

# ── revert ───────────────────────────────────────────────────────────────────

do_revert() {
  head_ revert_head
  [ -f "$BACKUP" ] || fail no_backup

  # Возврат автозагрузки в исходное состояние.
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1
  local had_agent
  had_agent=$(python3 - "$BACKUP" "$PLIST" <<'PY'
import json, os, sys
backup, plist = sys.argv[1], sys.argv[2]
d = json.load(open(backup))
if d.get('launchagent_existed') and d.get('launchagent_body'):
    open(plist, 'w').write(d['launchagent_body'])
    print('restored')
elif os.path.exists(plist):
    os.remove(plist)
    print('removed')
PY
)
  [ "$had_agent" = restored ] && step agent_restored
  [ "$had_agent" = removed ]  && step agent_removed
  [ -f "$PLIST" ] && launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1

  # Возврат ремапа. Пустое сохранённое значение = ремапа не было.
  local had_mapping
  had_mapping=$(python3 -c "
import json
d=json.load(open('$BACKUP'))
m=(d.get('user_key_mapping') or '').strip()
print('yes' if m and m != '(null)' and 'HIDKeyboardModifierMappingSrc' in m else 'no')")
  [ "$had_mapping" = yes ] && step remap_complex
  hidutil property --set '{"UserKeyMapping":[]}' >/dev/null
  step remap_dropped

  # Возврат системного шортката.
  #
  # Восстановление и удаление идут разными путями намеренно: `defaults` пишет
  # через демон настроек и сразу перезаписывает ключ целиком, а вот удалить
  # вложенный ключ он не умеет — там нужен PlistBuddy, который правит файл
  # мимо кэша демона, поэтому кэш после него приходится сбрасывать.
  local hotkey_xml
  hotkey_xml=$(python3 -c "
import json
d=json.load(open('$BACKUP'))
print(d.get('hotkey_xml') or '')")

  if [ -n "$hotkey_xml" ]; then
    defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add "$HOTKEY_ID" "$hotkey_xml"
    step hotkey_restored
  else
    /usr/libexec/PlistBuddy -c "Delete :AppleSymbolicHotKeys:$HOTKEY_ID" \
      "$HOME/Library/Preferences/com.apple.symbolichotkeys.plist" >/dev/null 2>&1
    killall cfprefsd 2>/dev/null
    step hotkey_removed
  fi
  [ -x "$ACTIVATE" ] && "$ACTIVATE" -u >/dev/null 2>&1

  rm -f "$BACKUP"
  step backup_dropped

  emit APPLIED no
  emit RESULT ok
  emit SUMMARY "$(t sum_reverted)"
}

# ── разбор аргументов ────────────────────────────────────────────────────────

CMD="${1:-check}"; shift 2>/dev/null || true
while [ $# -gt 0 ]; do
  case "$1" in
    --lang) UILANG="${2:-ru}"; shift 2 ;;
    *) shift ;;
  esac
done
[ "$UILANG" = en ] || UILANG=ru

case "$CMD" in
  check)  do_check  ;;
  apply)  do_apply  ;;
  revert) do_revert ;;
  *) echo "usage: $(basename "$0") {check|apply|revert} [--lang ru|en]"; exit 2 ;;
esac
