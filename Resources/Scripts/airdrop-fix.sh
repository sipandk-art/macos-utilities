#!/bin/bash
#
# airdrop-fix.sh — снять зависшее окно AirDrop без перезагрузки Mac.
#
#   airdrop-fix.sh check              проверка: версия macOS, права, что нашлось
#   airdrop-fix.sh list               только показать найденное, ничего не трогать
#   airdrop-fix.sh fix [флаги]        закрыть зависшее и перезапустить AirDrop
#   airdrop-fix.sh selftest           самопроверка разбора возраста процессов
#
#   флаги:
#     --finder      вдобавок перезапустить Finder
#     --wifi        вдобавок перезапустить Wi-Fi-интерфейс awdl0 (спросит пароль)
#     --age N       считать зависшим то, что живёт дольше N секунд (по умолчанию 300)
#     --lang ru|en  язык сообщений (по умолчанию ru)
#
# ЗАЧЕМ. Окно «Поделиться -> AirDrop» рисует не сам Finder, а два его расширения:
# ShareSheetUI.appex и AirDrop.appex. Иногда окно закрывают, а расширения
# не выходят — процессы висят в системе неделями, держат отправляемый файл
# и время от времени всплывают поверх других окон.
#
# КАК. Найти эти процессы по пути к бандлу расширения, отсеять свежие (вдруг
# пользователь прямо сейчас что-то отправляет), закрыть старые и перезапустить
# sharingd — служебную программу, которая и есть AirDrop. Система поднимет её сама.
#
# ПРАВА. sudo/root НЕ НУЖЕН для основного сценария: закрываются собственные
# процессы пользователя. Пароль администратора нужен ТОЛЬКО для флага --wifi.

set -u

MIN_AGE=300            # пять минут: столько шит AirDrop живым уже не бывает
RESTART_FINDER=0
RESTART_WIFI=0
MIN_MACOS=11
UILANG=ru

# Пути к бандлам расширений — по ним процессы и опознаются.
PATTERN='AirDrop\.appex/Contents/MacOS/AirDrop|ShareSheetUI\.appex/Contents/MacOS/ShareSheetUI'

# ── сообщения ────────────────────────────────────────────────────────────────
#
# Оба языка лежат рядом: так перевод виден вместе с оригиналом и не разъезжается
# с кодом. `t` отдаёт строку, значения подставляются через printf.

