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
        let out = await ScriptRunner.run(scriptName, arguments: ["check"]) { _ in }
        diagnostics = out
        isChecking = false
    }

    /// Запуск действия. Журнал очищается, строки прилетают по мере выполнения.
    func run(_ arguments: [String]) async {
        guard !isBusy else { return }
        isRunning = true
        log = []
        lastRun = nil
        let out = await ScriptRunner.run(scriptName, arguments: arguments) { [weak self] line in
            guard let self, !line.isEmpty else { return }
            self.log.append(line)
        }
        lastRun = out
        isRunning = false
        await check()      // состояние на карточке пересобирается по факту
    }

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

    var title: String {
        switch self {
        case .inputSource: return "Раскладка"
        case .airdrop:     return "AirDrop"
        case .keepAwake:   return "Не спать"
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
        case .airdrop:     return .indigo
        case .keepAwake:   return .green
        }
    }
    /// Короткая строка под названием в боковой панели — чтобы раздел был понятен
    /// до того, как в него зашли.
    var blurb: String {
        switch self {
        case .inputSource: return "Caps Lock переключает язык"
        case .airdrop:     return "Снять зависший AirDrop"
        case .keepAwake:   return "Mac не уходит в сон"
        }
    }
}
