import SwiftUI
import Carbon

struct AutoSwitchView: View {
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var sw: AutoSwitcher
    @State private var showScript = false
    @State private var confirmEnable = false

    var body: some View {
        ToolPage(
            header: PageHeader(
                symbol: Tool.autoSwitch.symbol,
                tint: Tool.autoSwitch.tint,
                title: loc.t("Набрано не в той раскладке", "Typed in the wrong layout"),
                subtitle: loc.t(
                    """
                    Начали писать «ghbdtn» вместо «привет» — приложение замечает это \
                    на пробеле, переписывает слово и переключает язык. Стирать \
                    и набирать заново не нужно.
                    """,
                    """
                    You start typing "ghbdtn" instead of "привет" — the app notices at \
                    the space, rewrites the word and switches the language. No need to \
                    erase and retype.
                    """)
            ),
            script: nil,
            showScript: $showScript
        ) {
            mainToggle
            if sw.isEnabled && !sw.hasAccessibility { permissionsCard }
            behaviourCard
            privacyCard
        }
        .animation(.calm, value: sw.isEnabled)
        .animation(.calm, value: sw.isRunning)
        .task { sw.refreshPermissions() }
        .alert(loc.t("Понадобятся два разрешения", "Two permissions are needed"),
               isPresented: $confirmEnable) {
            Button(loc.t("Продолжить", "Continue")) { enableAndRequest() }
            Button(loc.t("Отмена", "Cancel"), role: .cancel) { }
        } message: {
            Text(loc.t(
                """
                Чтобы исправлять набранное, приложению нужно видеть нажатия клавиш \
                и уметь печатать за вас. macOS спросит об этом отдельно.

                Нажатия нигде не сохраняются: слово живёт до ближайшего пробела \
                и стирается из памяти. В полях пароля перехват выключается сам.
                """,
                """
                To fix what you typed, the app needs to see your keystrokes and be able \
                to type for you. macOS will ask about each of these separately.

                Keystrokes are never stored: the current word is discarded at the next \
                space. In password fields the app stops watching automatically.
                """))
        }
    }

    /// Включает раздел и сразу показывает системные запросы: сначала
    /// универсальный доступ — без него перехват не создастся вовсе.
    private func enableAndRequest() {
        sw.isEnabled = true
        Permissions.requestAccessibility()
        Permissions.requestInputMonitoring()
        sw.refreshPermissions()
    }

    // MARK: Главный переключатель

