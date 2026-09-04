import SwiftUI

struct AirDropView: View {
    @StateObject private var tool: ScriptTool

    init(tool: ScriptTool = ScriptTool(scriptName: "airdrop-fix",
                                       scriptTitle: "airdrop-fix.sh")) {
        _tool = StateObject(wrappedValue: tool)
    }

    @State private var showScript = false
    @State private var restartFinder = false
    @State private var bounceAWDL = false
    @State private var threshold = 120
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
                title: "Зависший AirDrop",
                subtitle: """
                Окно «Поделиться → AirDrop» рисуют расширения Finder. Иногда окно \
                закрывают, а расширения не выходят: процессы висят неделями, держат \
                отправляемый файл и всплывают поверх других окон. Раздел находит их, \
                снимает и перезапускает службу AirDrop — без перезагрузки Mac.
                """
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
                    title: tool.resultKind == .ok ? "Готово" : "Не выполнено",
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
        .task { if !tool.checked { await tool.check() } }
        // Предупреждение показывается ДО запуска, а не после: перезапуск Finder
        // закрывает окна Finder и на секунду гасит рабочий стол.
        .alert("Finder будет перезапущен", isPresented: $confirmFinder) {
            Button("Продолжить") { launch() }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("""
            Все открытые окна Finder закроются, рабочий стол на секунду моргнёт и \
            перерисуется. Несохранённые операции копирования в Finder прервутся. \
            Остальные программы это не затронет.
            """)
        }
    }

    // MARK: Проверка

    private var diagnosticsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text("Проверка системы").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if tool.isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { Task { await tool.check() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Просканировать заново")
                    }
                }

                Divider()

                if !tool.checked {
                    BusyLabel(text: "Проверяю систему…")
                } else {
                CheckRow(title: "Версия macOS", value: tool.macOSVersion,
                         kind: tool.isSupported ? .ok : .fail,
                         hint: tool.isSupported ? "фикс поддерживается" : "нужна macOS 11 или новее")

                CheckRow(title: "Права администратора",
                         value: bounceAWDL ? "нужны" : "не нужны",
                         kind: .ok,
                         hint: bounceAWDL
                               ? "пароль спросит система — только для перезапуска awdl0"
                               : "снимаются собственные процессы пользователя")

                CheckRow(title: "Служба sharingd", value: sharingdUp ? "работает" : "не запущена",
                         kind: sharingdUp ? .ok : .warn)

                CheckRow(title: "Хелперов AirDrop найдено", value: "\(found)",
                         kind: stale > 0 ? .warn : .ok,
                         hint: stale > 0 ? "из них зависших: \(stale)" : "зависших нет")
                }
            }
        }
    }

    // MARK: Параметры

    private var optionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Параметры").font(.system(size: 13, weight: .semibold))

                Picker("Считать зависшим процесс старше", selection: $threshold) {
                    Text("30 секунд").tag(30)
                    Text("2 минут").tag(120)
                    Text("10 минут").tag(600)
                    Text("любого возраста").tag(0)
                }
                .pickerStyle(.menu)
                .font(.system(size: 12.5))

                Toggle(isOn: $restartFinder) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Перезапустить Finder").font(.system(size: 12.5))
                        Text("если окно AirDrop нарисовано, но не откликается")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: $bounceAWDL) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Передёрнуть интерфейс awdl0").font(.system(size: 12.5))
                        Text("лечит «Mac не видит iPhone» · потребуется пароль администратора")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .toggleStyle(.checkbox)

                if restartFinder {
                    ResultBanner(
                        kind: .warn,
                        title: "Окна Finder закроются",
                        detail: "Рабочий стол моргнёт и перерисуется. Перед запуском появится подтверждение."
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
                Text("Действия").font(.system(size: 13, weight: .semibold))

                HStack(spacing: 10) {
                    Button {
                        restartFinder ? confirmFinder = true : launch()
                    } label: {
                        Text("Починить AirDrop").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!tool.isSupported || tool.isBusy)

                    Button("Только показать") {
                        Task { await tool.run(["list", "--age", "\(threshold)"]) }
                    }
                    .controlSize(.large)
                    .disabled(tool.isBusy)
                    .help("Вывести список процессов, ничего не трогая")
                }

                if tool.isRunning { BusyLabel(text: "Выполняю…") }
            }
        }
    }

    private func launch() {
        var args = ["fix", "--age", "\(threshold)"]
        if restartFinder { args.append("--finder") }
        if bounceAWDL { args.append("--awdl") }
        Task { await tool.run(args) }
    }
}