t() {
  local ru en
  case "$1" in
    check_head)    ru="== Проверка системы =="     ; en="== System check ==" ;;
    procs_head)    ru="== Окна AirDrop (зависшим считается то, что живёт дольше %s мин) =="
                   en="== AirDrop windows (stuck means alive longer than %s min) ==" ;;
    kill_head)     ru="== Закрываю зависшее:%s ==" ; en="== Closing what is stuck:%s ==" ;;
    restart_head)  ru="== Перезапускаю AirDrop ==" ; en="== Restarting AirDrop ==" ;;
    finder_head)   ru="== Перезапускаю Finder ==" ; en="== Restarting Finder ==" ;;
    wifi_head)     ru="== Перезапускаю Wi-Fi для AirDrop (нужен пароль администратора) =="
                   en="== Restarting Wi-Fi for AirDrop (administrator password required) ==" ;;
    state_head)    ru="== Состояние =="            ; en="== Status ==" ;;
    macos)         ru="macOS %s"                   ; en="macOS %s" ;;
    supported)     ru="версия подходит"            ; en="version is supported" ;;
    unsupported)   ru="версия не подходит, нужна macOS %s или новее"
                   en="version is too old, macOS %s or later is required" ;;
    no_root)       ru="пароль администратора не нужен (нужен только для перезапуска Wi-Fi)"
                   en="no administrator password needed (only for restarting Wi-Fi)" ;;
    service_up)    ru="служба AirDrop работает"    ; en="the AirDrop service is running" ;;
    service_down)  ru="служба AirDrop не запущена" ; en="the AirDrop service is not running" ;;
    stuck)         ru="ЗАВИСЛО"                    ; en="STUCK" ;;
    fine)          ru="норма"                      ; en="ok" ;;
    stuck_file)    ru="застрял файл: %s"           ; en="stuck file: %s" ;;
    nothing)       ru="ничего не найдено, чисто"   ; en="nothing found, all clear" ;;
    look_only)     ru="режим просмотра — ничего не тронуто"
                   en="look-only mode — nothing was touched" ;;
    force)         ru="не отвечают, закрываю принудительно:%s"
                   en="not responding, force-closing:%s" ;;
    closed)        ru="закрыто окон: %s"           ; en="windows closed: %s" ;;
    service_back)  ru="служба AirDrop перезапущена" ; en="the AirDrop service restarted" ;;
    service_fail)  ru="ВНИМАНИЕ: служба AirDrop не перезапустилась"
                   en="WARNING: the AirDrop service did not restart" ;;
    finder_ok)     ru="Finder перезапущен"         ; en="Finder restarted" ;;
    finder_absent) ru="Finder не был запущен"      ; en="Finder was not running" ;;
    wifi_ok)       ru="Wi-Fi для AirDrop перезапущен" ; en="Wi-Fi for AirDrop restarted" ;;
    wifi_fail)     ru="не получилось: ввод пароля отменён или нет прав"
                   en="did not work: the password prompt was cancelled or permission denied" ;;
    visible_to)    ru="AirDrop видят: %s"          ; en="AirDrop is visible to: %s" ;;
    wifi_state)    ru="Wi-Fi для AirDrop: %s"      ; en="Wi-Fi for AirDrop: %s" ;;
    wifi_on)       ru="работает"                   ; en="working" ;;
    wifi_off)      ru="не поднят"                  ; en="down" ;;
    finally)       ru="Готово. Откройте Finder -> AirDrop (Shift-Cmd-R) и проверьте."
                   en="Done. Open Finder -> AirDrop (Shift-Cmd-R) and check." ;;
    check_done)    ru="Проверка выполнена"         ; en="System check complete" ;;
    sum_found)     ru="Найдены зависшие окна AirDrop" ; en="Found stuck AirDrop windows" ;;
    sum_clean)     ru="Зависших окон AirDrop нет"  ; en="No stuck AirDrop windows" ;;
    sum_fixed)     ru="Закрыто зависших окон: %s, служба AirDrop перезапущена"
                   en="Stuck windows closed: %s, the AirDrop service restarted" ;;
    sum_nothing)   ru="Зависших окон не было, служба AirDrop перезапущена"
                   en="Nothing was stuck, the AirDrop service restarted" ;;
    sum_unsupported) ru="macOS %s не поддерживается" ; en="macOS %s is not supported" ;;
    not_set)       ru="(не задано)"                ; en="(not set)" ;;
    *)             ru="$1"                         ; en="$1" ;;
  esac
  [ "$UILANG" = en ] && printf '%s' "$en" || printf '%s' "$ru"
}

emit() { printf '@@%s=%s\n' "$1" "$2"; }
# shellcheck disable=SC2059  # формат приходит из таблицы выше, не извне
step() { local f; f=$(t "$1"); shift; printf '  • '; printf "$f" "$@"; printf '\n'; }
# shellcheck disable=SC2059
head_() { local f; f=$(t "$1"); shift; printf "$f" "$@"; printf '\n'; }

# ── разбор аргументов ────────────────────────────────────────────────────────

CMD="${1:-check}"; shift 2>/dev/null || true
while [ $# -gt 0 ]; do
  case "$1" in
    --age)    MIN_AGE="${2:-300}"; shift 2 ;;
    --finder) RESTART_FINDER=1; shift ;;
    --wifi)   RESTART_WIFI=1; shift ;;
    --lang)   UILANG="${2:-ru}"; shift 2 ;;
    *) shift ;;
  esac
done
[ "$UILANG" = en ] || UILANG=ru

# ── поиск процессов ──────────────────────────────────────────────────────────

