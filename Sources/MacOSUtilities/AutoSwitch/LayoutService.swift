import AppKit
import Carbon

/// Раскладки клавиатуры: какие включены, что даёт нажатие клавиши в каждой,
/// и переключение активной.
///
/// Соответствие клавиш символам НЕ зашито таблицей — его отдаёт сама система
/// через `UCKeyTranslate`. Поэтому работает любая пара раскладок, которую
/// включил пользователь, а не только та, под которую писали код.
@MainActor
final class LayoutService {

    struct Layout: Identifiable, Equatable {
        let id: String              // com.apple.keylayout.RussianWin
        let name: String            // Russian — Windows
        let source: TISInputSource
        /// Письменность, которую даёт раскладка: по ней выбирается словарь.
        let script: Script

        static func == (a: Layout, b: Layout) -> Bool { a.id == b.id }
    }

    enum Script { case latin, cyrillic, other }

    private(set) var layouts: [Layout] = []

    init() { reload() }

    func reload() {
        let filter = [kTISPropertyInputSourceCategory as String:
                      kTISCategoryKeyboardInputSource as String] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?
            .takeRetainedValue() as? [TISInputSource] else { layouts = []; return }

        layouts = list.compactMap { src in
            // Раскладки без таблицы символов (например рукописный ввод) пропускаем.
            guard TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) != nil,
                  let idPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID),
                  let namePtr = TISGetInputSourceProperty(src, kTISPropertyLocalizedName)
            else { return nil }
            let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
            let name = Unmanaged<CFString>.fromOpaque(namePtr).takeUnretainedValue() as String
            let probe = Self.translate(source: src, keycode: 4, shift: false) ?? ""   // клавиша H
            return Layout(id: id, name: name, source: src, script: Self.script(of: probe))
        }
    }

    var current: Layout? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return nil }
        let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        return layouts.first { $0.id == id }
    }

    /// Пара «латиница + кириллица», с которой работает переключатель.
    /// Пока поддержаны только эти две письменности — так и просили.
    var pair: (latin: Layout, cyrillic: Layout)? {
        guard let lat = layouts.first(where: { $0.script == .latin }),
              let cyr = layouts.first(where: { $0.script == .cyrillic }) else { return nil }
        return (lat, cyr)
    }

    func select(_ layout: Layout) {
        TISSelectInputSource(layout.source)
    }

    // MARK: Перевод нажатий в текст

    /// Что напечатает клавиша `keycode` в этой раскладке.
    nonisolated static func translate(source: TISInputSource, keycode: UInt16,
                                      shift: Bool) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        // Модификаторы для UCKeyTranslate задаются в «карбоновом» виде:
        // это старший байт маски событий, поэтому shiftKey сдвигается на 8.
        let modifiers = UInt32(shift ? (UInt32(shiftKey) >> 8) : 0)
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        var deadState: UInt32 = 0
        let ok = data.withUnsafeBytes { raw -> Bool in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return false }
            return UCKeyTranslate(layout, keycode, UInt16(kUCKeyActionDown), modifiers,
                                  UInt32(LMGetKbdType()),
                                  UInt32(kUCKeyTranslateNoDeadKeysMask),
                                  &deadState, 4, &length, &chars) == noErr
        }
        guard ok, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    /// Собирает слово из нажатий в заданной раскладке.
    nonisolated static func render(_ keys: [KeyPress], in layout: Layout) -> String {
        keys.compactMap { translate(source: layout.source, keycode: $0.keycode, shift: $0.shift) }
            .joined()
    }

    nonisolated static func script(of text: String) -> Script {
        for ch in text.unicodeScalars {
            if ch.value >= 0x0400 && ch.value <= 0x04FF { return .cyrillic }
            if (ch.value >= 0x41 && ch.value <= 0x5A) || (ch.value >= 0x61 && ch.value <= 0x7A) {
                return .latin
            }
        }
        return .other
    }
}

/// Одно нажатие: код клавиши и был ли зажат Shift. Символ не запоминается —
/// он вычисляется из кода в нужной раскладке в момент проверки.
struct KeyPress: Equatable {
    let keycode: UInt16
    let shift: Bool
}
