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
///
/// Плюс пинги (см. `NetworkPing`): Mac не спит, но VPN-туннель без трафика
/// закрывают как неактивный — роутер, провайдер или сам сервер VPN.
@MainActor
final class KeepAwake: ObservableObject {

    static let shared = KeepAwake()

    @Published private(set) var isOn = false
    @Published private(set) var displaySleepMinutes: Int?

    private var systemAssertion: IOPMAssertionID = 0
    private var networkAssertion: IOPMAssertionID = 0
    private var pingTimer: Timer?
    private var pingActivity: NSObjectProtocol?
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
        if AppDefaults.store.bool(forKey: defaultsKey) { enable() }
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
        startPings()
        isOn = true
        AppDefaults.store.set(true, forKey: defaultsKey)
        refreshDisplaySleep()
    }

    func disable() {
        if systemAssertion != 0 { IOPMAssertionRelease(systemAssertion); systemAssertion = 0 }
        if networkAssertion != 0 { IOPMAssertionRelease(networkAssertion); networkAssertion = 0 }
        stopPings()
        isOn = false
        AppDefaults.store.set(false, forKey: defaultsKey)
    }

    private func startPings() {
        // Окно закрыто — и macOS притормаживает фоновое приложение (App Nap):
        // таймер срабатывал бы раз в несколько минут, а не раз в 30 секунд.
        pingActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "MacOS Utilities: не давать VPN простаивать")
        NetworkPing.send()
        pingTimer = Timer.scheduledTimer(withTimeInterval: NetworkPing.interval, repeats: true) { _ in
            NetworkPing.send()
        }
    }

    private func stopPings() {
        pingTimer?.invalidate()
        pingTimer = nil
        if let activity = pingActivity { ProcessInfo.processInfo.endActivity(activity) }
        pingActivity = nil
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

/// Короткий запрос к Google раз в 30 секунд, пока включён режим «не спать».
///
/// При VPN весь трафик идёт через туннель, и запрос не даёт ему простаивать.
/// Обычный ping (ICMP) для этого не годится: VPN-клиенты со своим виртуальным
/// интерфейсом отвечают на него сами — за миллисекунду, туннель не трогая.
enum NetworkPing {
    static let interval: TimeInterval = 30
    /// Google отдаёт здесь пустой ответ 204 — адрес ровно для проверки связи.
    static let url = URL(string: "https://www.gstatic.com/generate_204")!

    /// Ответ не нужен: важен сам трафик через туннель.
    static func send() {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: 10)
        URLSession.shared.dataTask(with: request).resume()
    }
}
