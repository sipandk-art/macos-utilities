import AppKit
import SwiftUI

/// Режим `--snapshot <папка>`: приложение отрисовывает каждый раздел в PNG
/// и завершается. Нужен для ревью вёрстки без ручного открытия окна —
/// на обычный запуск не влияет.
///
/// Рисуется именно содержимое раздела: боковая панель — системный List,
/// её вид задаёт macOS, а проверять надо свою вёрстку карточек.
enum Snapshot {

    static var isRequested: Bool { CommandLine.arguments.contains("--snapshot") }
    static var isMeasureRequested: Bool { CommandLine.arguments.contains("--measure") }

    /// `--measure`: печатает идеальную высоту каждого раздела при заданной ширине.
    /// По самому высокому и выставлен размер окна по умолчанию, чтобы в исходном
    /// состоянии не появлялась вертикальная прокрутка.
    static func measure() {
        Task { @MainActor in
            let width = CommandLine.arguments
                .drop(while: { $0 != "--measure" }).dropFirst().first
                .flatMap(Double.init) ?? 668
            let keepAwake = KeepAwake()
            keepAwake.refreshDisplaySleep()
            let loc = Localization()
            let inputTool = ScriptTool(scriptName: "input-source-fix",
                                       scriptTitle: "input-source-fix.sh")
            let airdropTool = ScriptTool(scriptName: "airdrop-fix",
                                         scriptTitle: "airdrop-fix.sh")
            await inputTool.check()
            await airdropTool.check()

            for tool in Tool.allCases {
                let page = pageView(tool, inputTool: inputTool, airdropTool: airdropTool)
                    .environmentObject(keepAwake)
                    .environmentObject(loc)
                    .environment(\.snapshotMode, true)
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                let renderer = ImageRenderer(content: page)
                renderer.scale = 1
                let h = renderer.nsImage?.size.height ?? 0
                print("\(tool.rawValue): \(Int(h.rounded()))")
            }
            NSApp.terminate(nil)
        }
    }

    static func run() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else {
            NSApp.terminate(nil); return
        }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // ImageRenderer не запускает .task, поэтому диагностику прогоняем сами
        // и отдаём разделам уже заполненный ScriptTool — иначе на снимке
        // остался бы бесконечный «Проверяю систему…».
        Task { @MainActor in
            let keepAwake = KeepAwake()
            keepAwake.refreshDisplaySleep()
            let loc = Localization()

            let inputTool = ScriptTool(scriptName: "input-source-fix",
                                       scriptTitle: "input-source-fix.sh")
            let airdropTool = ScriptTool(scriptName: "airdrop-fix",
                                         scriptTitle: "airdrop-fix.sh")
            await inputTool.check()
            await airdropTool.check()

            for tool in Tool.allCases {
                let page = pageView(tool, inputTool: inputTool, airdropTool: airdropTool)
                    .environmentObject(keepAwake)
                    .environmentObject(loc)
                    .environment(\.snapshotMode, true)
                    .frame(width: 660, height: 700)
                write(page, to: dir.appendingPathComponent("\(tool.rawValue).png"))
            }
            // Второй кадр keep-alive — во включённом состоянии.
            keepAwake.enable()
            write(KeepAwakeView().environmentObject(keepAwake).environmentObject(loc)
                    .environment(\.snapshotMode, true).frame(width: 660, height: 700),
                  to: dir.appendingPathComponent("keepAwake-on.png"))
            keepAwake.disable()
            NSApp.terminate(nil)
        }
    }

    @ViewBuilder @MainActor
    private static func pageView(_ tool: Tool,
                                 inputTool: ScriptTool,
                                 airdropTool: ScriptTool) -> some View {
        switch tool {
        case .inputSource: InputSourceView(tool: inputTool)
        case .airdrop:     AirDropView(tool: airdropTool)
        case .keepAwake:   KeepAwakeView()
        }
    }

    @MainActor
    private static func write<V: View>(_ view: V, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("не удалось отрисовать \(url.lastPathComponent)\n".utf8))
            return
        }
        try? png.write(to: url)
        FileHandle.standardError.write(Data("снято: \(url.lastPathComponent)\n".utf8))
    }
}
