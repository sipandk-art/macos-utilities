import SwiftUI

struct InputSourceView: View {
    @EnvironmentObject private var loc: Localization
    @StateObject private var tool: ScriptTool

    init(tool: ScriptTool = ScriptTool(scriptName: "input-source-fix",
                                       scriptTitle: "input-source-fix.sh")) {
        _tool = StateObject(wrappedValue: tool)
    }

    @State private var showScript = false
    @State private var confirmRevert = false

    private var d: ScriptOutput? { tool.diagnostics }
    private var applied: Bool { d?.flag("APPLIED") ?? false }
    private var hasBackup: Bool { d?.flag("HAS_BACKUP") ?? false }
    private var layouts: Int { Int(d?["LAYOUTS"] ?? "") ?? 0 }

    var body: some View {
        ToolPage(
            header: PageHeader(
                symbol: Tool.inputSource.symbol,
                tint: Tool.inputSource.tint,
                title: loc.t("Переключение раскладки", "Switching the keyboard layout"),
                subtitle: loc.t(
                    """
                    Caps Lock начнёт переключать язык ввода. Встроенная настройка macOS \
                    делает то же самое, но при быстром наборе иногда пропускает нажатия — \
                    здесь этого не происходит.
                    """,
                    """
                    Caps Lock starts switching the input language. The built-in macOS \
                    option does the same but drops keystrokes when you type fast — \
                    this one doesn't.
                    """)
            ),
            script: (tool.scriptTitle, tool.source),
            showScript: $showScript
        ) {
            diagnosticsCard
            actionsCard
            if let run = tool.lastRun {
                ResultBanner(
                    kind: tool.resultKind,
                    title: tool.resultKind == .ok ? loc.t("Готово", "Done")
                                                  : loc.t("Не выполнено", "Failed"),
                    detail: run.summary
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if !tool.log.isEmpty {
                Card { LogPanel(lines: tool.log) }
            }
        }
        .animation(.calm, value: tool.lastRun?.summary)
        .animation(.calm, value: tool.isRunning)
        .task { tool.lang = loc.lang; if !tool.checked { await tool.check() } }
        .onChange(of: loc.lang) { newValue in
            tool.lang = newValue
            Task { await tool.check() }
        }
        .confirmationDialog(
            loc.t("Отменить изменения?", "Undo the changes?"),
            isPresented: $confirmRevert,
            titleVisibility: .visible
        ) {
            Button(loc.t("Отменить изменения", "Undo"), role: .destructive) {
                Task { await tool.run(["revert"]) }
            }
            Button(loc.t("Отмена", "Cancel"), role: .cancel) { }
        } message: {
            Text(loc.t(
                "Caps Lock снова станет обычным Caps Lock, а настройки клавиатуры вернутся к тому, что было до применения.",
                "Caps Lock goes back to being Caps Lock, and your keyboard settings return to how they were before."))
        }
    }

    // MARK: Проверка системы

    private var diagnosticsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 11) {
                CardHeader(title: loc.t("Проверка системы", "System check"),
                           busy: tool.isChecking,
                           hint: loc.t("Проверить заново", "Check again")) {
                    Task { await tool.check() }
                }

                Divider()

                if !tool.checked {
                    BusyLabel(text: loc.t("Проверяю систему…", "Checking…"))
                } else {
                    CheckRow(title: loc.t("Версия macOS", "macOS version"),
                             value: tool.macOSVersion,
                             kind: tool.isSupported ? .ok : .fail,
                             hint: tool.isSupported ? loc.t("подходит", "supported")
                                                    : loc.t("нужна macOS 11 или новее", "macOS 11 or later required"))

                    CheckRow(title: loc.t("Пароль администратора", "Administrator password"),
                             value: loc.t("не нужен", "not needed"),
                             kind: .ok,
                             hint: loc.t("меняются только ваши настройки",
                                         "only your own settings are changed"))

                    CheckRow(title: loc.t("Языков ввода включено", "Input languages enabled"),
                             value: "\(layouts)",
                             kind: layouts >= 2 ? .ok : .warn,
                             hint: layouts >= 2 ? nil
                                   : loc.t("добавьте второй язык, иначе переключать нечего",
                                           "add a second language, otherwise there is nothing to switch"))

                    if d?.flag("CAPS_NOACTION") == true {
                        CheckRow(title: loc.t("Клавиша Caps Lock", "The Caps Lock key"),
                                 value: loc.t("отключена", "disabled"),
                                 kind: .warn,
                                 hint: loc.t("будет включена обратно", "will be re-enabled"))
                    }

                    CheckRow(title: loc.t("Сейчас", "Right now"),
                             value: applied ? loc.t("включено", "on") : loc.t("выключено", "off"),
                             kind: applied ? .ok : .idle)
                }
            }
        }
    }

    // MARK: Действия

    private var actionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 13) {
                Text(loc.t("Действия", "Actions")).font(.system(size: 13, weight: .semibold))

                Text(applied
                     ? loc.t("Уже включено. Нажать ещё раз безопасно — настройки просто запишутся заново.",
                             "Already on. Pressing again is safe — the settings are simply written once more.")
                     : loc.t("Настройки клавиатуры изменятся так, чтобы Caps Lock переключал язык. Это переживёт перезагрузку.",
                             "Your keyboard settings change so that Caps Lock switches the language. This survives a reboot."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        Task { await tool.run(["apply"]) }
                    } label: {
                        Text(applied ? loc.t("Включить заново", "Turn on again")
                                     : loc.t("Включить", "Turn on"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!tool.isSupported || tool.isBusy)

                    Button(loc.t("Отменить изменения", "Undo")) { confirmRevert = true }
                        .controlSize(.large)
                        .disabled(!hasBackup || tool.isBusy)
                        .help(hasBackup
                              ? loc.t("Вернуть настройки к тому, что было до применения",
                                      "Restore the settings to how they were before")
                              : loc.t("Отменять нечего: через это приложение ничего не менялось",
                                      "Nothing to undo: this app has not changed anything yet"))
                }

                if tool.isRunning { BusyLabel(text: loc.t("Выполняю…", "Working…")) }
            }
        }
    }
}

