import AppKit
import Carbon
import ServiceManagement

/// Автопереключение раскладки: собирает слово из нажатий, на пробеле решает,
/// не набрано ли оно не в той раскладке, и если да — переписывает и переключает
/// язык. Плюс ручное исправление по горячему сочетанию.
///
/// Накопленное слово живёт только до ближайшего пробела и нигде не сохраняется:
/// ни файла, ни истории, ни отправки — именно этим программа отличается
/// от закрытых аналогов с «дневником нажатий».
@MainActor
final class AutoSwitcher: ObservableObject {

    static let shared = AutoSwitcher()

    /// `--trace`: печатает в stderr, что видит перехватчик и какое решение
    /// принимает. Нужен, чтобы отличать «не долетели нажатия» от «долетели,
    /// но решили не трогать» — без него причина сбоя в чужой программе
    /// не отличима на глаз.
    static let tracing = CommandLine.arguments.contains("--trace")

    private func trace(_ text: @autoclosure () -> String) {
        guard Self.tracing else { return }
        FileHandle.standardError.write(Data(("[trace] " + text() + "\n").utf8))
    }

    // MARK: Настройки

    @Published var isEnabled = false { didSet { save("autoSwitchEnabled", isEnabled); apply() } }
    @Published var autoMode = true   { didSet { save("autoSwitchAuto", autoMode); apply() } }
    @Published var skipTerminals = true { didSet { save("autoSwitchSkipTerminals", skipTerminals); apply() } }
    @Published var skipPasswordManagers = true { didSet { save("autoSwitchSkipPasswords", skipPasswordManagers); apply() } }
    @Published var skipBrowsers = false { didSet { save("autoSwitchSkipBrowsers", skipBrowsers); apply() } }
    @Published var launchAtLogin = false { didSet { setLaunchAtLogin(launchAtLogin) } }
    @Published var hotkey: KeyMonitor.Hotkey = .doubleShift { didSet { saveHotkey(); apply() } }

    // MARK: Состояние для интерфейса

    @Published private(set) var isRunning = false
    @Published private(set) var lastAction: String?
    @Published private(set) var correctionCount = 0
    @Published private(set) var hasAccessibility = false
    @Published private(set) var hasInputMonitoring = false

    let layouts = LayoutService()
    private let checker = WordChecker()
    private let monitor = KeyMonitor()

    /// Всё, что набрано подряд под текущим курсором: буквы и разделители между
    /// ними. Очищается, как только курсор уходит — клик мышью, стрелки, Enter,
    /// переключение программы. Ничего не сохраняется и не покидает память.
    private var run: [KeyPress] = []
    /// Ограничение на длину: правка стирает набранное посимвольно, и на очень
    /// длинном куске это заметная пачка нажатий. Хвост важнее начала.
    private let runLimit = 240
    /// Что заменили в прошлый раз: повторное сочетание возвращает как было.
    private var undo: (inserted: String, original: String)?

    init() {
        isEnabled = AppDefaults.store.bool(forKey: "autoSwitchEnabled")
        autoMode = AppDefaults.store.object(forKey: "autoSwitchAuto") as? Bool ?? true
        skipTerminals = AppDefaults.store.object(forKey: "autoSwitchSkipTerminals") as? Bool ?? true
        skipPasswordManagers = AppDefaults.store.object(forKey: "autoSwitchSkipPasswords") as? Bool ?? true
        skipBrowsers = AppDefaults.store.bool(forKey: "autoSwitchSkipBrowsers")
        loadHotkey()
        monitor.onSignal = { [weak self] in self?.handle($0) }
    }

