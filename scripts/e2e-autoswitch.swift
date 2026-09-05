#!/usr/bin/env swift
//
// e2e-autoswitch.swift — проверка автопереключения целиком, на живой клавиатуре.
//
//   1. Запустить приложение и включить в нём раздел «Автопереключение».
//   2. Открыть TextEdit с пустым документом.
//   3. swift scripts/e2e-autoswitch.swift auto     — правка на пробеле
//      swift scripts/e2e-autoswitch.swift manual   — горячее сочетание
//
// Два прогона нужны потому, что режимы мешают друг другу: с включённой
// автоматикой слова правятся по одному прямо по ходу набора, и проверить
// на них многословную ручную правку нельзя.
//
// Стенд сам выводит TextEdit вперёд, печатает настоящими событиями клавиатуры
// и читает результат через систему универсального доступа. Самому стенду нужны
// те же разрешения, что и приложению.
//
// Две ловушки, на которые он натыкался и ради которых написан именно так:
//
//   • Carbon отдаёт текущую раскладку через цикл событий. Если спать в usleep,
//     а не крутить RunLoop, читается устаревшее значение и кажется, что
//     переключения не произошло.
//   • Синтетическое событие с модификатором оставляет систему в состоянии
//     «Command зажат», и следующие буквы уходят как команды. Поэтому поле
//     чистится одними Backspace.

import AppKit
import Carbon

func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

func inputSources() -> [TISInputSource] {
    let filter = [kTISPropertyInputSourceCategory as String:
                  kTISCategoryKeyboardInputSource as String] as CFDictionary
    return TISCreateInputSourceList(filter, false)!.takeRetainedValue() as! [TISInputSource]
}

func sourceID(_ s: TISInputSource) -> String {
    guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return "?" }
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}

func currentLayout() -> String {
    guard let s = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return "?" }
    return sourceID(s)
}

func selectLatin() {
    if let abc = inputSources().first(where: { sourceID($0).contains("ABC") }) {
        TISSelectInputSource(abc)
    }
    pump(0.5)
}

func selectCyrillic() {
    if let ru = inputSources().first(where: { sourceID($0).contains("Russian") }) {
        TISSelectInputSource(ru)
    }
    pump(0.5)
}

func type(_ codes: [CGKeyCode]) {
    let src = CGEventSource(stateID: .hidSystemState)
    for code in codes {
        CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        pump(0.03)
        CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
        pump(0.06)
    }
}

/// Два «чистых» нажатия Shift подряд — горячее сочетание по умолчанию.
func doubleShift() {
    let src = CGEventSource(stateID: .hidSystemState)
    for _ in 0..<2 {
        let down = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: true)!
        down.type = .flagsChanged; down.flags = .maskShift
        down.post(tap: .cghidEventTap)
        pump(0.05)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: false)!
        up.type = .flagsChanged; up.flags = []
        up.post(tap: .cghidEventTap)
        pump(0.08)
    }
}

func fieldText() -> String {
    let system = AXUIElementCreateSystemWide()
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString,
                                        &focused) == .success, let element = focused
    else { return "<нет фокуса>" }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXValueAttribute as CFString,
                                        &value) == .success else { return "<нет значения>" }
    return (value as? String) ?? "<не строка>"
}

func clearField() { type(Array(repeating: 51, count: 60)); pump(0.2) }

/// Выделить всё. Модификатор идёт отдельным событием: иначе система считает
/// Command зажатым и следующие буквы уходят как команды.
func selectAll() {
    let src = CGEventSource(stateID: .hidSystemState)
    let m = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: true)!
    m.type = .flagsChanged; m.flags = .maskCommand; m.post(tap: .cghidEventTap); pump(0.05)
    let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)!
    d.flags = .maskCommand; d.post(tap: .cghidEventTap); pump(0.06)
    let u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)!
    u.flags = .maskCommand; u.post(tap: .cghidEventTap); pump(0.06)
    let mu = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: false)!
    mu.type = .flagsChanged; mu.flags = []; mu.post(tap: .cghidEventTap); pump(0.3)
}