# Печатает по строке на процесс: pid <TAB> возраст_в_секундах <TAB> имя.
# ps выдаёт возраст в четырёх разных форматах (SS, MM:SS, HH:MM:SS, DD-HH:MM:SS),
# awk-функция secs() приводит их к секундам — это единственная нетривиальная
# логика в скрипте, она закрыта самопроверкой (см. `selftest`).
scan() {
  ps -Ao pid=,etime=,comm= | scan_stdin
}

scan_stdin() {
  awk -v pat="$PATTERN" '
    function secs(e,   d, a, t, n, s) {
      d = 0
      n = split(e, a, "-")
      if (n == 2) { d = a[1]; e = a[2] }
      n = split(e, t, ":")
      if (n == 3)      s = t[1] * 3600 + t[2] * 60 + t[3]
      else if (n == 2) s = t[1] * 60 + t[2]
      else             s = t[1]
      return d * 86400 + s
    }
    $0 ~ pat {
      name = $3
      sub(/.*\//, "", name)
      print $1 "\t" secs($2) "\t" name
    }'
}

human() {
  s=$1
  if   [ "$s" -lt 60 ];    then echo "${s}s"
  elif [ "$s" -lt 3600 ];  then echo "$((s / 60))m"
  elif [ "$s" -lt 86400 ]; then echo "$((s / 3600))h$(((s % 3600) / 60))m"
  else                          echo "$((s / 86400))d$(((s % 86400) / 3600))h"
  fi
}

do_selftest() {
  printf '%s\n' \
    " 111 45 /x/AirDrop.appex/Contents/MacOS/AirDrop" \
    " 222 3:07 /x/AirDrop.appex/Contents/MacOS/AirDrop" \
    " 333 2:10:30 /x/ShareSheetUI.appex/Contents/MacOS/ShareSheetUI" \
    " 444 15-21:20:16 /x/AirDrop.appex/Contents/MacOS/AirDrop" \
    " 555 9:99 /usr/libexec/notmatching" \
  | scan_stdin | awk -F'\t' '
      $1==111 && $2==45      { ok++; next }
      $1==222 && $2==187     { ok++; next }
      $1==333 && $2==7830    { ok++; next }
      $1==444 && $2==1372816 { ok++; next }
      { bad++ }
      END { if (ok==4 && bad==0 && NR==4) { print "PASS"; exit 0 }
            else { print "FAIL ok=" ok+0 " bad=" bad+0 " NR=" NR; exit 1 } }'
}

# Печатает найденное, список зависших отдаёт через глобальную STALE.
STALE=""
report_procs() {
  local found=0 stale_n=0 mark f
  STALE=""
  head_ procs_head "$((MIN_AGE / 60))"
  while IFS="$(printf '\t')" read -r pid age name; do
    [ -z "$pid" ] && continue
    found=$((found + 1))
    if [ "$age" -ge "$MIN_AGE" ]; then
      mark=$(t stuck); STALE="$STALE $pid"; stale_n=$((stale_n + 1))
    else
      mark=$(t fine)
    fi
    printf '  %-7s %-8s %-14s %s\n' "$pid" "$(human "$age")" "$name" "$mark"
    # Какой пользовательский файл держит процесс — обычно это застрявшая отправка.
    # cwd и rtd исключены: это рабочий и корневой каталоги, а не отправляемый файл.
    # А вот txt оставлен — застрявший файл процесс держит именно так, отображённым
    # в память (проверено на реально зависшем окне).
    f=$(lsof -w -p "$pid" -a -d '^cwd,^rtd' -Fn 2>/dev/null \
        | grep '^n/Users/' | grep -v '/Library/' | head -1 | cut -c2-)
    [ -n "$f" ] && step stuck_file "$f"
  done < <(scan)
  [ "$found" -eq 0 ] && step nothing
  emit FOUND "$found"
  emit STALE "$stale_n"
}

# ── команды ──────────────────────────────────────────────────────────────────

do_check() {
  local v major
  v=$(sw_vers -productVersion); major=$(echo "$v" | cut -d. -f1)
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
  if pgrep -x sharingd >/dev/null; then
    step service_up; emit SHARINGD up
  else
    step service_down; emit SHARINGD down
  fi
  echo
  report_procs
  emit RESULT ok
  emit SUMMARY "$(t check_done)"
}

do_list() {
  report_procs
  echo
  step look_only
  emit RESULT ok
  if [ -n "${STALE// /}" ]; then
    emit SUMMARY "$(t sum_found)"
  else
    emit SUMMARY "$(t sum_clean)"
  fi
}

do_fix() {
  local v major killed=0 survivors old new i
  v=$(sw_vers -productVersion); major=$(echo "$v" | cut -d. -f1)
  if [ "$major" -lt "$MIN_MACOS" ]; then
    emit RESULT fail
    emit SUMMARY "$(printf "$(t sum_unsupported)" "$v")"
    exit 1
  fi

  report_procs

  # 1. Сначала вежливое закрытие, через две секунды выжившим — принудительное.
  if [ -n "${STALE// /}" ]; then
    echo
    head_ kill_head "$STALE"
    kill $STALE 2>/dev/null
    sleep 2
    survivors=""
    for p in $STALE; do
      kill -0 "$p" 2>/dev/null && survivors="$survivors $p"
    done
    if [ -n "${survivors// /}" ]; then
      step force "$survivors"
      kill -9 $survivors 2>/dev/null
    fi
    for p in $STALE; do kill -0 "$p" 2>/dev/null || killed=$((killed + 1)); done
    step closed "$killed"
  fi
  emit KILLED "$killed"

  # 2. Перезапуск самой службы AirDrop. Система поднимает sharingd автоматически,
  #    поэтому достаточно его закрыть и дождаться нового номера процесса.
  echo
  head_ restart_head
  old=$(pgrep -x sharingd)
  killall sharingd 2>/dev/null
  new=""; i=0
  while [ "$i" -lt 20 ]; do
    new=$(pgrep -x sharingd)
    [ -n "$new" ] && [ "$new" != "$old" ] && break
    sleep 0.5
    i=$((i + 1))
  done
  if [ -n "$new" ] && [ "$new" != "$old" ]; then
    step service_back; emit SHARINGD restarted
  else
    step service_fail; emit SHARINGD failed
  fi

  # 3. Finder — по запросу. Окна Finder закроются, рабочий стол моргнёт.
  if [ "$RESTART_FINDER" -eq 1 ]; then
    echo
    head_ finder_head
    if killall Finder 2>/dev/null; then step finder_ok; emit FINDER restarted
    else step finder_absent; emit FINDER absent; fi
  fi

  # 4. awdl0 — интерфейс, на котором AirDrop ищет устройства. Лечит «Mac не видит
  #    iPhone». Требует прав администратора, поэтому запрос идёт через системное
  #    окно ввода пароля, а не через sudo в терминале.
  if [ "$RESTART_WIFI" -eq 1 ]; then
    echo
    head_ wifi_head
    if osascript -e 'do shell script "/sbin/ifconfig awdl0 down; sleep 1; /sbin/ifconfig awdl0 up" with administrator privileges' >/dev/null 2>&1; then
      step wifi_ok; emit AWDL restarted
    else
      step wifi_fail; emit AWDL failed
    fi
  fi

  echo
  head_ state_head
  step visible_to "$(defaults read com.apple.sharingd DiscoverableMode 2>/dev/null || t not_set)"
  if ifconfig awdl0 2>/dev/null | head -1 | grep -q RUNNING; then
    step wifi_state "$(t wifi_on)"
  else
    step wifi_state "$(t wifi_off)"
  fi
  echo
  head_ finally

  emit RESULT ok
  if [ "$killed" -gt 0 ]; then
    emit SUMMARY "$(printf "$(t sum_fixed)" "$killed")"
  else
    emit SUMMARY "$(t sum_nothing)"
  fi
}

case "$CMD" in
  check)    do_check    ;;
  list)     do_list     ;;
  fix)      do_fix      ;;
  selftest) do_selftest ;;
  *) echo "usage: $(basename "$0") {check|list|fix|selftest} [--finder] [--wifi] [--age N] [--lang ru|en]"; exit 2 ;;
esac
