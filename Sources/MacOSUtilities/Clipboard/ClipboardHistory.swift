import AppKit
import Carbon

/// Одна запись истории буфера обмена.
struct ClipItem: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String
    var date: Date
    /// Из какой программы скопировали — чтобы в списке было понятно, откуда запись.
    var app: String?
    /// Закреплённые записи не вытесняются новыми и живут, пока их не открепят.
    var pinned: Bool
}

/// История буфера обмена.
///
/// macOS не сообщает об изменении буфера, поэтому раз в полсекунды проверяется
/// его счётчик изменений — так делают все менеджеры буфера. Записывается только
/// текст. Пароли не записываются: менеджеры паролей помечают скопированное
/// специальными типами (`org.nspasteboard.ConcealedType` и подобными), и такие
/// копии пропускаются целиком.
@MainActor
final class ClipboardHistory: ObservableObject {

    static let shared = ClipboardHistory()

    // MARK: Настройки

    /// Выключено по умолчанию, как и автопереключение: история запоминает всё
    /// скопированное, и включать это человек должен сам, а не получать молча.
    @Published var isEnabled = false { didSet { save("clipboardEnabled", isEnabled); apply() } }
    @Published var limit = 20 { didSet { AppDefaults.store.set(limit, forKey: "clipboardLimit"); trim() } }
    @Published var pasteImmediately = true { didSet { save("clipboardPaste", pasteImmediately) } }
    @Published var hotkeyEnabled = true { didSet { save("clipboardHotkey", hotkeyEnabled); apply() } }

    static let limits = [10, 20, 50, 100]

    // MARK: Состояние

    @Published private(set) var items: [ClipItem] = []

    /// Что показывать: закреплённые сверху, дальше по свежести.
    var displayItems: [ClipItem] { items.filter(\.pinned) + items.filter { !$0.pinned } }

    /// Открыть меню значка — его подставляет строка меню. Сочетание клавиш
    /// открывает то же меню, что и клик по значку.
    var showMenu: (() -> Void)?

    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var hotkey: GlobalHotKey?
    private var didBootstrap = false

