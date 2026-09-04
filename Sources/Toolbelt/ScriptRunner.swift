import Foundation

/// Результат прогона скрипта: человекочитаемый журнал плюс разобранные
/// служебные строки вида `@@KEY=value`, которые скрипты печатают для UI.
struct ScriptOutput {
    var log: String = ""
    var meta: [String: String] = [:]
    var exitCode: Int32 = 0

    var succeeded: Bool { meta["RESULT"] == "ok" && exitCode == 0 }
    var summary: String {
        meta["SUMMARY"] ?? (succeeded ? "Готово" : "Не удалось выполнить")
    }
    subscript(_ key: String) -> String? { meta[key] }
    func flag(_ key: String) -> Bool { meta[key] == "yes" }
}

/// Собирает вывод процесса. Данные приходят кусками из фонового потока,
/// границы кусков не совпадают с границами строк — класс копит хвост под
/// замком и отдаёт наружу только целые строки.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private var output = ScriptOutput()
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func consume(_ chunk: String) {
        lock.lock()
        pending += chunk
        var ready: [String] = []
        while let idx = pending.firstIndex(of: "\n") {
            ready.append(String(pending[pending.startIndex..<idx]))
            pending = String(pending[pending.index(after: idx)...])
        }
        lock.unlock()
        ready.forEach(handle)
    }

    func flush() {
        lock.lock()
        let tail = pending
        pending = ""
        lock.unlock()
        if !tail.isEmpty { handle(tail) }
    }

    func finish(exitCode: Int32) -> ScriptOutput {
        lock.lock(); defer { lock.unlock() }
        output.exitCode = exitCode
        return output
    }

    private func handle(_ line: String) {
        if line.hasPrefix("@@"), let eq = line.firstIndex(of: "=") {
            let key = String(line[line.index(line.startIndex, offsetBy: 2)..<eq])
            let value = String(line[line.index(after: eq)...])
            lock.lock(); output.meta[key] = value; lock.unlock()
            return   // служебные строки в журнал не попадают
        }
        lock.lock(); output.log += line + "\n"; lock.unlock()
        let callback = onLine
        DispatchQueue.main.async { callback(line) }
    }
}

enum ScriptRunner {

    enum Failure: LocalizedError {
        case notFound(String)
        var errorDescription: String? {
            switch self {
            case .notFound(let name): return "Скрипт \(name).sh не найден в приложении"
            }
        }
    }

    /// Ищет скрипт в ресурсах бандла; при запуске из исходников — в папке проекта.
    static func url(for name: String) throws -> URL {
        if let u = Bundle.main.url(forResource: name, withExtension: "sh") { return u }
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Scripts/\(name).sh")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        throw Failure.notFound(name)
    }

    static func source(of name: String) -> String {
        (try? url(for: name)).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "Не удалось прочитать скрипт \(name).sh"
    }

    /// Запускает скрипт и отдаёт строки журнала по мере появления.
    /// `onLine` вызывается на главной очереди — можно писать прямо в @Published.
    static func run(_ name: String,
                    arguments: [String],
                    onLine: @escaping (String) -> Void) async -> ScriptOutput {
        let scriptURL: URL
        do { scriptURL = try url(for: name) }
        catch {
            let text = error.localizedDescription
            await MainActor.run { onLine(text) }
            return ScriptOutput(log: text, meta: ["RESULT": "fail", "SUMMARY": text], exitCode: 127)
        }

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptURL.path] + arguments
            // Скрипты печатают по-русски; без этого bash/awk могут ломать вывод.
            var env = ProcessInfo.processInfo.environment
            env["LANG"] = "ru_RU.UTF-8"
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let collector = Collector(onLine: onLine)

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                collector.consume(String(decoding: data, as: UTF8.self))
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                if !rest.isEmpty { collector.consume(String(decoding: rest, as: UTF8.self)) }
                collector.flush()
                continuation.resume(returning: collector.finish(exitCode: proc.terminationStatus))
            }

            do { try process.run() }
            catch {
                let message = "Не удалось запустить скрипт: \(error.localizedDescription)"
                var out = ScriptOutput()
                out.exitCode = 126
                out.meta["RESULT"] = "fail"
                out.meta["SUMMARY"] = message
                continuation.resume(returning: out)
            }
        }
    }
}
