# MacOS Utilities

Три утилиты для macOS в одном окне: надёжное переключение раскладки по Caps Lock,
снятие зависшего AirDrop и режим «не давать Mac уснуть».

Приложение ничего не прячет. Каждый фикс — это обычный bash-скрипт с подробными
комментариями, который лежит внутри бандла; кнопка **«Показать весь скрипт»**
открывает ровно тот код, который будет выполнен. Ни один раздел не требует пароля
администратора — кроме одной опции, о которой сказано прямо в интерфейсе.

<p>
<img src="docs/screenshot-input-source.png" width="420" alt="Раздел «Переключение раскладки»">
<img src="docs/screenshot-keep-awake.png" width="420" alt="Раздел «Mac не уходит в сон»">
</p>

## Установка

1. Скачать `MacOS-Utilities-1.1.0.dmg` из [Releases](https://github.com/sipandk-art/macos-utilities/releases).
2. Открыть DMG, перетащить **MacOS Utilities** в **Applications**.
3. Запустить.

Сборки из релизов подписаны сертификатом Developer ID и нотаризованы Apple —
дополнительных действий не требуется. Если вы собрали приложение сами, без
сертификата, первый запуск идёт через правую кнопку по иконке → **Открыть** →
**Открыть**, а при жалобе «повреждено» помогает снятие карантина:

```bash
xattr -dr com.apple.quarantine "/Applications/MacOS Utilities.app"
```

Требуется macOS 13 (Ventura) или новее. Сборка универсальная: Apple Silicon и Intel.

## Что внутри

### 1. Переключение раскладки

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

**Откат.** Первый `apply` сохраняет прежнее состояние в
`~/Library/Application Support/MacOS Utilities/input-source-backup.json`. Кнопка
«Откатить» возвращает системный шорткат к прежнему значению, снимает ремап
и убирает LaunchAgent.

**Права администратора не нужны:** всё перечисленное — настройки текущего
пользователя.

### 2. Зависший AirDrop

Окно «Поделиться → AirDrop» рисует не Finder, а два его расширения:
`ShareSheetUI.appex` и `AirDrop.appex`. Бывает, что окно закрыли, а расширения
не вышли — процессы висят в системе неделями, держат отправляемый файл
отображённым в память и время от времени всплывают поверх других окон.

Раздел находит такие процессы по пути к бандлу расширения, показывает возраст
каждого и какой файл в нём застрял, снимает старые (`kill`, через две секунды
выжившим `kill -9`) и перезапускает `sharingd` — демон, который и есть служба
AirDrop; launchd поднимает его обратно сам.

Так выглядит поиск (`Только показать` в интерфейсе, `list` в терминале):

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
  Лечит «Mac не видит iPhone». **Единственное место, где нужен пароль
  администратора** — его спрашивает системное окно, не терминал.

### 3. Mac не уходит в сон

Одна большая кнопка. Во включённом состоянии Mac не засыпает по бездействию
и не рвёт сетевые соединения — долгая задача нейросети-агента или выгрузка
не оборвутся на середине.

Механизм — штатные power assertions IOKit, то же самое, что делает системная
утилита `caffeinate`: `PreventUserIdleSystemSleep` и `NetworkClientActive`.
Утверждение на дисплей сознательно не берётся, поэтому экран продолжает гаснуть
по системному таймеру — подсветка не тратится впустую, машина остаётся в работе.

Режим действует, пока приложение запущено. Состояние кнопки запоминается:
при следующем запуске режим включится сам.

## Сборка из исходников

```bash
git clone https://github.com/sipandk-art/macos-utilities.git
cd macos-utilities
./scripts/build-app.sh --dmg
```

Нужен Xcode или Command Line Tools со Swift 5.9+. Результат — `build/MacOS Utilities.app`
и `dist/MacOS-Utilities-1.1.0.dmg`.

Скрипты можно запускать и без приложения:

```bash
./Resources/Scripts/input-source-fix.sh check
./Resources/Scripts/airdrop-fix.sh list
```

### Подпись и нотаризация

По умолчанию скрипт сборки ставит ad-hoc подпись: приложение работает на своей
машине, но у скачавшего Gatekeeper выдаст предупреждение. Чтобы собрать сборку
для раздачи, нужны две вещи из платной учётной записи Apple Developer.

**Сертификат Developer ID Application.** Именно он, не «Apple Development» и не
«Apple Distribution» — те для отладки и для App Store. Создаётся на
[developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates)
кнопкой «+» → **Developer ID Application**. Нужна платная подписка Apple
Developer Program, и выпустить такой сертификат может только Account Holder —
роли Admin этого типа недоступны. Скачанный `.cer` открывается двойным кликом
и попадает в связку ключей. Число сертификатов Developer ID на аккаунт
ограничено, а приватный ключ существует в единственном экземпляре — сразу
выгрузите его из Keychain Access в `.p12` и положите в надёжное место,
иначе при потере машины подписывать обновления прежней личностью будет нечем.

Проверка:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

**Профиль для нотаризации.** Нотаризация — это отправка сборки в Apple на
автоматическую проверку; без неё Gatekeeper на чужой машине всё равно ругнётся.
Нужен пароль приложения: [appleid.apple.com](https://appleid.apple.com) →
«Вход и безопасность» → «Пароли приложений». Он один раз кладётся в связку ключей:

```bash
xcrun notarytool store-credentials notary \
  --apple-id "почта@apple.id" \
  --team-id ABCDE12345 \
  --password "xxxx-xxxx-xxxx-xxxx"
```

`ABCDE12345` — Team ID, он же в скобках в имени сертификата и на странице
Membership в аккаунте разработчика.

**Сборка:**

```bash
SIGN_ID="Developer ID Application: ВАШЕ ИМЯ (ABCDE12345)" \
NOTARY_PROFILE=notary \
./scripts/build-app.sh --dmg
```

Скрипт подпишет приложение с hardened runtime и меткой времени, соберёт DMG,
подпишет и его, отправит на нотаризацию, дождётся вердикта и прикрепит штамп
(`stapler staple`) — после этого DMG открывается на чужом Mac без предупреждений
и без интернета. Нотаризация занимает несколько минут.

Проверить готовый файл:

```bash
spctl -a -vvv -t install dist/MacOS-Utilities-1.1.0.dmg
```

Ожидаемый ответ — `accepted` и `source=Notarized Developer ID`.

### Структура

```
Sources/MacOSUtilities/    приложение на SwiftUI
Resources/Scripts/         bash-скрипты, которые приложение выполняет и показывает
scripts/build-app.sh       сборка .app и DMG
scripts/make-icon.swift    иконка рисуется кодом, а не картинкой
```

Приложение общается со скриптами через строки вида `@@КЛЮЧ=значение`: скрипт
печатает их в общий поток, приложение вынимает из журнала и рисует по ним
карточку диагностики. Всё остальное, что печатает скрипт, попадает
в раскрывающийся журнал выполнения как есть.

### Проверки

```bash
./Resources/Scripts/airdrop-fix.sh selftest   # разбор возраста процессов из ps
```

Разбор `etime` — единственная нетривиальная логика в скриптах (четыре формата:
`45`, `3:07`, `2:10:30`, `15-21:20:16`), она закрыта самопроверкой.

Режим `--snapshot <папка>` отрисовывает разделы в PNG — им сделаны скриншоты
в этом README:

```bash
./build/MacOS\ Utilities.app/Contents/MacOS/MacOSUtilities --snapshot docs/
```

## Чего приложение не делает

- Не отправляет никуда данные и не ходит в сеть.
- Не ставит фоновых агентов от своего имени. Единственный LaunchAgent —
  `com.user.capslock2f18` — ставится только по кнопке «Применить» в первом разделе
  и удаляется по кнопке «Откатить».
- Не требует прав администратора нигде, кроме опции «передёрнуть awdl0».

## Известные ограничения

- Приложение не в песочнице (App Sandbox): `hidutil`, `launchctl` и `defaults`
  из песочницы не работают, поэтому в Mac App Store его выложить нельзя —
  только прямой раздачей.
- Откат первого раздела возвращает системный шорткат и снимает ремап,
  но не восстанавливает произвольный прежний `UserKeyMapping`, если он был
  сложнее одного правила — HID-ремап снимается целиком.
- Режим «не спать» живёт, пока открыто приложение: это не фоновый демон.

## Лицензия

MIT — см. [LICENSE](LICENSE).

---

**English summary.** MacOS Utilities is a small macOS utility app bundling three fixes:
a reliable Caps Lock → input-source switcher (HID remap to F18 plus a system
shortcut, surviving reboots), a cleaner for stuck AirDrop share-sheet helper
processes with a `sharingd` restart, and a keep-awake toggle built on IOKit power
assertions that lets the display sleep while the system stays up. Every fix is a
commented bash script shipped inside the bundle and viewable from the UI before
you run it. No admin password is required except for the optional `awdl0` bounce.
