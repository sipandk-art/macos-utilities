import SwiftUI

/// Как открыть окно, когда его уже закрыли.
///
/// Окно создаёт SwiftUI, и из AppKit нового не попросить. Поэтому окно само,
/// пока живо, оставляет здесь способ открыть себя заново — им пользуется пункт
/// «Открыть окно…» в строке меню.
@MainActor
final class WindowPresenter {
    static let shared = WindowPresenter()
    var open: (() -> Void)?

    /// Видимые обычные окна приложения. Панели и служебные окна не в счёт.
    var visibleWindows: [NSWindow] {
        NSApp.windows.filter { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
    }

    /// Показать окно: сначала возвращаем значок в Dock, иначе окно откроется
    /// без него и приложение останется недоступным для Cmd+Tab.
    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = visibleWindows.first {
            window.makeKeyAndOrderFront(nil)
        } else {
            open?()
        }
    }

    /// Спрятать значок из Dock, когда окон не осталось. Приложение продолжает
    /// работать значком в строке меню.
    func hideFromDockIfNoWindows() {
        guard visibleWindows.isEmpty else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let menuBar = MenuBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Без окон приложение выглядит для системы бездельником, и она вправе
        // снять процесс, чтобы освободить память. Для значка в строке меню это
        // недопустимо: вместе с процессом молча умерло бы автопереключение.
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("значок в строке меню")
        if !Snapshot.isRequested && !Snapshot.isMeasureRequested {
            menuBar.install()
            // Фоновые режимы поднимаются сами: если автопереключение было
            // включено, оно должно работать сразу после входа в систему,
            // а не после того, как человек откроет окно.
            AutoSwitcher.shared.bootstrap()
            KeepAwake.shared.bootstrap()

            // Закрыли последнее окно — убираем значок из Dock. Уведомление
            // приходит до того, как окно перестало числиться видимым,
            // поэтому проверяем следующим тактом.
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: nil, queue: .main
            ) { _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { WindowPresenter.shared.hideFromDockIfNoWindows() }
                }
            }
        }
        if Snapshot.isRequested { Snapshot.run() }
        if Snapshot.isMeasureRequested { Snapshot.measure() }
        if CommandLine.arguments.contains("--selftest") {
            exit(AutoSwitcher.selftest() ? 0 : 1)
        }
    }
    /// Закрытие окна никогда не завершает приложение: оно остаётся значком
    /// в строке меню, и выйти можно пунктом «Выйти» в его меню. Иначе
    /// закрытие окна молча выключало бы фоновые режимы.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Клик по значку в Dock, когда окон нет, — просьба показать окно.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowPresenter.shared.show() }
        return true
    }
}

@main
struct MacOSUtilitiesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
        }
        // Ширина 900 = боковая панель 244 + колонка раздела 656. Высота взята
        // по самому высокому разделу при этой колонке (автопереключение, 763 pt,
        // замерено режимом `--measure`, одинаково на обоих языках). В исходном
        // состоянии прокрутки нет.
        .defaultSize(width: 900, height: 780)
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
