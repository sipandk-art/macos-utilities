# MacOS Utilities

Три утилиты для macOS в одном окне: надёжное переключение раскладки по Caps Lock,
снятие зависшего AirDrop и режим «не давать Mac уснуть».

<p>
<img src="docs/screenshot-input-source.png" width="420" alt="Раздел «Переключение раскладки»">
<img src="docs/screenshot-keep-awake.png" width="420" alt="Раздел «Mac не уходит в сон»">
</p>

Приложение ничего не прячет. Каждый фикс — обычный bash-скрипт с подробными
комментариями, который лежит внутри бандла; кнопка **«Показать весь скрипт»**
открывает ровно тот код, который будет выполнен. Права администратора нужны
ровно в одном месте, и об этом сказано прямо в интерфейсе.

## Установка

Скачать `MacOS-Utilities-1.1.0.dmg` из [Releases](https://github.com/sipandk-art/macos-utilities/releases),
открыть, перетащить **MacOS Utilities** в **Applications**.

macOS 13 (Ventura) и новее, Apple Silicon и Intel.

## Переключение раскладки

Штатная галка «Использовать Caps Lock для переключения раскладки» работает через
обработчик, который при быстром наборе теряет нажатия: печатаешь быстро — раскладка
не переключилась, половина слова ушла не в тот язык.

Фикс обходит этот путь целиком:

| Шаг | Что делается | Где живёт |
| --- | --- | --- |
| 1 | Caps Lock перекладывается на F18 в HID-слое | `hidutil property --set UserKeyMapping` |
| 2 | Ремап повторяется при каждом входе в систему | `~/Library/LaunchAgents/com.user.capslock2f18.plist` |
| 3 | На F18 вешается шорткат «предыдущий источник ввода» | `com.apple.symbolichotkeys`, ключ `60` |
| 4 | Если Caps Lock стоял в «Нет действия» — возвращается на место | `com.apple.keyboard.modifiermapping.*` |

Перед применением приложение проверяет версию macOS, число включённых раскладок
(меньше двух — переключать нечего) и хвосты от Karabiner-Elements.

**Откат.** Первое применение сохраняет прежнее состояние в
`~/Library/Application Support/MacOS Utilities/input-source-backup.json`. Кнопка
«Откатить» возвращает системный шорткат к прежнему значению, снимает ремап
и убирает LaunchAgent.

Права администратора не нужны: всё перечисленное — настройки текущего пользователя.

## Зависший AirDrop

Окно «Поделиться → AirDrop» рисует не Finder, а два его расширения:
`ShareSheetUI.appex` и `AirDrop.appex`. Бывает, что окно закрыли, а расширения
не вышли — процессы висят в системе неделями, держат отправляемый файл
отображённым в память и время от времени всплывают поверх других окон.

Раздел находит такие процессы по пути к бандлу расширения, показывает возраст
каждого и какой файл в нём застрял, снимает старые (`kill`, через две секунды
выжившим `kill -9`) и перезапускает `sharingd` — демон, который и есть служба
AirDrop; launchd поднимает его обратно сам.

Так выглядит поиск:

```
== Хелперы AirDrop (порог зависания 120с) ==
  95340   15д21ч   AirDrop        ЗАВИС
          застрял файл: /Users/you/Downloads/photos/IMG_4557.jpg
  95326   15д21ч   ShareSheetUI   ЗАВИС
  38712   14с      AirDrop        ok
```

Параметры:

- **порог зависания** — 30 секунд / 2 минуты / 10 минут / любой возраст.
  По умолчанию 2 минуты, чтобы не убить окно, которое вы открыли только что;
- **перезапустить Finder** — если окно AirDrop нарисовано, но не откликается.
  Перед запуском приложение предупреждает, что окна Finder закроются
  и рабочий стол перерисуется;
- **передёрнуть awdl0** — интерфейс, на котором AirDrop ищет устройства.
  Лечит «Mac не видит iPhone». Единственное место, где нужен пароль
  администратора — его спрашивает системное окно, не терминал.

## Mac не уходит в сон

Одна большая кнопка. Во включённом состоянии Mac не засыпает по бездействию
и не рвёт сетевые соединения — долгая задача нейросети-агента или выгрузка
не оборвутся на середине.

Механизм — штатные power assertions IOKit, то же самое, что делает системная
утилита `caffeinate`: `PreventUserIdleSystemSleep` и `NetworkClientActive`.
Утверждение на дисплей сознательно не берётся, поэтому экран продолжает гаснуть
по системному таймеру — подсветка не тратится впустую, машина остаётся в работе.

Режим действует, пока приложение запущено. Состояние кнопки запоминается:
при следующем запуске режим включится сам.

## Чего приложение не делает

- Не отправляет никуда данные и не ходит в сеть.
- Не ставит фоновых агентов от своего имени. Единственный LaunchAgent —
  `com.user.capslock2f18` — появляется только по кнопке «Применить» в первом
  разделе и удаляется по кнопке «Откатить».
- Не требует прав администратора нигде, кроме опции «передёрнуть awdl0».

## Сборка из исходников

```bash
git clone https://github.com/sipandk-art/macos-utilities.git
cd macos-utilities
./scripts/build-app.sh --dmg
```

Нужен Xcode или Command Line Tools со Swift 5.9+. Результат —
`build/MacOS Utilities.app` и `dist/MacOS-Utilities-1.1.0.dmg`.

Скрипты работают и сами по себе, без приложения:

```bash
./Resources/Scripts/input-source-fix.sh check
./Resources/Scripts/airdrop-fix.sh list
./Resources/Scripts/airdrop-fix.sh selftest
```

Устройство проекта, подпись и выпуск релиза — в [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Лицензия

MIT — см. [LICENSE](LICENSE).

---

**English summary.** MacOS Utilities bundles three macOS fixes in one window:
a reliable Caps Lock → input-source switcher (HID remap to F18 plus a system
shortcut, surviving reboots), a cleaner for stuck AirDrop share-sheet helper
processes with a `sharingd` restart, and a keep-awake toggle built on IOKit power
assertions that lets the display sleep while the system stays up. Every fix is a
commented bash script shipped inside the bundle and viewable from the UI before
you run it. No admin password is required except for the optional `awdl0` bounce.