    /// Вызывается после первой отрисовки: чтение разрешений и запуск перехвата
    /// меняют @Published, а делать это внутри init нельзя — SwiftUI считает
    /// это правкой состояния во время обновления вида.
    func bootstrap() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshPermissions()
        apply()
    }

    func refreshPermissions() {
        hasAccessibility = Permissions.hasAccessibility
        hasInputMonitoring = Permissions.hasInputMonitoring
    }

    // MARK: Запуск и остановка

    private func apply() {
        monitor.hotkey = hotkey
        monitor.excludedBundleIDs = excludedIDs()

        if isEnabled && hasAccessibility {
            if !monitor.isRunning {
                let started = monitor.start()
                trace(started ? "перехват запущен" : "перехват НЕ запустился")
            }
        } else if monitor.isRunning {
            monitor.stop()
        }
        isRunning = monitor.isRunning
    }

    /// Отдельно от `excludedIDs`, чтобы список можно было собрать и проверить
    /// без запущенного перехвата — этим пользуется самопроверка.
    static func excluded(terminals: Bool, passwords: Bool, browsers: Bool) -> Set<String> {
        var ids: Set<String> = []
        if terminals { ids.formUnion(terminalsAndIDEs) }
        if passwords { ids.formUnion(passwordManagers) }
        if browsers { ids.formUnion(Self.browsers) }
        return ids
    }

    private func excludedIDs() -> Set<String> {
        return Self.excluded(terminals: skipTerminals,
                             passwords: skipPasswordManagers,
                             browsers: skipBrowsers)
    }

    // MARK: Разбор сигналов

    private func handle(_ signal: KeyMonitor.Signal) {
        switch signal {
        case .char(let press):
            append(press)
            undo = nil

        case .erase:
            if !run.isEmpty { run.removeLast() }
            undo = nil

        case .reset:
            trace("сброс")
            run = []
            undo = nil

        case .space(let press):
            let word = trailingWord()
            append(press)
            undo = nil
            guard !word.isEmpty else { return }
            // Пробел ещё не дошёл до программы — обрабатываем следующим тактом,
            // когда он уже вставлен и курсор стоит за ним.
            DispatchQueue.main.async { [weak self] in
                self?.finishWord(word)
            }

        case .hotkey:
            trace("горячее сочетание")
            DispatchQueue.main.async { [weak self] in self?.manualFix() }
        }
    }

    private func append(_ press: KeyPress) {
        run.append(press)
        if run.count > runLimit { run.removeFirst(run.count - runLimit) }
    }

    /// Всё, что набрано после последнего пробела, — «последнее слово»,
    /// вместе со знаками внутри и по краям.
    private func trailingWord() -> [KeyPress] {
        var word: [KeyPress] = []
        for press in run.reversed() {
            guard !press.isSpace else { break }
            word.insert(press, at: 0)
        }
        return word
    }

    /// Слово закончено: если автоматика включена — проверяем и правим.
    private func finishWord(_ keys: [KeyPress]) {
        guard autoMode else { trace("автоматика выключена"); return }
        guard let pair = layouts.pair else { trace("нет пары раскладок"); return }
        guard let current = layouts.current else { trace("текущая раскладка не определена"); return }
        let other = current.id == pair.latin.id ? pair.cyrillic : pair.latin

        let typed = LayoutService.render(keys, in: current)
        let alternative = LayoutService.render(keys, in: other)
        let verdict = checker.judge(typed: typed, alternative: alternative)
        trace("слово «\(typed)» / «\(alternative)» → \(verdict == .wrongLayout ? "правим" : "не трогаем")")
        guard verdict == .wrongLayout else { return }

        // Стираем слово вместе с уже вставленным пробелом и печатаем заново.
        // Знаки внутри слова переписываются той же клавишей в другой раскладке:
        // «ghbdtn?» становится «привет,», потому что «?» и «,» — одна клавиша.
        Corrector.replace(charactersBack: typed.count + 1, with: alternative + " ")
        layouts.select(other)
        // В возврат кладём и пробел: на экране сейчас «привет |», и без него
        // возврат стёр бы пробел вместе с частью слова.
        undo = (inserted: alternative + " ", original: typed + " ")
        correctionCount += 1
        lastAction = "\(typed) → \(alternative)"
        // На экране теперь текст в другой раскладке, а накопленные нажатия
        // соответствуют прежней. Сопоставлять их больше нельзя — начинаем заново.
        run = []
    }

    /// Ручное исправление. Порядок: выделенный текст, если он есть; иначе
    /// хвост набранного. Повторное нажатие сразу после замены — возврат.
    private func manualFix() {
        if let undoPair = undo {
            Corrector.replace(charactersBack: undoPair.inserted.count, with: undoPair.original)
            undo = nil
            run = []
            lastAction = "возврат: \(undoPair.original)"
            return
        }

        if let selection = Corrector.selectedText(), !selection.isEmpty {
            guard let converted = convertText(selection) else { return }
            Corrector.replace(charactersBack: 0, with: converted)
            correctionCount += 1
            run = []
            lastAction = "выделение → \(converted.prefix(24))"
            return
        }

        guard let pair = layouts.pair, let current = layouts.current else { return }
        let other = current.id == pair.latin.id ? pair.cyrillic : pair.latin

        let tail = tailToFix(in: current)
        guard !tail.isEmpty else { trace("нечего исправлять"); return }

        let typed = LayoutService.render(tail, in: current)
        let alternative = LayoutService.render(tail, in: other)
        trace("вручную: «\(typed)» → «\(alternative)»")
        Corrector.replace(charactersBack: typed.count, with: alternative)
        layouts.select(other)
        undo = (inserted: alternative, original: typed)
        correctionCount += 1
        run = []
        lastAction = "\(typed) → \(alternative)"
    }

    /// Что взять в ручную правку, когда ничего не выделено: последнее слово
    /// до пробела — вместе со знаками — и пробелы после него. Несколько слов
    /// разом сознательно не берём: для этого есть выделение, там границы
    /// задаёт человек, а не догадка программы.
    private func tailToFix(in current: LayoutService.Layout) -> [KeyPress] {
        guard !run.isEmpty else { return [] }
        var start: Int? = nil
        var index = run.count - 1
        while index >= 0, run[index].isSpace { index -= 1 }            // хвостовые пробелы
        while index >= 0, !run[index].isSpace { start = index; index -= 1 }
        guard let from = start else { return [] }
        return Array(run[from...])
    }

    /// Посимвольный перевод готового текста между раскладками — для выделения,
    /// где нажатий у нас нет, есть только сам текст.
    func convertText(_ text: String) -> String? {
        guard let pair = layouts.pair else { return nil }
        let fromCyrillic = LayoutService.script(of: text) == .cyrillic
        let from = fromCyrillic ? pair.cyrillic : pair.latin
        let to   = fromCyrillic ? pair.latin : pair.cyrillic
        let map = Self.charMap(from: from, to: to)
        return String(text.map { map[$0] ?? $0 })
    }

    /// Таблица «символ в одной раскладке → символ в другой», собранная опросом
    /// системы по всем кодам клавиш. Хардкода соответствий в приложении нет.
    static func charMap(from: LayoutService.Layout, to: LayoutService.Layout) -> [Character: Character] {
        var map: [Character: Character] = [:]
        for keycode in UInt16(0)...127 {
            for shift in [false, true] {
                guard let a = LayoutService.translate(source: from.source, keycode: keycode, shift: shift),
                      let b = LayoutService.translate(source: to.source, keycode: keycode, shift: shift),
                      let ca = a.first, let cb = b.first, a.count == 1, b.count == 1,
                      ca.isLetter || cb.isLetter else { continue }
                map[ca] = cb
            }
        }
        return map
    }

    // MARK: Автозапуск

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            lastAction = "автозапуск: \(error.localizedDescription)"
        }
    }

    // MARK: Хранение настроек

    private func save(_ key: String, _ value: Bool) {
        AppDefaults.store.set(value, forKey: key)
    }

    private func saveHotkey() {
        let d = AppDefaults.store
        switch hotkey {
        case .doubleShift:
            d.set("doubleShift", forKey: "autoSwitchHotkeyKind")
        case .combo(let keycode, let flags):
            d.set("combo", forKey: "autoSwitchHotkeyKind")
            d.set(Int(keycode), forKey: "autoSwitchHotkeyCode")
            d.set(Int(flags.rawValue), forKey: "autoSwitchHotkeyFlags")
        }
    }

    private func loadHotkey() {
        let d = AppDefaults.store
        guard d.string(forKey: "autoSwitchHotkeyKind") == "combo" else { hotkey = .doubleShift; return }
        let code = UInt16(d.integer(forKey: "autoSwitchHotkeyCode"))
        let flags = CGEventFlags(rawValue: UInt64(d.integer(forKey: "autoSwitchHotkeyFlags")))
        hotkey = .combo(keycode: code, flags: flags)
    }

    // MARK: Списки исключений

    static let terminalsAndIDEs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "io.alacritty", "com.mitchellh.ghostty",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.apple.dt.Xcode",
        "com.todesktop.230313mzl4w4u92",                       // Cursor
        "com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.pycharm",
        "com.jetbrains.WebStorm", "com.jetbrains.goland", "com.jetbrains.rider",
    ]

    /// Браузеры. Отдельным списком и по умолчанию выключены: поле пароля
    /// на веб-странице определить нельзя — ни Safari, ни Chrome не включают
    /// системный «защищённый ввод» и не показывают такие поля системе
    /// доступности (проверено). Кому это важно, отключает браузеры целиком.
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.google.Chrome.canary",
        "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.Browser",                          // Arc
        "com.operasoftware.Opera", "ru.yandex.desktop.yandex-browser",
        "com.vivaldi.Vivaldi",
    ]

    static let passwordManagers: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword",
        "com.bitwarden.desktop", "org.keepassxc.keepassxc", "com.lastpass.LastPass",
        "in.sinew.Enpass-Desktop", "com.dashlane.dashlanephonefinal",
        "com.apple.keychainaccess",
    ]

    // MARK: Самопроверка

    /// Прогон решающей логики на заведомо известных парах. Здесь два нетривиальных
    /// места: перевод нажатий через системную раскладку и поправка на то, что
    /// английский словарь macOS считает любую кириллицу правильным словом.
    static func selftest() -> Bool {
        let service = LayoutService()
        guard let pair = service.pair else {
            print("FAIL: нужны две раскладки — латинская и кириллическая")
            return false
        }
        let checker = WordChecker()
        var ok = 0, bad = 0

        // Коды клавиш слова, набранного на латинской клавиатуре, и то,
        // что те же клавиши дают в кириллической раскладке.
        let cases: [(codes: [UInt16], latin: String, cyrillic: String, verdict: WordChecker.Verdict)] = [
            ([5, 4, 11, 2, 17, 45],          "ghbdtn", "привет",    .wrongLayout),
            ([4, 14, 37, 37, 31],            "hello",  "руддщ",     .leaveAlone),
        ]
        for c in cases {
            let latin = LayoutService.render(c.codes.map { KeyPress(keycode: $0, shift: false) }, in: pair.latin)
            let cyr = LayoutService.render(c.codes.map { KeyPress(keycode: $0, shift: false) }, in: pair.cyrillic)
            let verdictLatinTyped = checker.judge(typed: latin, alternative: cyr)
            let renderOK = latin == c.latin && cyr == c.cyrillic
            let verdictOK = verdictLatinTyped == c.verdict
            if renderOK && verdictOK { ok += 1 } else {
                bad += 1
                print("FAIL: \(c.latin)/\(c.cyrillic) -> получили \(latin)/\(cyr), вердикт \(verdictLatinTyped)")
            }
        }

        // Ловушка: английский словарь пропускает кириллицу как «правильную».
        // Проверяем, что поправка на письменность её ловит.
        if checker.isRealWord("ъъъъъ") { bad += 1; print("FAIL: «ъъъъъ» признано словом") } else { ok += 1 }
        if !checker.isRealWord("привет") { bad += 1; print("FAIL: «привет» не признано словом") } else { ok += 1 }

        // Посимвольный перевод выделенного текста.
        let map = charMap(from: pair.latin, to: pair.cyrillic)
        let converted = String("ghbdtn".map { map[$0] ?? $0 })
        if converted == "привет" { ok += 1 } else { bad += 1; print("FAIL: таблица символов дала \(converted)") }

        // Слова целиком до пробела. Семь русских букв сидят на клавишах, которые
        // в латинице — знаки препинания, и раньше слово рвалось на них.
        // (код клавиши, Shift) → что должно получиться и что решить.
        func press(_ spec: [(UInt16, Bool)]) -> [KeyPress] {
            spec.map { KeyPress(keycode: $0.0, shift: $0.1) }
        }
        let n = false, S = true
        let wholeWords: [(name: String, keys: [KeyPress], from: LayoutService.Layout,
                          to: LayoutService.Layout, expect: String, verdict: WordChecker.Verdict)] = [
            ("это",       press([(39,n),(45,n),(38,n)]),                        pair.latin, pair.cyrillic, "это", .wrongLayout),
            ("хорошо",    press([(33,n),(38,n),(4,n),(38,n),(34,n),(38,n)]),    pair.latin, pair.cyrillic, "хорошо", .wrongLayout),
            ("будет",     press([(43,n),(14,n),(37,n),(17,n),(45,n)]),          pair.latin, pair.cyrillic, "будет", .wrongLayout),
            ("сообщение", press([(8,n),(38,n),(38,n),(43,n),(31,n),(17,n),(16,n),(11,n),(17,n)]),
                                                                                pair.latin, pair.cyrillic, "сообщение", .wrongLayout),
            ("что-то",    press([(7,n),(45,n),(38,n),(27,n),(45,n),(38,n)]),    pair.latin, pair.cyrillic, "что-то", .wrongLayout),
            ("привет,",   press([(5,n),(4,n),(11,n),(2,n),(17,n),(45,n),(44,S)]),
                                                                                pair.latin, pair.cyrillic, "привет,", .wrongLayout),
            ("Хорошо",    press([(33,S),(38,n),(4,n),(38,n),(34,n),(38,n)]),    pair.latin, pair.cyrillic, "Хорошо", .wrongLayout),
            ("what's",    press([(13,n),(4,n),(0,n),(17,n),(39,n),(1,n)]),      pair.cyrillic, pair.latin, "what's", .wrongLayout),
            // Трогать нельзя: правильное слово со знаком, сокращение, цифры.
            ("hello,",    press([(4,n),(14,n),(37,n),(37,n),(31,n),(43,n)]),    pair.latin, pair.cyrillic, "руддщб", .leaveAlone),
            ("it's",      press([(34,n),(17,n),(39,n),(1,n)]),                  pair.latin, pair.cyrillic, "шеэы", .leaveAlone),
            ("ghbdtn1",   press([(5,n),(4,n),(11,n),(2,n),(17,n),(45,n),(18,n)]),
                                                                                pair.latin, pair.cyrillic, "привет1", .leaveAlone),
        ]
        for c in wholeWords {
            let typed = LayoutService.render(c.keys, in: c.from)
            let alternative = LayoutService.render(c.keys, in: c.to)
            let verdict = checker.judge(typed: typed, alternative: alternative)
            if alternative == c.expect && verdict == c.verdict { ok += 1 }
            else {
                bad += 1
                print("FAIL: «\(c.name)»: набрано «\(typed)», вариант «\(alternative)», вердикт \(verdict)")
            }
        }

        // Короткие слова. Порог опущен до трёх букв, и здесь проверяется обе
        // стороны сделки: что короткие слова теперь правятся и что при этом
        // не начали портиться сокращения и обычные слова обоих языков.
        let toLatin = charMap(from: pair.cyrillic, to: pair.latin)
        let toCyrillic = charMap(from: pair.latin, to: pair.cyrillic)
        func flip(_ s: String) -> String {
            LayoutService.script(of: s) == .cyrillic
                ? String(s.map { toLatin[$0] ?? $0 })
                : String(s.map { toCyrillic[$0] ?? $0 })
        }
        func verdict(_ s: String) -> WordChecker.Verdict {
            checker.judge(typed: s, alternative: flip(s))
        }

        for typed in ["црн", "црщ", "рщц", "нуы"] {          // why, who, how, yes
            if verdict(typed) == .wrongLayout { ok += 1 }
            else { bad += 1; print("FAIL: «\(typed)» должно было стать «\(flip(typed))»") }
        }

        let mustNotTouch = [
            "png", "jpg", "svg", "css", "sql", "xml", "yml", "npm", "git", "ssh",
            "api", "url", "pdf", "zip", "env", "tmp", "lib", "src", "app", "div",
            "как", "что", "для", "они", "мне", "год", "при", "под", "над", "три",
            "the", "and", "for", "you", "not", "but", "are", "was", "who", "why",
        ]
        let touched = mustNotTouch.filter { verdict($0) == .wrongLayout }
        if touched.isEmpty { ok += 1 }
        else { bad += 1; print("FAIL: тронуло то, что трогать нельзя: \(touched.joined(separator: ", "))") }

        // Списки исключений: галки должны включать и выключать ровно свои группы,
        // и ни одна группа не должна протекать в чужую.
        let none = excluded(terminals: false, passwords: false, browsers: false)
        let onlyBrowsers = excluded(terminals: false, passwords: false, browsers: true)
        let defaults = excluded(terminals: true, passwords: true, browsers: false)
        let checks: [(String, Bool)] = [
            ("без галок список пуст", none.isEmpty),
            ("браузеры включаются галкой", onlyBrowsers.contains("com.apple.Safari")
                                        && onlyBrowsers.contains("com.google.Chrome")),
            ("по умолчанию браузеры не исключены", !defaults.contains("com.apple.Safari")),
            ("по умолчанию терминал исключён", defaults.contains("com.apple.Terminal")),
            ("по умолчанию менеджер паролей исключён", defaults.contains("com.1password.1password")),
            ("Sublime Text больше не в списке", !terminalsAndIDEs.contains("com.sublimetext.4")),
            ("Figma больше не в списке", !terminalsAndIDEs.contains("com.figma.Desktop")),
            ("группы не пересекаются", terminalsAndIDEs.isDisjoint(with: Self.browsers)
                                    && passwordManagers.isDisjoint(with: Self.browsers)),
        ]
        for (name, passed) in checks {
            if passed { ok += 1 } else { bad += 1; print("FAIL: \(name)") }
        }

        let clip = ClipboardHistory.selftest()
        ok += clip.ok
        bad += clip.bad

        print(bad == 0 ? "PASS: проверок пройдено \(ok)" : "FAIL: провалено \(bad) из \(ok + bad)")
        return bad == 0
    }
}
