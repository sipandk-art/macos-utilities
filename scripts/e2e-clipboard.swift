#!/usr/bin/env swift
//
// e2e-clipboard.swift — проверка истории буфера обмена целиком.
//
//   1. Запустить приложение, включить в нём раздел «Буфер обмена».
//   2. Открыть TextEdit с пустым документом.
//   3. swift scripts/e2e-clipboard.swift
//
// Стенд копирует тексты в системный буфер, читает, что записало приложение
// (файл истории), открывает меню значка, выбирает записи и проверяет, что
// оказалось в буфере и в документе. Буфер обмена пользователя в конце
// возвращается как был.

import AppKit
import Carbon

func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

let pb = NSPasteboard.general
let savedClipboard = pb.string(forType: .string)

let historyFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/MacOS Utilities (test)/clipboard-history.json")

struct Entry: Decodable { let text: String; let pinned: Bool }

func history() -> [String] {
    guard let data = try? Data(contentsOf: historyFile),
          let items = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
    return items.map(\.text)
}

/// Копирует текст так, как это делает обычная программа, и ждёт, пока
/// приложение его заметит: оно проверяет буфер раз в полсекунду.
func copy(_ text: String) {
    pb.clearContents()
    pb.setString(text, forType: .string)
    pump(0.9)
}

/// Копия с пометкой «секретное» — так кладут пароли 1Password, Bitwarden и другие.
func copyConcealed(_ text: String) {
    let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    pb.clearContents()
    pb.declareTypes([.string, concealed], owner: nil)
    pb.setString(text, forType: .string)
    pb.setString("", forType: concealed)
    pump(0.9)
}

func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    let src = CGEventSource(stateID: .hidSystemState)
    // Модификаторы — отдельными событиями, иначе система считает их зажатыми.
    var mods: [(CGKeyCode, CGEventFlags)] = []
    if flags.contains(.maskControl) { mods.append((59, .maskControl)) }
    if flags.contains(.maskCommand) { mods.append((55, .maskCommand)) }
    var held: CGEventFlags = []
    for (m, f) in mods {
        held.insert(f)
        let e = CGEvent(keyboardEventSource: src, virtualKey: m, keyDown: true)!
        e.type = .flagsChanged; e.flags = held; e.post(tap: .cghidEventTap); pump(0.03)
    }
    let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)!
    d.flags = held; d.post(tap: .cghidEventTap); pump(0.04)
    let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)!
    u.flags = held; u.post(tap: .cghidEventTap); pump(0.04)
    for (m, f) in mods.reversed() {
        held.remove(f)
        let e = CGEvent(keyboardEventSource: src, virtualKey: m, keyDown: false)!
        e.type = .flagsChanged; e.flags = held; e.post(tap: .cghidEventTap); pump(0.03)
    }
}

func appleScript(_ source: String) -> String? {
    var error: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
    if let error { print("  AppleScript: \(error[NSAppleScript.errorMessage] ?? error)") }
    return result?.stringValue
}

func focusTextEdit() -> Bool {
    guard let app = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.TextEdit").first else { return false }
    app.activate(options: [.activateAllWindows])
    for _ in 0..<20 {
        pump(0.2)
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit" { return true }
    }
    return false
}

func documentText() -> String {
    appleScript("tell application \"TextEdit\" to get text of document 1") ?? "<нет>"
}

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String) {
    if !ok { failures += 1 }
    print("  \(ok ? "PASS" : "FAIL") \(name): \(detail)")
}

let stamp = String(Int(Date().timeIntervalSince1970) % 100000)
let first = "первый-\(stamp)", second = "second-\(stamp)", third = "третий-\(stamp)"

print("== 1. скопированное попадает в историю, новое сверху ==")
copy(first); copy(second); copy(third)
var h = history()
check("порядок", Array(h.prefix(3)) == [third, second, first], "\(Array(h.prefix(3)))")

print("== 2. повторная копия поднимается, а не дублируется ==")
copy(first)
h = history()
check("наверху", h.first == first, "первая запись «\(h.first ?? "")»")
check("без дубля", h.filter { $0 == first }.count == 1, "раз в истории: \(h.filter { $0 == first }.count)")

print("== 3. пароль из менеджера паролей не записывается ==")
let secret = "пароль-\(stamp)"
copyConcealed(secret)
check("секретное пропущено", !history().contains(secret), "в истории: \(history().contains(secret) ? "ДА" : "нет")")

print("== 4. файл истории доступен только владельцу ==")
let perms = (try? FileManager.default.attributesOfItem(atPath: historyFile.path)[.posixPermissions]) as? Int
check("права 0600", perms == 0o600, String(format: "%o", perms ?? 0))

print("== 5. выбор в меню значка кладёт запись в буфер и вставляет её ==")
copy("заглушка-\(stamp)")
// Выбор из меню ещё и вставляет запись в активную программу. Впереди обязан быть
// TextEdit: иначе текст ушёл бы в то окно, откуда запущен стенд.
guard focusTextEdit() else { print("  TextEdit не вышел вперёд — стоп"); exit(2) }
_ = appleScript("tell application \"TextEdit\" to set text of document 1 to \"\"")
pump(0.4)
let secondTitle = second                        // короткий текст — в меню виден целиком
_ = appleScript("""
tell application "System Events" to tell process "MacOSUtilities"
  click menu bar item 1 of menu bar 2
  delay 0.8
  click menu item "\(secondTitle)" of menu 1 of menu bar item 1 of menu bar 2
end tell
""")
pump(1.0)
check("в буфере выбранное", pb.string(forType: .string) == second,
      "в буфере «\(pb.string(forType: .string) ?? "")»")
check("вставлено в TextEdit", documentText() == second, "в документе «\(documentText())»")

print("== 6. ⌃⌘V и цифра вставляют запись в документ ==")
guard focusTextEdit() else { print("  TextEdit не вышел вперёд — стоп"); exit(2) }
_ = appleScript("tell application \"TextEdit\" to set text of document 1 to \"\"")
pump(0.4)
let expected = history().first ?? ""
key(9, [.maskControl, .maskCommand])            // ⌃⌘V — открыть историю
pump(1.0)
key(18)                                         // «1» — первая запись
pump(1.2)
check("вставлено в TextEdit", documentText() == expected,
      "в документе «\(documentText())», ждали «\(expected)»")

pb.clearContents()
if let savedClipboard { pb.setString(savedClipboard, forType: .string) }
print(failures == 0 ? "\nВСЕ ПРОВЕРКИ ПРОЙДЕНЫ" : "\nПРОВАЛЕНО: \(failures)")
exit(failures == 0 ? 0 : 1)
