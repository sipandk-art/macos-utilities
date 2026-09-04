import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if Snapshot.isRequested { Snapshot.run() }
        if Snapshot.isMeasureRequested { Snapshot.measure() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // В режиме снимков окна закрываются по одному — выходить рано.
        !Snapshot.isRequested && !Snapshot.isMeasureRequested
    }
}

@main
struct MacOSUtilitiesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        // Высота подобрана по самому высокому разделу (AirDrop, 704 pt при этой
        // ширине колонки — замерено режимом `--measure`) плюс запас на титульную
        // полосу и баннер с итогом операции. В исходном состоянии прокрутки нет.
        .defaultSize(width: 900, height: 812)
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