    private init() {
        let d = AppDefaults.store
        isEnabled = d.bool(forKey: "clipboardEnabled")
        limit = d.object(forKey: "clipboardLimit") as? Int ?? 20
        pasteImmediately = d.object(forKey: "clipboardPaste") as? Bool ?? true
        hotkeyEnabled = d.object(forKey: "clipboardHotkey") as? Bool ?? true
    }

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        items = Self.load()
        apply()
    }

    private func apply() {
        guard didBootstrap else { return }
        if isEnabled && timer == nil {
            lastChangeCount = NSPasteboard.general.changeCount   // прошлое не записываем задним числом
            let t = Timer(timeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated { ClipboardHistory.shared.poll() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !isEnabled {
            timer?.invalidate()
            timer = nil
        }

        if isEnabled && hotkeyEnabled {
            if hotkey == nil {
                // ⌃⌘V: не ⇧⌘V — во многих программах это «вставить без форматирования»,
                // и не ⌥⌘V — им Finder перемещает скопированные файлы.
                hotkey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_V),
                                      modifiers: UInt32(controlKey | cmdKey)) {
                    ClipboardHistory.shared.showMenu?()
                }
            }
        } else {
            hotkey?.unregister()
            hotkey = nil
        }
    }

    // MARK: Слежение за буфером

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        if Self.isConfidential(types: pb.types ?? []) { return }
        let front = NSWorkspace.shared.frontmostApplication
        if let id = front?.bundleIdentifier, AutoSwitcher.passwordManagers.contains(id) { return }
        guard let text = pb.string(forType: .string) else { return }

        let updated = Self.inserting(text, app: front?.localizedName, into: items, limit: limit)
        guard updated != items else { return }
        items = updated
        persist()
    }

    /// Собственная запись в буфер: счётчик сдвигается на неё, и слежение её
    /// не подхватит как новую копию. Иначе, например, чтение выделения через
    /// буфер в автопереключении попадало бы в историю.
    func markOwnWrite() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    // MARK: Действия

    /// Положить запись в буфер. Если просили — ещё и вставить туда, где стоит курсор.
    func pick(_ item: ClipItem, paste: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.text, forType: .string)
        markOwnWrite()
        items = Self.inserting(item.text, app: item.app, into: items, limit: limit, keepPinned: item.pinned)
        persist()

        // Вставлять имеет смысл, только если впереди чужая программа: из собственного
        // окна вставка ушла бы в никуда. И только с универсальным доступом —
        // без него macOS не даёт нажимать клавиши за человека.
        guard paste, pasteImmediately, Permissions.hasAccessibility,
              NSWorkspace.shared.frontmostApplication?.processIdentifier
                != ProcessInfo.processInfo.processIdentifier else { return }
        // Меню должно успеть закрыться, иначе ⌘V достанется ему.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            MainActor.assumeIsolated { Corrector.sendPaste() }
        }
    }

    func togglePin(_ item: ClipItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].pinned.toggle()
        trim()
        persist()
    }

    func remove(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    /// Очистка не трогает закреплённое: закрепляют как раз то, что терять не хотят.
    func clearUnpinned() {
        items.removeAll { !$0.pinned }
        persist()
    }

    private func trim() {
        let trimmed = Self.trimmed(items, limit: limit)
        if trimmed != items { items = trimmed; persist() }
    }

    // MARK: Чистая логика — её проверяет --selftest

    /// Больше этого в историю не кладём: огромный текст раздувает файл истории,
    /// а вставлять его из меню всё равно никто не станет.
    static let maxBytes = 200_000

    static func inserting(_ text: String, app: String?, date: Date = Date(),
                          into items: [ClipItem], limit: Int, keepPinned: Bool? = nil) -> [ClipItem] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= maxBytes else { return items }
        var result = items
        // Повторная копия того же текста не дублирует запись, а поднимает её наверх.
        let existing = result.firstIndex { $0.text == text }
        let wasPinned = existing.map { result[$0].pinned } ?? false
        if let i = existing { result.remove(at: i) }
        let item = ClipItem(id: existing.map { items[$0].id } ?? UUID(), text: text, date: date,
                            app: app, pinned: keepPinned ?? wasPinned)
        result.insert(item, at: 0)
        return trimmed(result, limit: limit)
    }

    /// Закреплённые остаются всегда, из остальных — `limit` самых свежих.
    static func trimmed(_ items: [ClipItem], limit: Int) -> [ClipItem] {
        var unpinnedKept = 0
        return items.filter { item in
            if item.pinned { return true }
            unpinnedKept += 1
            return unpinnedKept <= limit
        }
    }

    /// Типы, которыми менеджеры паролей и системные утилиты помечают
    /// секретное и временное (соглашение nspasteboard.org).
    static let confidentialTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
        "com.typeit4me.clipping",
        "de.petermaurer.TransientPasteboardType",
        "Pasteboard generator type",
    ]

    static func isConfidential(types: [NSPasteboard.PasteboardType]) -> Bool {
        types.contains { confidentialTypes.contains($0.rawValue) }
    }

    /// Одна строка для меню: переводы строк и повторные пробелы схлопываются.
    static func menuTitle(_ text: String, max: Int = 48) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max)) + "…" : flat
    }

    // MARK: Хранение

    /// Файл истории. Лежит только на этом Mac и доступен только владельцу
    /// учётной записи (права 0600).
    static var fileURL: URL {
        AppDefaults.supportFolder.appendingPathComponent("clipboard-history.json")
    }

    private func persist() {
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted]
            try encoder.encode(items).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            FileHandle.standardError.write(Data("история буфера не сохранилась: \(error)\n".utf8))
        }
    }

    private static func load() -> [ClipItem] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ClipItem].self, from: data)) ?? []
    }

    private func save(_ key: String, _ value: Bool) {
        AppDefaults.store.set(value, forKey: key)
    }

    /// Только для `--snapshot` и `--measure`: образцовые записи в памяти, чтобы
    /// раздел рисовался заполненным. На диск не пишутся, слежение не запускается.
    func useSampleItems() {
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        isEnabled = true
        items = [
            ClipItem(id: UUID(), text: "Встреча перенесена на четверг, 15:00. Ссылка та же.",
                     date: ago(1), app: "Telegram", pinned: false),
            ClipItem(id: UUID(), text: "https://github.com/sipandk-art/macos-utilities",
                     date: ago(4), app: "Safari", pinned: false),
            ClipItem(id: UUID(), text: "ул. Остоженка, 12, подъезд 2, код 4417",
                     date: ago(60), app: "Заметки", pinned: true),
            ClipItem(id: UUID(), text: "git commit -m \"Граница слова — пробел\"",
                     date: ago(12), app: "Терминал", pinned: false),
            ClipItem(id: UUID(), text: "Спасибо! Посмотрю вечером и отпишусь.",
                     date: ago(35), app: "Почта", pinned: false),
        ]
    }

    // MARK: Самопроверка

    static func selftest() -> (ok: Int, bad: Int) {
        var ok = 0, bad = 0
        func expect(_ name: String, _ condition: Bool) {
            if condition { ok += 1 } else { bad += 1; print("FAIL: история буфера — \(name)") }
        }
        var h: [ClipItem] = []
        h = inserting("первый", app: nil, into: h, limit: 3)
        h = inserting("второй", app: nil, into: h, limit: 3)
        h = inserting("третий", app: nil, into: h, limit: 3)
        expect("новое сверху", h.map(\.text) == ["третий", "второй", "первый"])

        h = inserting("первый", app: nil, into: h, limit: 3)
        expect("повтор поднимается, а не дублируется", h.map(\.text) == ["первый", "третий", "второй"])

        h = inserting("четвёртый", app: nil, into: h, limit: 3)
        expect("лишнее вытесняется", h.map(\.text) == ["четвёртый", "первый", "третий"])

        h[2].pinned = true                                   // «третий» закреплён
        h = inserting("пятый", app: nil, into: h, limit: 3)
        h = inserting("шестой", app: nil, into: h, limit: 3)
        expect("закреплённое не вытесняется", h.contains { $0.text == "третий" && $0.pinned })
        expect("незакреплённых не больше лимита", h.filter { !$0.pinned }.count == 3)

        h = inserting("третий", app: nil, into: h, limit: 3)
        expect("повтор закреплённого остаётся закреплённым",
               h.first?.text == "третий" && h.first?.pinned == true)

        expect("пустое не пишется", inserting("  \n ", app: nil, into: [], limit: 3).isEmpty)
        expect("огромное не пишется",
               inserting(String(repeating: "я", count: maxBytes), app: nil, into: [], limit: 3).isEmpty)

        expect("пароль из менеджера паролей не пишется",
               isConfidential(types: [.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")]))
        expect("обычный текст пишется", !isConfidential(types: [.string]))
        expect("строка меню схлопывает переносы", menuTitle("раз\n\n  два\tтри") == "раз два три")
        expect("строка меню обрезается", menuTitle(String(repeating: "а", count: 60)).count == 49)
        return (ok, bad)
    }
}
