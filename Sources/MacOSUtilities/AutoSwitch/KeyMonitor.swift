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
        case letter(KeyPress)      // обычная клавиша с буквой
        case separator             // пробел, перевод строки, знак препинания
        case erase                 // Backspace: убираем последнее нажатие
        case reset                 // курсор ушёл — накопленное слово больше не под ним
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
    /// Автоматический разбор выключен — работает только горячее сочетание.
    var autoEnabled = true

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

        if isExcludedApp() { return pass }

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

    private func isExcludedApp() -> Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return excludedBundleIDs.contains(id)
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

        guard autoEnabled else { return false }

        // Сочетания с Cmd/Ctrl/Opt — это команды, а не текст.
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            onSignal?(.reset)
            return false
        }

        switch keycode {
        case 51:                                   // Backspace
            onSignal?(.erase)
        case 36, 76, 48, 53:                       // Return, Enter, Tab, Esc
            onSignal?(.separator)
        case 123...126, 115, 116, 119, 121, 117:   // стрелки, Home/End, PageUp/Down, Delete
            onSignal?(.reset)
        default:
            let shift = flags.contains(.maskShift)
            let press = KeyPress(keycode: keycode, shift: shift)
            if isLetterKey(press) {
                onSignal?(.letter(press))
            } else {
                onSignal?(.separator)
            }
        }
        return false
    }

    /// Буква ли это в текущей раскладке. Цифры, знаки и пробел — граница слова.
    private func isLetterKey(_ press: KeyPress) -> Bool {
        guard let src = cachedLayout,
              let text = LayoutService.translate(source: src, keycode: press.keycode,
                                                 shift: press.shift),
              let ch = text.first else { return false }
        return ch.isLetter
    }
}
