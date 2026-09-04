import SwiftUI

struct AirDropView: View {
    @EnvironmentObject private var loc: Localization
    @StateObject private var tool: ScriptTool

    init(tool: ScriptTool = ScriptTool(scriptName: "airdrop-fix",
                                       scriptTitle: "airdrop-fix.sh")) {
        _tool = StateObject(wrappedValue: tool)
    }

    @State private var showScript = false
    @State private var restartFinder = false
    @State private var restartAWDL = false
    @State private var confirmFinder = false

    private var d: ScriptOutput? { tool.diagnostics }
    private var found: Int { Int(d?["FOUND"] ?? "") ?? 0 }
    private var stale: Int { Int(d?["STALE"] ?? "") ?? 0 }
    private var sharingdUp: Bool { d?["SHARINGD"] == "up" }

    var body: some View {
        ToolPage(
            header: PageHeader(
                symbol: Tool.airdrop.symbol,
                tint: Tool.airdrop.tint,
                title: loc.t("Зависший AirDrop", "AirDrop is stuck"),
                subtitle: loc.t(
                    """
                    Окно AirDrop иногда не закрывается до конца: оно исчезает с экрана, \
                    но остаётся в системе и время от времени всплывает поверх других окон. \
                    Здесь такие окна находятся и закрываются, а AirDrop перезапускается — \
                    без перезагрузки Mac.
                    """,
                    """
                    The AirDrop window sometimes doesn't close all the way: it leaves the \
                    screen but stays in the system and pops back over other windows now and \
                    then. This finds those windows, closes them and restarts AirDrop — \
                    without rebooting your Mac.
                    """)
            ),
            script: (tool.scriptTitle, tool.source),
            showScript: $showScript
        ) {
            diagnosticsCard
            optionsCard
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
        .animation(.calm, value: restartFinder)
        .task { tool.lang = loc.lang; if !tool.checked { await tool.check() } }
        .onChange(of: loc.lang) { newValue in
            tool.lang = newValue
            Task { await tool.check() }
        }
        // Предупреждение показывается ДО запуска, а не после: перезапуск Finder
        // закрывает окна Finder и на секунду гасит рабочий стол.
        .alert(loc.t("Finder будет перезапущен", "Finder will restart"), isPresented: $confirmFinder) {
            Button(loc.t("Продолжить", "Continue")) { launch() }
            Button(loc.t("Отмена", "Cancel"), role: .cancel) { }
        } message: {
            Text(loc.t(
                """
                Все открытые окна Finder закроются, рабочий стол на секунду моргнёт \
                и перерисуется. Копирование файлов, если оно сейчас идёт в Finder, \
                прервётся. Остальные программы это не затронет.
                """,
                """
                Every open Finder window will close and the desktop will blink and redraw \
                for a second. Any file copying currently running in Finder will be \
                interrupted. Other apps are not affected.
                """))
        }
    }

    // MARK: Проверка

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
                             value: restartAWDL ? loc.t("нужен", "needed") : loc.t("не нужен", "not needed"),
                             kind: .ok,
                             hint: restartAWDL
                                   ? loc.t("его спросит система — только для перезапуска Wi-Fi",
                                           "the system will ask for it — only to restart Wi-Fi")
                                   : loc.t("закрываются только ваши собственные окна",
                                           "only your own windows are closed"))

                    CheckRow(title: loc.t("Служба AirDrop", "The AirDrop service"),
                             value: sharingdUp ? loc.t("работает", "running")
                                               : loc.t("не запущена", "not running"),
                             kind: sharingdUp ? .ok : .warn)

                    CheckRow(title: loc.t("Незакрытых окон AirDrop", "Unclosed AirDrop windows"),
                             value: "\(found)",
                             kind: stale > 0 ? .warn : .ok,
                             hint: stale > 0 ? loc.t("из них зависших: \(stale)", "stuck: \(stale)")
                                             : loc.t("зависших нет", "none are stuck"))
                }
            }
        }
    }

    // MARK: Дополнительно

    private var optionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(loc.t("Дополнительно", "Also do this"))
                    .font(.system(size: 13, weight: .semibold))

                Toggle(isOn: $restartFinder) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc.t("Перезапустить Finder", "Restart Finder"))
                            .font(.system(size: 12.5))
                        Text(loc.t("если окно AirDrop видно на экране, но не отвечает",
                                   "if the AirDrop window is on screen but doesn't respond"))
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: $restartAWDL) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc.t("Перезапустить Wi-Fi для AirDrop", "Restart Wi-Fi for AirDrop"))
                            .font(.system(size: 12.5))
                        Text(loc.t("если Mac не видит iPhone · спросит пароль администратора",
                                   "if your Mac can't see your iPhone · asks for the administrator password"))
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .toggleStyle(.checkbox)

                if restartFinder {
                    ResultBanner(
                        kind: .warn,
                        title: loc.t("Окна Finder закроются", "Finder windows will close"),
                        detail: loc.t("Перед запуском появится подтверждение.",
                                      "You'll be asked to confirm before anything happens.")
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    // MARK: Действия

    private var actionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 13) {
                Text(loc.t("Действия", "Actions")).font(.system(size: 13, weight: .semibold))

                HStack(spacing: 10) {
                    Button {
                        restartFinder ? confirmFinder = true : launch()
                    } label: {
                        Text(loc.t("Починить AirDrop", "Fix AirDrop")).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!tool.isSupported || tool.isBusy)

                    Button(loc.t("Только посмотреть", "Just look")) {
                        Task { await tool.run(["list"]) }
                    }
                    .controlSize(.large)
                    .disabled(tool.isBusy)
                    .help(loc.t("Показать, что нашлось, ничего не трогая",
                                "Show what was found without touching anything"))
                }

                if tool.isRunning { BusyLabel(text: loc.t("Выполняю…", "Working…")) }
            }
        }
    }

    private func launch() {
        var args = ["fix"]
        if restartFinder { args.append("--finder") }
        if restartAWDL { args.append("--wifi") }
        Task { await tool.run(args) }
    }
}