/// Общий каркас раздела: заголовок, содержимое, нижняя панель с кнопками
/// «Показать весь скрипт» и «Поделиться».
struct ToolPage<Content: View>: View {
    let header: PageHeader
    let script: (title: String, source: String)?
    @Binding var showScript: Bool
    @ViewBuilder var content: Content

    @EnvironmentObject private var loc: Localization
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        VStack(spacing: 0) {
            // В режиме снимков прокрутка отключается: ImageRenderer не делает
            // проход раскладки внутри ScrollView и отдал бы пустой кадр.
            if snapshotMode {
                stack.padding(Metrics.gutter)
                Spacer(minLength: 0)
            } else {
                ScrollView { stack.padding(Metrics.gutter) }
            }

            Divider()

            HStack(spacing: 10) {
                if script != nil {
                    Button {
                        showScript = true
                    } label: {
                        Label(loc.t("Показать весь скрипт", "Show the full script"),
                              systemImage: "curlybraces")
                    }
                    .help(loc.t("Открыть исходный код с комментариями",
                                "Open the source code with comments"))
                }
                Spacer()
                ShareRepoButton()
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 11)
            .background(.bar)
        }
        .sheet(isPresented: $showScript) {
            if let script {
                ScriptSheet(title: script.title, script: script.source)
                    .environmentObject(loc)
            }
        }
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: Metrics.stack) {
            header.padding(.bottom, 4)
            content
        }
        // Длина строки текста ограничена: на широком окне абзацы описаний
        // иначе растягиваются и перестают читаться.
        .frame(maxWidth: 760, alignment: .leading)
    }
}

/// Флаг режима `--snapshot`: отключает прокрутку, чтобы страницу можно было
/// отрисовать целиком в PNG.
private struct SnapshotModeKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}
