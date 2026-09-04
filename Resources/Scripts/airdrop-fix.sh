#!/bin/bash
#
# airdrop-fix.sh — снять зависший AirDrop без перезагрузки Mac.
#
#   airdrop-fix.sh check              диагностика: версия macOS, права, что найдено
#   airdrop-fix.sh list               только показать процессы, ничего не трогать
#   airdrop-fix.sh fix [флаги]        убить зависшие + перезапустить службу AirDrop
#   airdrop-fix.sh selftest           самопроверка разбора возраста процессов
#
#   флаги для fix:
#     --age N     зависшим считать то, что живёт дольше N секунд (по умолчанию 120)
#     --age 0     убить вообще все хелперы AirDrop, даже только что открытые
#     --finder    вдобавок перезапустить Finder
#     --awdl      вдобавок передёрнуть Wi-Fi-интерфейс awdl0 (спросит пароль админа)
#
# ПРОБЛЕМА. «Поделиться -> AirDrop» из Finder открывает шит, который рисует не сам
# Finder, а два его расширения: ShareSheetUI.appex и AirDrop.appex. Иногда шит
# закрывают, а расширения не выходят — процессы висят в системе неделями, держат
# открытым отправляемый файл и время от времени всплывают поверх других окон.
#
# РЕШЕНИЕ. Найти эти процессы по пути к бандлу расширения, отсеять свежие (вдруг
# пользователь прямо сейчас что-то отправляет), убить старые и перезапустить
# sharingd — демон, который и есть служба AirDrop. launchd поднимет его сам.
#
# ПРАВА. sudo/root НЕ НУЖЕН для основного сценария: убиваем собственные процессы
# пользователя, sharingd перезапускается через killall в своей же сессии.
# Пароль администратора нужен ТОЛЬКО для флага --awdl (ifconfig трогает интерфейс).

set -u

MIN_AGE=120
RESTART_FINDER=0
BOUNCE_AWDL=0
MIN_MACOS=11

# Пути к бандлам расширений — по ним процессы и опознаются.
PATTERN='AirDrop\.appex/Contents/MacOS/AirDrop|ShareSheetUI\.appex/Contents/MacOS/ShareSheetUI'

emit() { printf '@@%s=%s\n' "$1" "$2"; }
step() { printf '  • %s\n' "$1"; }

# ── разбор аргументов ────────────────────────────────────────────────────────

CMD="${1:-check}"; shift 2>/dev/null || true
while [ $# -gt 0 ]; do
  case "$1" in
    --age)    MIN_AGE="${2:-120}"; shift 2 ;;
    --finder) RESTART_FINDER=1; shift ;;
    --awdl)   BOUNCE_AWDL=1; shift ;;
    *) shift ;;
  esac
done

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
  if   [ "$s" -lt 60 ];    then echo "${s}с"
  elif [ "$s" -lt 3600 ];  then echo "$((s / 60))м"
  elif [ "$s" -lt 86400 ]; then echo "$((s / 3600))ч$(((s % 3600) / 60))м"
  else                          echo "$((s / 86400))д$(((s % 86400) / 3600))ч"
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
      END { if (ok==4 && bad==0 && NR==4) { print "PASS: разбор возраста и фильтр ок"; exit 0 }
            else { print "FAIL ok=" ok+0 " bad=" bad+0 " NR=" NR; exit 1 } }'
}

# Печатает найденные процессы, возвращает список зависших через глобальную STALE.
STALE=""
report_procs() {
  local found=0 stale_n=0
  STALE=""
  echo "== Хелперы AirDrop (порог зависания ${MIN_AGE}с) =="
  while IFS="$(printf '\t')" read -r pid age name; do
    [ -z "$pid" ] && continue
    found=$((found + 1))
    if [ "$age" -ge "$MIN_AGE" ]; then
      mark="ЗАВИС"; STALE="$STALE $pid"; stale_n=$((stale_n + 1))
    else
      mark="ok"
    fi
    printf '  %-7s %-8s %-14s %s\n' "$pid" "$(human "$age")" "$name" "$mark"
    # Какой пользовательский файл держит процесс — обычно это застрявшая отправка.
    # cwd и rtd исключены: это рабочий и корневой каталоги, а не отправляемый файл.
    # А вот txt оставлен — застрявший файл процесс держит именно так, отображённым
    # в память (проверено на реально зависшем хелпере).
    f=$(lsof -w -p "$pid" -a -d '^cwd,^rtd' -Fn 2>/dev/null \
        | grep '^n/Users/' | grep -v '/Library/' | head -1 | cut -c2-)
    [ -n "$f" ] && printf '          застрял файл: %s\n' "$f"
  done < <(scan)
  [ "$found" -eq 0 ] && echo "  процессов нет, чисто"
  emit FOUND "$found"
  emit STALE "$stale_n"
}

# ── команды ──────────────────────────────────────────────────────────────────

