import AppKit
import ApplicationServices

/// Два разрешения macOS, без которых автопереключение работать не может.
/// Они запрашиваются только при включении раздела и ничего не значат
/// для остальных функций приложения.
@MainActor
enum Permissions {

    /// Мониторинг ввода — видеть нажатия клавиш в других программах.
    static var hasInputMonitoring: Bool { CGPreflightListenEventAccess() }

    /// Универсальный доступ — стирать напечатанное и печатать заново.
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static var allGranted: Bool { hasInputMonitoring && hasAccessibility }

    /// Показывает системный запрос. Оба разрешения требуют перезапуска
    /// приложения только в старых версиях macOS; с 13 подхватываются на лету.
    static func requestInputMonitoring() {
        if !CGRequestListenEventAccess() { openSettings(.inputMonitoring) }
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { openSettings(.accessibility) }
    }

    enum Pane {
        case inputMonitoring, accessibility
        var url: URL {
            switch self {
            case .inputMonitoring:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
            case .accessibility:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            }
        }
    }

    static func openSettings(_ pane: Pane) {
        NSWorkspace.shared.open(pane.url)
    }
}
