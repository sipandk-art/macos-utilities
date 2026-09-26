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
    private let clipboard = ClipboardHistory.shared
    private let awake = KeepAwake.shared
    private let loc = Localization.shared

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "wrench.adjustable",
                                     accessibilityDescription: "MacOS Utilities")
        item.button?.image?.isTemplate = true
        self.item = item
        rebuild()

        // ⌃⌘V открывает то же меню, что и клик по значку. Меню значка — системное:
        // приложение не становится активным, фокус остаётся в программе, где
        // стоит курсор, и выбранная запись вставляется именно туда.
        clipboard.showMenu = { [weak self] in self?.item?.button?.performClick(nil) }

        // Меню пересобирается на любое изменение состояния: галки и подписи
        // должны совпадать с тем, что показывает окно.
        for publisher in [sw.objectWillChange, awake.objectWillChange, loc.objectWillChange,
                          clipboard.objectWillChange] {
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
        addClipboardSection(to: menu)

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

    // MARK: Буфер обмена

    /// История — первым списком: за ней в меню и приходят чаще всего.
    /// Первые девять записей выбираются цифрой, пока меню открыто.
    private func addClipboardSection(to menu: NSMenu) {
        let header = NSMenuItem(title: loc.t("Буфер обмена", "Clipboard"), action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(
            string: loc.t("Буфер обмена", "Clipboard"),
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                         .foregroundColor: NSColor.secondaryLabelColor])
        header.isEnabled = false
        menu.addItem(header)

        guard clipboard.isEnabled else {
            let enable = NSMenuItem(title: loc.t("Включить историю…", "Turn on history…"),
                                    action: #selector(showClipboardSection), keyEquivalent: "")
            enable.target = self
            menu.addItem(enable)
            menu.addItem(.separator())
            return
        }

        let entries = Array(clipboard.displayItems.prefix(10))
        if entries.isEmpty {
            let empty = NSMenuItem(title: loc.t("Пока пусто — скопируйте что-нибудь",
                                                "Empty — copy something"),
                                   action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for (index, entry) in entries.enumerated() {
            let key = index < 9 ? String(index + 1) : ""
            let mi = NSMenuItem(title: ClipboardHistory.menuTitle(entry.text),
                                action: #selector(pickClip(_:)), keyEquivalent: key)
            mi.keyEquivalentModifierMask = []
            mi.target = self
            mi.representedObject = entry.id
            mi.toolTip = String(entry.text.prefix(400))
            if entry.pinned {
                mi.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
            }
            menu.addItem(mi)
        }

        let all = NSMenuItem(title: loc.t("Вся история…", "Full history…"),
                             action: #selector(showClipboardSection), keyEquivalent: "")
        all.target = self
        menu.addItem(all)
        menu.addItem(.separator())
    }

    @objc private func pickClip(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let entry = clipboard.items.first(where: { $0.id == id }) else { return }
        clipboard.pick(entry, paste: true)
    }

    @objc private func showClipboardSection() {
        NotificationCenter.default.post(name: .showTool, object: Tool.clipboard)
        WindowPresenter.shared.show()
        // Окно могло только что создаться и ещё не подписаться на уведомление.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: .showTool, object: Tool.clipboard)
        }
    }

    @objc private func openWindow() {
        WindowPresenter.shared.show()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
