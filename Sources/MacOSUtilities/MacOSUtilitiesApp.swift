import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let menuBar = MenuBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if !Snapshot.isRequested && !Snapshot.isMeasureRequested {
            menuBar.install()
            // Фоновые режимы поднимаются сами: если автопереключение было
            // включено, оно должно работать сразу после входа в систему,
            // а не после того, как человек откроет окно.
            AutoSwitcher.shared.bootstrap()
            KeepAwake.shared.bootstrap()
        }
        if Snapshot.isRequested { Snapshot.run() }
        if Snapshot.isMeasureRequested { Snapshot.measure() }
        if CommandLine.arguments.contains("--selftest") {
            exit(AutoSwitcher.selftest() ? 0 : 1)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if Snapshot.isRequested || Snapshot.isMeasureRequested { return false }
        // Пока работает что-то фоновое, закрытие окна не должно выключать это
        // без спроса: приложение остаётся значком в строке меню. Если фоновых
        // режимов нет, ведём себя как обычная программа и выходим.
        return !(AutoSwitcher.shared.isEnabled || KeepAwake.shared.isOn)
    }
}

@main
struct MacOSUtilitiesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        // Ширина 900 = боковая панель 244 + колонка раздела 656. Высота взята
        // по самому высокому разделу при этой колонке (652 pt, замерено режимом
        // `--measure`, одинаково на обоих языках) плюс запас на баннер с итогом
        // операции. В исходном состоянии прокрутки нет.
        .defaultSize(width: 900, height: 760)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Репозиторий на GitHub") {
                    if let url = URL(string: AppInfo.repositoryURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
