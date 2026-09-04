import SwiftUI

/// Обёртка над одним bash-скриптом: диагностика, запуск действий, журнал.
/// Оба «чинящих» раздела устроены одинаково, поэтому логика здесь одна на двоих.
@MainActor
final class ScriptTool: ObservableObject {

    let scriptName: String
    let scriptTitle: String

    @Published private(set) var diagnostics: ScriptOutput?
    @Published private(set) var lastRun: ScriptOutput?
    @Published private(set) var isChecking = false
    @Published private(set) var isRunning = false
    @Published private(set) var log: [String] = []

    /// Язык, с которым запускаются скрипты: их вывод идёт в журнал и в баннер
    /// с итогом, значит должен быть на языке интерфейса.
    var lang: Lang = .ru

    // nonisolated: объект создаётся как значение по умолчанию в init разделов,
    // а там ещё нет главного актора. Присваиваются только два let.
    nonisolated init(scriptName: String, scriptTitle: String) {
        self.scriptName = scriptName
        self.scriptTitle = scriptTitle
    }

    var source: String { ScriptRunner.source(of: scriptName) }
    var isBusy: Bool { isChecking || isRunning }

    /// Диагностика перед действием: подходит ли версия macOS, нужны ли права,
    /// в каком состоянии система сейчас. Кнопка действия до этого не активна.
    func check() async {
        guard !isBusy else { return }
        isChecking = true
        let out = await ScriptRunner.run(scriptName, arguments: ["check"] + langArgs) { _ in }
        diagnostics = out
        isChecking = false
    }

    /// Запуск действия. Журнал очищается, строки прилетают по мере выполнения.
    func run(_ arguments: [String]) async {
        guard !isBusy else { return }
        isRunning = true
        log = []
        lastRun = nil
        let out = await ScriptRunner.run(scriptName, arguments: arguments + langArgs) { [weak self] line in
            guard let self, !line.isEmpty else { return }
            self.log.append(line)
        }
        lastRun = out
        isRunning = false
        await check()      // состояние на карточке пересобирается по факту
    }

    private var langArgs: [String] { ["--lang", lang.rawValue] }

    // Значения диагностики, к которым обращаются экраны.
    var macOSVersion: String { diagnostics?["MACOS"] ?? "—" }
    var isSupported: Bool { diagnostics?.flag("SUPPORTED") ?? false }
    var needsRoot: Bool { diagnostics?.flag("NEEDS_ROOT") ?? false }
    var checked: Bool { diagnostics != nil }

    var resultKind: StatusKind {
        guard let lastRun else { return .idle }
        return lastRun.succeeded ? .ok : .fail
    }
}

/// Разделы приложения. Порядок здесь = порядок в боковой панели.
enum Tool: String, CaseIterable, Identifiable {
    case inputSource, airdrop, keepAwake

    var id: String { rawValue }

    @MainActor func title(_ loc: Localization) -> String {
        switch self {
        case .inputSource: return loc.t("Раскладка", "Keyboard")
        case .airdrop:     return loc.t("AirDrop", "AirDrop")
        case .keepAwake:   return loc.t("Не спать", "Stay awake")
        }
    }

    /// Строка под названием в боковой панели — чтобы раздел был понятен
    /// до того, как в него зашли.
    @MainActor func blurb(_ loc: Localization) -> String {
        switch self {
        case .inputSource: return loc.t("Caps Lock переключает язык", "Caps Lock switches language")
        case .airdrop:     return loc.t("Снять зависший AirDrop", "Unstick AirDrop")
        case .keepAwake:   return loc.t("Mac не уходит в сон", "Keep the Mac awake")
        }
    }

    var symbol: String {
        switch self {
        case .inputSource: return "keyboard"
        case .airdrop:     return "dot.radiowaves.right"
        case .keepAwake:   return "bolt.fill"
        }
    }
    var tint: Color {
        switch self {
        case .inputSource: return .blue
        case .airdrop:     return .teal
        case .keepAwake:   return .green
        }
    }
}
