import AppKit
import Combine
import SwiftUI

/// Значок в строке меню. Нужен потому, что автопереключение и режим «не спать»
/// работают в фоне: без значка приложение было бы невидимо, и его нельзя было бы
/// ни выключить, ни закрыть, не открывая окно.
@MainActor
final class MenuBarController {

    private var item: NSStatusItem?
    private var bag = Set<AnyCancellable>()

    private let sw = AutoSwitcher.shared
    private let awake = KeepAwake.shared
    private let loc = Localization.shared

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "wrench.adjustable",
                                     accessibilityDescription: "MacOS Utilities")
        item.button?.image?.isTemplate = true
        self.item = item
        rebuild()

        // Меню пересобирается на любое изменение состояния: галки и подписи
        // должны совпадать с тем, что показывает окно.
        for publisher in [sw.objectWillChange, awake.objectWillChange, loc.objectWillChange] {
            publisher
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.rebuild() }
                .store(in: &bag)
        }
    }

    private func rebuild() {
        guard let item else { return }
        item.button?.image = NSImage(
            systemSymbolName: (sw.isRunning || awake.isOn) ? "wrench.adjustable.fill" : "wrench.adjustable",
            accessibilityDescription: "MacOS Utilities")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()

        let autoItem = NSMenuItem(title: loc.t("Исправлять раскладку", "Fix the layout"),
                                  action: #selector(toggleAuto), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = sw.isEnabled ? .on : .off
        menu.addItem(autoItem)

        if sw.isEnabled && !sw.hasAccessibility {
            let warn = NSMenuItem(title: loc.t("  нужно разрешение macOS", "  needs a macOS permission"),
                                  action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }

        let awakeItem = NSMenuItem(title: loc.t("Не давать Mac уснуть", "Keep the Mac awake"),
                                   action: #selector(toggleAwake), keyEquivalent: "")
        awakeItem.target = self
        awakeItem.state = awake.isOn ? .on : .off
        menu.addItem(awakeItem)

        menu.addItem(.separator())

        let open = NSMenuItem(title: loc.t("Открыть окно…", "Open window…"),
                              action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let quit = NSMenuItem(title: loc.t("Выйти", "Quit"),
                              action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
    }

    @objc private func toggleAuto() {
        if !sw.isEnabled && !sw.hasAccessibility {
            openWindow()
            return                      // разрешения спрашиваются в окне, а не молча из меню
        }
        sw.isEnabled.toggle()
    }

    @objc private func toggleAwake() { awake.toggle() }

    @objc private func openWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Окно WindowGroup закрывается вместе с последним окном сцены,
        // поэтому просим систему открыть новое штатным способом.
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
