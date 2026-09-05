import AppKit
import Carbon

/// Стирает набранное и печатает заново в другой раскладке.
///
/// Текст вставляется не через буфер обмена, а событиями клавиатуры
/// с готовой строкой (`keyboardSetUnicodeString`): буфер пользователя
/// остаётся нетронутым, и это работает в том числе в Electron-приложениях,
/// где вставка из буфера часто срывается.
@MainActor
enum Corrector {

    /// Метка на собственных событиях: перехватчик по ней узнаёт свои же
    /// нажатия и не принимает их за пользовательский ввод.
    static let marker: Int64 = 0x4D_55_54_4C     // "MUTL"

    private static let backspaceKey: CGKeyCode = 51

    private static func source() -> CGEventSource? {
        let src = CGEventSource(stateID: .privateState)
        src?.userData = marker
        return src
    }

    /// Убирает `count` символов слева от курсора и печатает `text`.
    static func replace(charactersBack count: Int, with text: String) {
        guard count > 0 || !text.isEmpty, let src = source() else { return }

        for _ in 0..<count {
            CGEvent(keyboardEventSource: src, virtualKey: backspaceKey, keyDown: true)?
                .post(tap: .cgAnnotatedSessionEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: backspaceKey, keyDown: false)?
                .post(tap: .cgAnnotatedSessionEventTap)
        }

        guard !text.isEmpty else { return }
        var utf16 = Array(text.utf16)
        // Длинные строки разбиваются: у события ограниченный буфер,
        // а вставлять приходится целые слова, а иногда и выделение.
        let chunk = 20
        var index = 0
        while index < utf16.count {
            let end = min(index + chunk, utf16.count)
            var slice = Array(utf16[index..<end])
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
                down.post(tap: .cgAnnotatedSessionEventTap)
            }
            if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
                up.post(tap: .cgAnnotatedSessionEventTap)
            }
            index = end
        }
    }

    /// Выделенный текст в активном поле, если система его отдаёт.
    /// Нужен для исправления не одного слова, а того, что человек выделил сам.
    static func selectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let element = focused else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement,
                                            kAXSelectedTextAttribute as CFString,
                                            &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}
