import SwiftUI

struct InputSourceView: View {
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
                title: "Переключение раскладки",
                subtitle: """
                Штатная галка «Caps Lock переключает раскладку» при быстром наборе \
                теряет нажатия. Здесь Caps Lock перекладывается на F18 в драйвере \
                клавиатуры, а на F18 вешается системный шорткат смены языка — этот \
                путь не пропускает нажатия и переживает перезагрузку.
                """
            ),
            script: (tool.scriptTitle, tool.source),
            showScript: $showScript
        ) {
            diagnosticsCard
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
        .task { if !tool.checked { await tool.check() } }
        .confirmationDialog(
            "Откатить изменения?",
            isPresented: $confirmRevert,
            titleVisibility: .visible
        ) {
            Button("Откатить", role: .destructive) { Task { await tool.run(["revert"]) } }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("""
            Caps Lock снова станет обычным Caps Lock, автозагрузка ремапа удалится, \
            шорткат смены языка вернётся к значению, которое было до применения фикса.
            """)
        }
    }

    // MARK: Проверка системы

    private var diagnosticsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text("Проверка системы").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if tool.isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            Task { await tool.check() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Проверить заново")
                    }
                }

                Divider()

                if !tool.checked {
                    BusyLabel(text: "Проверяю систему…")
                } else {
                CheckRow(title: "Версия macOS", value: tool.macOSVersion,
                         kind: tool.isSupported ? .ok : .fail,
                         hint: tool.isSupported ? "фикс поддерживается" : "нужна macOS 11 или новее")

                CheckRow(title: "Права администратора", value: tool.needsRoot ? "нужны" : "не нужны",
                         kind: .ok,
                         hint: "меняются только настройки текущего пользователя")

                CheckRow(title: "Раскладок включено", value: "\(layouts)",
                         kind: layouts >= 2 ? .ok : .warn,
                         hint: layouts >= 2 ? nil : "добавьте вторую раскладку, иначе переключать нечего")

                if d?.flag("CAPS_NOACTION") == true {
                    CheckRow(title: "Caps Lock в «Modifier Keys»", value: "Нет действия",
                             kind: .warn, hint: "фикс вернёт клавише действие по умолчанию")
                }

                CheckRow(title: "Состояние фикса", value: applied ? "применён" : "не применён",
                         kind: applied ? .ok : .idle)
                }
            }
        }
    }

    // MARK: Действия

    private var actionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 13) {
                Text("Действия").font(.system(size: 13, weight: .semibold))

                Text(applied
                     ? "Фикс уже стоит. Повторное применение безопасно — оно просто перезапишет настройки."
                     : "Приложение переложит Caps Lock на F18, поставит автозагрузку ремапа и назначит системный шорткат смены языка.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        Task { await tool.run(["apply"]) }
                    } label: {
                        Text(applied ? "Применить заново" : "Применить")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!tool.isSupported || tool.isBusy)

                    Button("Откатить") { confirmRevert = true }
                        .controlSize(.large)
                        .disabled(!hasBackup || tool.isBusy)
                        .help(hasBackup
                              ? "Вернуть состояние, которое было до применения"
                              : "Откатывать нечего: фикс через это приложение не применялся")
                }

                if tool.isRunning {
                    BusyLabel(text: "Выполняю…")
                }
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
                        Label("Показать весь скрипт", systemImage: "curlybraces")
                    }
                    .help("Открыть исходный код с комментариями")
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