func focusTextEdit() {
    guard let app = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.TextEdit").first else {
        print("TextEdit не запущен — откройте его с пустым документом"); exit(2)
    }
    app.activate(options: [.activateAllWindows])
    for _ in 0..<20 {
        pump(0.2)
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit" { return }
    }
    print("не удалось вывести TextEdit вперёд"); exit(2)
}

/// Чужое окно под нажатиями — это чужой текст. Каждый шаг сверяется с фокусом;
/// если его перехватила другая программа, один раз пробуем вернуть, и только
/// потом сдаёмся — печатать вслепую нельзя.
func requireTextEdit() {
    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit" { return }
    focusTextEdit()
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
    if front != "com.apple.TextEdit" { print("фокус ушёл в \(front) — стоп"); exit(2) }
}

/// Режим прогона: «auto» — правка на пробеле, «manual» — горячее сочетание.
let mode = CommandLine.arguments.dropFirst().first ?? "auto"

var failures = 0
func check(_ name: String, _ got: String, _ want: String) {
    requireTextEdit()
    let ok = got == want
    if !ok { failures += 1 }
    print("  \(ok ? "PASS" : "FAIL") \(name): получили «\(got)», ждали «\(want)»")
}

focusTextEdit()

// g h b d t n — это «привет», набранное в латинской раскладке.
let ghbdtn: [CGKeyCode] = [5, 4, 11, 2, 17, 45]
let hello: [CGKeyCode] = [4, 14, 37, 37, 31]

if mode == "auto" {
print("== 1. слово не в той раскладке правится на пробеле ==")
requireTextEdit(); selectLatin(); clearField()
type(ghbdtn + [49])
pump(1.2)
check("ghbdtn + пробел", fieldText(), "привет ")
let after = currentLayout()
print("     раскладка переключилась на: \(after)")
if !after.contains("Russian") { failures += 1; print("  FAIL: раскладка должна была стать русской") }

print("== 2. правильное английское слово трогать нельзя ==")
requireTextEdit(); selectLatin(); clearField()
type(hello + [49])
pump(1.0)
check("hello + пробел", fieldText(), "hello ")

}

if mode == "manual" {
print("== 3. ручное исправление двойным Shift, ещё до пробела ==")
requireTextEdit(); selectLatin(); clearField()
type(ghbdtn)
pump(0.4)
doubleShift()
pump(1.2)
check("ghbdtn -> привет", fieldText(), "привет")

print("== 4. повторное сочетание возвращает как было ==")
doubleShift()
pump(1.2)
check("возврат", fieldText(), "ghbdtn")

}

if mode == "auto" {
print("== 5. короткое слово в обратную сторону ==")
requireTextEdit(); selectCyrillic(); clearField()
// Клавиши w h y: в русской раскладке это «црн», в латинской — «why».
type([13, 4, 16] + [49])
pump(1.2)
check("црн + пробел", fieldText(), "why ")
let backToLatin = currentLayout()
print("     раскладка переключилась на: \(backToLatin)")
if !backToLatin.contains("ABC") { failures += 1; print("  FAIL: раскладка должна была стать латинской") }

}

if mode == "manual" {
print("== 6. без выделения правится только последнее слово ==")
requireTextEdit(); selectLatin(); clearField()
// ghbdtn rfr ltkf — это «привет как дела», набранное в латинской раскладке.
type(ghbdtn + [49] + [15, 3, 15] + [49] + [37, 17, 40, 3])
pump(0.5)
doubleShift()
pump(1.5)
check("тронуто только последнее", fieldText(), "ghbdtn rfr дела")

print("== 7. выделенный текст правится целиком ==")
requireTextEdit(); selectLatin(); clearField()
type(ghbdtn + [49] + [15, 3, 15] + [49] + [37, 17, 40, 3])
pump(0.5)
selectAll()
pump(0.5)
doubleShift()
pump(1.8)
check("всё выделенное", fieldText(), "привет как дела")

}

selectLatin()
clearField()
print(failures == 0 ? "\nВСЕ ПРОВЕРКИ ПРОЙДЕНЫ" : "\nПРОВАЛЕНО: \(failures)")
exit(failures == 0 ? 0 : 1)
