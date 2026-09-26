import AppKit
import Carbon

/// Перехватчик клавиатуры. Ничего не хранит на диске и не накапливает историю:
/// наружу отдаются отдельные события, а слово из них собирает `AutoSwitcher`
/// и забывает на ближайшем пробеле.
///
/// Перехват «активный» (`.defaultTap`), а не только на чтение — иначе нельзя
/// проглотить горячее сочетание, и оно напечатало бы свой символ в текст.
@MainActor
final class KeyMonitor {

    enum Signal {
        /// Любая печатная клавиша: буква, знак, цифра. Всё это часть слова.
        /// Знаки препинания здесь не граница: семь русских букв (х ъ ж э б ю ё)
        /// сидят на клавишах, которые в латинице — скобки, запятая, точка,
        /// кавычка. Считать их границей — значит рвать «это», «будет», «уже».
        case char(KeyPress)
        case space(KeyPress)       // граница слова
        case erase                 // Backspace: убираем последнее нажатие
        case reset                 // курсор ушёл — набранное больше не под ним
        case hotkey                // просили исправить вручную
    }

    /// Что считать горячим сочетанием.
    enum Hotkey: Equatable {
        case doubleShift
        case combo(keycode: UInt16, flags: CGEventFlags)

        var isDoubleShift: Bool { if case .doubleShift = self { return true }; return false }
    }

    var onSignal: ((Signal) -> Void)?
    var hotkey: Hotkey = .doubleShift
    /// Программы, в которых перехват молчит: терминалы, среды разработки,
    /// менеджеры паролей. Проверяется идентификатор активного приложения.
    var excludedBundleIDs: Set<String> = []

    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Текущая раскладка кэшируется: обработчик перехвата вызывается на каждое
    /// нажатие, и если он задумается, система молча выключит перехват
    /// по таймауту. Кэш сбрасывается по уведомлению о смене раскладки.
    private var cachedLayout: TISInputSource?
    private var layoutObserver: NSObjectProtocol?

    // Двойной Shift: время предыдущего отпускания и признак «между ними ничего не жали».
    private var lastShiftRelease: TimeInterval = 0
    private var shiftWasAlone = true

    // MARK: Запуск

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.leftMouseDown.rawValue)
                 | (1 << CGEventType.rightMouseDown.rawValue)

        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
            },
            userInfo: me
        ) else { return false }

        tap = port
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        cachedLayout = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cachedLayout = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
            }
        }

        isRunning = true
        return true
    }

    func stop() {
        guard isRunning, let port = tap else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        CFMachPortInvalidate(port)
        if let observer = layoutObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            layoutObserver = nil
        }
        cachedLayout = nil
        tap = nil
        runLoopSource = nil
        isRunning = false
    }

    // MARK: Разбор событий

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        // Система выключает перехват, если он задумался или если так решил
        // пользователь. Молча включаем обратно, иначе всё тихо перестанет работать.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
            return pass
        }

        // Собственные события, которыми мы же и печатаем замену.
        if event.getIntegerValueField(.eventSourceUserData) == Corrector.marker { return pass }

        // В поле пароля не смотрим вообще.
        if IsSecureEventInputEnabled() { onSignal?(.reset); return pass }

        if let excluded = excludedFrontApp() {
            if AutoSwitcher.tracing {
                FileHandle.standardError.write(Data("[trace] пропускаю: \(excluded)\n".utf8))
            }
            return pass
        }

        switch type {
        case .leftMouseDown, .rightMouseDown:
            onSignal?(.reset)
            return pass

        case .flagsChanged:
            handleFlags(event)
            return pass

        case .keyDown:
            return handleKeyDown(event) ? nil : pass

        default:
            return pass
        }
    }

    /// Возвращает идентификатор активной программы, если она в списке исключений.
    private func excludedFrontApp() -> String? {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              excludedBundleIDs.contains(id) else { return nil }
        return id
    }

    /// Двойной Shift. Считается только «чистое» нажатие: если между двумя
    /// Shift успела уйти любая другая клавиша, это был обычный набор заглавных.
    private func handleFlags(_ event: CGEvent) {
        guard hotkey.isDoubleShift else { return }
        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keycode == 56 || keycode == 60 else { return }        // левый и правый Shift
        let shiftDown = event.flags.contains(.maskShift)

        if shiftDown {
            shiftWasAlone = true
            return
        }
        let now = Date().timeIntervalSinceReferenceDate
        if shiftWasAlone && now - lastShiftRelease < 0.35 {
            lastShiftRelease = 0
            onSignal?(.hotkey)
        } else {
            lastShiftRelease = now
        }
    }

    /// Возвращает true, если событие надо проглотить (это было наше сочетание).
    private func handleKeyDown(_ event: CGEvent) -> Bool {
        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        shiftWasAlone = false

        if case let .combo(hotKeycode, hotFlags) = hotkey {
            let interesting: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            if keycode == hotKeycode && flags.intersection(interesting) == hotFlags.intersection(interesting) {
                onSignal?(.hotkey)
                return true
            }
        }

        // Нажатия копятся всегда, даже когда автоматика выключена: иначе
        // горячему сочетанию нечего было бы исправлять — оно умело бы только
        // выделенный текст, а последнее слово ему было бы недоступно.
        // Решение «править или нет» принимается уровнем выше.

        // Сочетания с Cmd/Ctrl/Opt — это команды, а не текст.
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            onSignal?(.reset)
            return false
        }

        switch keycode {
        case 51:                                   // Backspace
            onSignal?(.erase)
        case 36, 76, 48, 53:                       // Return, Enter, Tab, Esc
            // Ввод закончен и, скорее всего, уже отправлен: править нечего,
            // а накопленное больше не лежит под курсором.
            onSignal?(.reset)
        case 123...126, 115, 116, 119, 121, 117:   // стрелки, Home/End, PageUp/Down, Delete
            onSignal?(.reset)
        case 49:                                   // пробел — единственная граница слова
            onSignal?(.space(KeyPress(keycode: keycode, shift: flags.contains(.maskShift))))
        default:
            let press = KeyPress(keycode: keycode, shift: flags.contains(.maskShift))
            // Клавиши, которые ничего не печатают (F1–F12 и подобные), в слово
            // не берём: иначе при правке стёрли бы на символ больше, чем набрано.
            if printsText(press) { onSignal?(.char(press)) }
        }
        return false
    }

    /// Печатает ли клавиша видимый символ в текущей раскладке.
    private func printsText(_ press: KeyPress) -> Bool {
        guard let src = cachedLayout,
              let text = LayoutService.translate(source: src, keycode: press.keycode,
                                                 shift: press.shift),
              let scalar = text.unicodeScalars.first else { return false }
        if scalar.properties.generalCategory == .control { return false }
        if scalar.properties.generalCategory == .privateUse { return false }   // F-клавиши
        return true
    }
}
