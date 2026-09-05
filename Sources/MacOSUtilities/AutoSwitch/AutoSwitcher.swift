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

    // MARK: Настройки

    @Published var isEnabled = false { didSet { save("autoSwitchEnabled", isEnabled); apply() } }
    @Published var autoMode = true   { didSet { save("autoSwitchAuto", autoMode); apply() } }
    @Published var skipTerminals = true { didSet { save("autoSwitchSkipTerminals", skipTerminals); apply() } }
    @Published var skipPasswordManagers = true { didSet { save("autoSwitchSkipPasswords", skipPasswordManagers); apply() } }
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

    /// Нажатия текущего слова. Очищаются на границе слова.
    private var buffer: [KeyPress] = []
    /// Последнее законченное слово и разделитель после него — чтобы горячее
    /// сочетание работало и после того, как пробел уже нажат.
    private var completed: (keys: [KeyPress], separator: String)?
    /// Что заменили в прошлый раз: повторное сочетание возвращает как было.
    private var undo: (inserted: String, original: String)?

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: "autoSwitchEnabled")
        autoMode = UserDefaults.standard.object(forKey: "autoSwitchAuto") as? Bool ?? true
        skipTerminals = UserDefaults.standard.object(forKey: "autoSwitchSkipTerminals") as? Bool ?? true
        skipPasswordManagers = UserDefaults.standard.object(forKey: "autoSwitchSkipPasswords") as? Bool ?? true
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
        monitor.autoEnabled = autoMode
        monitor.excludedBundleIDs = excludedIDs()

        if isEnabled && hasAccessibility {
            if !monitor.isRunning { _ = monitor.start() }
        } else if monitor.isRunning {
            monitor.stop()
        }
        isRunning = monitor.isRunning
    }

    private func excludedIDs() -> Set<String> {
        var ids: Set<String> = []
        if skipTerminals { ids.formUnion(Self.terminalsAndIDEs) }
        if skipPasswordManagers { ids.formUnion(Self.passwordManagers) }
        return ids
    }

    // MARK: Разбор сигналов

    private func handle(_ signal: KeyMonitor.Signal) {
        switch signal {
        case .letter(let press):
            buffer.append(press)
            completed = nil
            undo = nil

        case .erase:
            if !buffer.isEmpty { buffer.removeLast() } else { completed = nil }
            undo = nil

        case .reset:
            buffer = []
            completed = nil
            undo = nil

        case .separator:
            let keys = buffer
            buffer = []
            guard !keys.isEmpty else { completed = nil; return }
            // Разделитель ещё не дошёл до программы — обрабатываем следующим
            // тактом, когда он уже вставлен и курсор стоит за ним.
            DispatchQueue.main.async { [weak self] in
                self?.finishWord(keys)
            }

        case .hotkey:
            DispatchQueue.main.async { [weak self] in self?.manualFix() }
        }
    }

    /// Слово закончено: если автоматика включена — проверяем и правим.
    private func finishWord(_ keys: [KeyPress]) {
        completed = (keys, "")
        guard autoMode, let pair = layouts.pair, let current = layouts.current else { return }
        let other = current.id == pair.latin.id ? pair.cyrillic : pair.latin

        let typed = LayoutService.render(keys, in: current)
        let alternative = LayoutService.render(keys, in: other)
        guard checker.judge(typed: typed, alternative: alternative) == .wrongLayout else { return }

        // Стираем слово вместе с уже вставленным разделителем и печатаем заново.
        // Разделитель добавляем обратно тем же символом, каким он был набран.
        Corrector.replace(charactersBack: typed.count + 1, with: alternative + " ")
        layouts.select(other)
        undo = (inserted: alternative, original: typed)
        correctionCount += 1
        lastAction = "\(typed) → \(alternative)"
        completed = nil
    }

    /// Ручное исправление: выделение, если оно есть; иначе текущее или
    /// последнее слово. Повторное нажатие сразу после замены — возврат.
    private func manualFix() {
        if let undoPair = undo {
            Corrector.replace(charactersBack: undoPair.inserted.count, with: undoPair.original)
            undo = nil
            lastAction = "возврат: \(undoPair.original)"
            return
        }

        if let selection = Corrector.selectedText(), !selection.isEmpty {
            guard let converted = convertText(selection) else { return }
            Corrector.replace(charactersBack: 0, with: converted)
            correctionCount += 1
            lastAction = "выделение → \(converted.prefix(24))"
            return
        }

        guard let pair = layouts.pair, let current = layouts.current else { return }
        let other = current.id == pair.latin.id ? pair.cyrillic : pair.latin

        if !buffer.isEmpty {
            let typed = LayoutService.render(buffer, in: current)
            let alternative = LayoutService.render(buffer, in: other)
            Corrector.replace(charactersBack: typed.count, with: alternative)
            layouts.select(other)
            undo = (inserted: alternative, original: typed)
            correctionCount += 1
            lastAction = "\(typed) → \(alternative)"
        } else if let last = completed {
            let typed = LayoutService.render(last.keys, in: current)
            let alternative = LayoutService.render(last.keys, in: other)
            Corrector.replace(charactersBack: typed.count + 1, with: alternative + " ")
            layouts.select(other)
            undo = (inserted: alternative, original: typed)
            correctionCount += 1
            lastAction = "\(typed) → \(alternative)"
            completed = nil
        }
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
        UserDefaults.standard.set(value, forKey: key)
    }

    private func saveHotkey() {
        let d = UserDefaults.standard
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
        let d = UserDefaults.standard
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
        "com.sublimetext.4", "com.figma.Desktop",
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

        print(bad == 0 ? "PASS: проверок пройдено \(ok)" : "FAIL: провалено \(bad) из \(ok + bad)")
        return bad == 0
    }
}
