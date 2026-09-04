import Foundation
import IOKit.pwr_mgt
import SwiftUI

enum AppInfo {
    static let repositoryURL = "https://github.com/sipandk-art/macos-utilities"
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}

/// Держит Mac в рабочем состоянии, пока включён тумблер.
///
/// Механизм — штатные power assertions IOKit, то же самое, что делает
/// системная утилита `caffeinate`. Два утверждения:
///
///   PreventUserIdleSystemSleep — система не уходит в сон по бездействию;
///   NetworkClientActive        — сетевые соединения не рвутся.
///
/// Утверждения на дисплей сознательно НЕ берутся: экран продолжает гаснуть
/// по системному таймеру, машина при этом не засыпает. Так и было задумано —
/// длинная задача не обрывается, а панель не жжёт подсветку впустую.
@MainActor
final class KeepAwake: ObservableObject {

    @Published private(set) var isOn = false
    @Published private(set) var displaySleepMinutes: Int?

    private var systemAssertion: IOPMAssertionID = 0
    private var networkAssertion: IOPMAssertionID = 0
    private let defaultsKey = "keepAwakeEnabled"

    private var didBootstrap = false

    /// Вызывается один раз после первой отрисовки, а не из init: чтение настроек
    /// питания и взятие утверждений меняют @Published, а править состояние
    /// внутри прохода обновления SwiftUI нельзя — это роняет граф отрисовки.
    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        refreshDisplaySleep()
        // Тумблер переживает перезапуск приложения: если его оставили включённым,
        // после запуска утверждения берутся заново.
        if UserDefaults.standard.bool(forKey: defaultsKey) { enable() }
    }

    func toggle() { isOn ? disable() : enable() }

    func enable() {
        guard !isOn else { return }
        let name = "MacOS Utilities: не давать Mac уснуть" as CFString
        let level = IOPMAssertionLevel(kIOPMAssertionLevelOn)

        var sys: IOPMAssertionID = 0
        let sysOK = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString, level, name, &sys) == kIOReturnSuccess

        var net: IOPMAssertionID = 0
        let netOK = IOPMAssertionCreateWithName(
            kIOPMAssertNetworkClientActive as CFString, level, name, &net) == kIOReturnSuccess

        guard sysOK else {
            if netOK { IOPMAssertionRelease(net) }
            return
        }
        systemAssertion = sys
        networkAssertion = netOK ? net : 0
        isOn = true
        UserDefaults.standard.set(true, forKey: defaultsKey)
        refreshDisplaySleep()
    }

    func disable() {
        if systemAssertion != 0 { IOPMAssertionRelease(systemAssertion); systemAssertion = 0 }
        if networkAssertion != 0 { IOPMAssertionRelease(networkAssertion); networkAssertion = 0 }
        isOn = false
        UserDefaults.standard.set(false, forKey: defaultsKey)
    }

    /// Через сколько минут бездействия гаснет экран — читаем системную настройку,
    /// чтобы показать её рядом с тумблером, а не заставлять лезть в «Настройки».
    func refreshDisplaySleep() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "live"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") where line.contains("displaysleep") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, let value = Int(parts[1]) {
                displaySleepMinutes = value
                return
            }
        }
    }

    func openDisplaySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")!
        NSWorkspace.shared.open(url)
    }
}