    private var mainToggle: some View {
        Card {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(sw.isEnabled ? loc.t("Включено", "On") : loc.t("Выключено", "Off"))
                        .font(.system(size: 15, weight: .semibold))
                    Text(statusText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: Binding(
                    get: { sw.isEnabled },
                    set: { on in
                        if on && !sw.hasAccessibility { confirmEnable = true }
                        else { sw.isEnabled = on }
                    }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }

    private var statusText: String {
        if !sw.isEnabled {
            return loc.t("Раздел не следит за клавиатурой и не просит разрешений",
                         "The app is not watching the keyboard and asks for nothing")
        }
        if !sw.hasAccessibility {
            return loc.t("Не хватает разрешения — смотрите ниже",
                         "A permission is missing — see below")
        }
        if sw.isRunning {
            let n = sw.correctionCount
            return n == 0
                ? loc.t("Работает. Попробуйте напечатать ghbdtn и пробел",
                        "Working. Try typing ghbdtn followed by a space")
                : loc.t("Работает. Исправлено слов: \(n)", "Working. Words fixed: \(n)")
        }
        return loc.t("Не запущено", "Not running")
    }

    // MARK: Разрешения

    private var permissionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 11) {
                CardHeader(title: loc.t("Разрешения macOS", "macOS permissions"),
                           busy: false,
                           hint: loc.t("Проверить заново", "Check again")) {
                    sw.refreshPermissions()
                }
                Divider()

                permissionRow(
                    granted: sw.hasAccessibility,
                    title: loc.t("Универсальный доступ", "Accessibility"),
                    why: loc.t("стереть напечатанное и напечатать заново",
                               "to erase what you typed and type it again"),
                    request: { Permissions.requestAccessibility() },
                    open: { Permissions.openSettings(.accessibility) })

                permissionRow(
                    granted: sw.hasInputMonitoring,
                    title: loc.t("Мониторинг ввода", "Input Monitoring"),
                    why: loc.t("видеть нажатия клавиш · нужен не на всех версиях macOS",
                               "to see keystrokes · not required on every macOS version"),
                    request: { Permissions.requestInputMonitoring() },
                    open: { Permissions.openSettings(.inputMonitoring) })

                if !sw.hasAccessibility {
                    Text(loc.t(
                        "После выдачи разрешения вернитесь сюда и нажмите «Проверить заново».",
                        "After granting the permission come back here and press “Check again”."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func permissionRow(granted: Bool, title: String, why: String,
                               request: @escaping () -> Void,
                               open: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: granted ? StatusKind.ok.symbol : StatusKind.warn.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(granted ? StatusKind.ok.color : StatusKind.warn.color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5))
                Text(why).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            if granted {
                Text(loc.t("выдано", "granted"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Button(loc.t("Выдать", "Grant")) { request(); open() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: Поведение

    private var behaviourCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(loc.t("Как исправлять", "How to fix")).font(.system(size: 13, weight: .semibold))

                Toggle(isOn: Binding(get: { sw.autoMode }, set: { sw.autoMode = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc.t("Исправлять самому на пробеле", "Fix automatically at the space"))
                            .font(.system(size: 12.5))
                        Text(loc.t("выключите, если хотите исправлять только сочетанием клавиш",
                                   "turn off if you'd rather fix things only with the shortcut"))
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .toggleStyle(.checkbox)

                Divider()

                HotkeyField()

                Text(loc.t(
                    "Сочетание исправляет выделенный текст, а если ничего не выделено — последнее слово. Нажатое сразу второй раз возвращает как было.",
                    "The shortcut fixes the selected text, or the last word when nothing is selected. Pressing it again right away undoes the change."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Toggle(isOn: Binding(get: { sw.skipTerminals }, set: { sw.skipTerminals = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc.t("Не вмешиваться в терминалы и редакторы кода",
                                   "Stay out of terminals and code editors"))
                            .font(.system(size: 12.5))
                        Text(loc.t("там много «неслов» — команды, переменные, пути",
                                   "full of non-words — commands, variables, paths"))
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: Binding(get: { sw.skipPasswordManagers },
                                     set: { sw.skipPasswordManagers = $0 })) {
                    Text(loc.t("Не вмешиваться в менеджеры паролей",
                               "Stay out of password managers"))
                        .font(.system(size: 12.5))
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: Binding(get: { sw.skipBrowsers }, set: { sw.skipBrowsers = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc.t("Не вмешиваться в браузеры", "Stay out of browsers"))
                            .font(.system(size: 12.5))
                        Text(loc.t("поле пароля на сайте распознать нельзя — браузеры этого не показывают",
                                   "a password field on a web page can't be detected — browsers don't expose it"))
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: Binding(get: { sw.launchAtLogin }, set: { sw.launchAtLogin = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc.t("Запускать при входе в систему", "Launch at login"))
                            .font(.system(size: 12.5))
                        Text(loc.t("иначе переключатель работает только пока приложение открыто",
                                   "otherwise the switcher works only while the app is open"))
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    // MARK: Что приложение видит

    private var privacyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 7) {
                Text(loc.t("Что приложение видит", "What the app can see"))
                    .font(.system(size: 13, weight: .semibold))
                Text(loc.t(
                    """
                    Набранное слово живёт до ближайшего пробела и стирается из памяти. Ничего не пишется на диск и никуда не отправляется. В полях пароля перехват выключается сам. Выключите раздел — слежение прекращается сразу.
                    """,
                    """
                    The current word is kept only until the next space, then discarded. Nothing is written to disk and nothing is sent anywhere. In password fields the app stops watching on its own. Turn the section off and the watching stops immediately.
                    """))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // У остальных разделов есть кнопка «Показать весь скрипт».
                // Здесь код на Swift и внутрь окна не помещается, поэтому
                // ведём прямо к нему — обещание «ничего скрытого» должно
                // выполняться и там, где приложение читает клавиатуру.
                Button {
                    if let url = URL(string: AppInfo.repositoryURL
                                     + "/tree/main/Sources/MacOSUtilities/AutoSwitch") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(loc.t("Открыть код этого раздела", "Open this section's source code"),
                          systemImage: "curlybraces")
                }
                .padding(.top, 2)
            }
        }
    }
}

// MARK: - Запись горячего сочетания

struct HotkeyField: View {
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var sw: AutoSwitcher
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 10) {
            Text(loc.t("Сочетание клавиш", "Shortcut")).font(.system(size: 12.5))
            Spacer(minLength: 8)

            Button(recording ? loc.t("Нажмите клавиши…", "Press the keys…") : description) {
                recording ? stopRecording() : startRecording()
            }
            .frame(minWidth: 168)

            if !sw.hotkey.isDoubleShift {
                Button(loc.t("Двойной Shift", "Double Shift")) {
                    stopRecording()
                    sw.hotkey = .doubleShift
                }
                .controlSize(.small)
            }
        }
    }

    private var description: String {
        switch sw.hotkey {
        case .doubleShift:
            return loc.t("Двойной Shift", "Double Shift")
        case .combo(let keycode, let flags):
            return Self.describe(keycode: keycode, flags: flags)
        }
    }

    private func startRecording() {
        recording = true
        // Локальный монитор ловит нажатие, пока открыто наше окно, — этого
        // достаточно, чтобы записать сочетание, и не требует разрешений.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.isEmpty else { return event }     // без модификаторов — не сочетание
            var cg: CGEventFlags = []
            if flags.contains(.command) { cg.insert(.maskCommand) }
            if flags.contains(.option) { cg.insert(.maskAlternate) }
            if flags.contains(.control) { cg.insert(.maskControl) }
            if flags.contains(.shift) { cg.insert(.maskShift) }
            sw.hotkey = .combo(keycode: event.keyCode, flags: cg)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    /// Человекочитаемое имя клавиши: символ берём из текущей раскладки,
    /// чтобы подпись совпадала с тем, что нарисовано на клавише.
    static func describe(keycode: UInt16, flags: CGEventFlags) -> String {
        var parts = ""
        if flags.contains(.maskControl) { parts += "⌃" }
        if flags.contains(.maskAlternate) { parts += "⌥" }
        if flags.contains(.maskShift) { parts += "⇧" }
        if flags.contains(.maskCommand) { parts += "⌘" }
        var key = "?"
        if let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
           let text = LayoutService.translate(source: src, keycode: keycode, shift: false),
           !text.isEmpty {
            key = text.uppercased()
        }
        switch keycode {
        case 49: key = "Space"
        case 36: key = "Return"
        case 48: key = "Tab"
        case 53: key = "Esc"
        default: break
        }
        return parts + key
    }
}