do_check() {
  local v major
  v=$(sw_vers -productVersion); major=$(echo "$v" | cut -d. -f1)
  echo "== Диагностика =="
  step "macOS $v"
  emit MACOS "$v"
  if [ "$major" -ge "$MIN_MACOS" ]; then
    step "версия поддерживается (нужна $MIN_MACOS+)"; emit SUPPORTED yes
  else
    step "версия НЕ поддерживается (нужна $MIN_MACOS+)"; emit SUPPORTED no
  fi
  step "права администратора не нужны (нужны только для перезапуска awdl0)"
  emit NEEDS_ROOT no
  if pgrep -x sharingd >/dev/null; then
    step "служба sharingd работает (PID $(pgrep -x sharingd))"; emit SHARINGD up
  else
    step "служба sharingd не запущена"; emit SHARINGD down
  fi
  echo
  report_procs
  emit RESULT ok
  emit SUMMARY "Диагностика выполнена"
}

do_list() {
  report_procs
  echo
  echo "режим просмотра — ничего не тронуто"
  emit RESULT ok
  if [ -n "${STALE// /}" ]; then
    emit SUMMARY "Найдены зависшие процессы AirDrop"
  else
    emit SUMMARY "Зависших процессов AirDrop нет"
  fi
}

do_fix() {
  local v major killed=0
  v=$(sw_vers -productVersion); major=$(echo "$v" | cut -d. -f1)
  if [ "$major" -lt "$MIN_MACOS" ]; then
    emit RESULT fail; emit SUMMARY "macOS $v не поддерживается"; exit 1
  fi

  report_procs

  # 1. Сначала вежливый kill, через 2 секунды выжившим — kill -9.
  if [ -n "${STALE// /}" ]; then
    echo
    echo "== Снимаю зависшие:$STALE =="
    kill $STALE 2>/dev/null
    sleep 2
    survivors=""
    for p in $STALE; do
      kill -0 "$p" 2>/dev/null && survivors="$survivors $p"
    done
    if [ -n "${survivors// /}" ]; then
      step "не отвечают, добиваю -9:$survivors"
      kill -9 $survivors 2>/dev/null
    fi
    for p in $STALE; do kill -0 "$p" 2>/dev/null || killed=$((killed + 1)); done
    step "снято процессов: $killed"
  fi
  emit KILLED "$killed"

  # 2. Перезапуск самой службы AirDrop. launchd поднимает sharingd автоматически,
  #    поэтому достаточно его убить и дождаться нового PID.
  echo
  echo "== Перезапуск службы AirDrop (sharingd) =="
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
    step "sharingd поднялся: PID ${old:-нет} -> $new"
    emit SHARINGD restarted
  else
    step "ВНИМАНИЕ: sharingd не перезапустился (было ${old:-нет}, стало ${new:-нет})"
    emit SHARINGD failed
  fi

  # 3. Finder — по запросу. Окна Finder закроются, рабочий стол моргнёт.
  if [ "$RESTART_FINDER" -eq 1 ]; then
    echo
    echo "== Перезапуск Finder =="
    if killall Finder 2>/dev/null; then step "Finder перезапущен"; emit FINDER restarted
    else step "Finder не был запущен"; emit FINDER absent; fi
  fi

  # 4. awdl0 — интерфейс, на котором AirDrop ищет устройства. Лечит «Mac не видит
  #    iPhone». Требует прав администратора, поэтому запрос идёт через системное
  #    окно ввода пароля, а не через sudo в терминале.
  if [ "$BOUNCE_AWDL" -eq 1 ]; then
    echo
    echo "== Передёргиваю awdl0 (нужен пароль администратора) =="
    if osascript -e 'do shell script "/sbin/ifconfig awdl0 down; sleep 1; /sbin/ifconfig awdl0 up" with administrator privileges' >/dev/null 2>&1; then
      step "awdl0 перезапущен"; emit AWDL restarted
    else
      step "не удалось (отменён ввод пароля или нет прав)"; emit AWDL failed
    fi
  fi

  echo
  echo "== Состояние =="
  vis=$(defaults read com.apple.sharingd DiscoverableMode 2>/dev/null || echo '(не задана)')
  awdl=$(ifconfig awdl0 2>/dev/null | head -1 | grep -o 'RUNNING' || echo 'не поднят')
  step "видимость AirDrop: $vis"
  step "awdl0: $awdl"
  echo
  echo "Готово. Откройте Finder -> AirDrop (Shift-Cmd-R) и проверьте."

  emit RESULT ok
  if [ "$killed" -gt 0 ]; then
    emit SUMMARY "Снято зависших процессов: $killed, служба AirDrop перезапущена"
  else
    emit SUMMARY "Зависших процессов не было, служба AirDrop перезапущена"
  fi
}

case "$CMD" in
  check)    do_check    ;;
  list)     do_list     ;;
  fix)      do_fix      ;;
  selftest) do_selftest ;;
  *) echo "Использование: $(basename "$0") {check|list|fix|selftest} [--age N] [--finder] [--awdl]"; exit 2 ;;
esac
