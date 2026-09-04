import SwiftUI

struct RootView: View {
    @State private var selection: Tool
    @StateObject private var keepAwake = KeepAwake()

    init(initial: Tool = .inputSource) {
        _selection = State(initialValue: initial)
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Обычный List с тегами, без NavigationLink: колонка деталей
                // строится ниже по selection, отдельный стек навигации не нужен.
                List(selection: $selection) {
                    Section("Утилиты") {
                        ForEach(Tool.allCases) { tool in
                            row(for: tool).tag(tool)
                        }
                    }
                }
                .listStyle(.sidebar)

                Divider()
                HStack {
                    Text("MacOS Utilities \(AppInfo.version)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
            .navigationSplitViewColumnWidth(min: 212, ideal: 212, max: 250)
        } detail: {
            switch selection {
            case .inputSource: InputSourceView()
            case .airdrop:     AirDropView()
            case .keepAwake:   KeepAwakeView()
            }
        }
        .environmentObject(keepAwake)
        // Опрос настроек питания и восстановление тумблера — после первого
        // прохода отрисовки: менять @Published прямо в init() нельзя, SwiftUI
        // ловит это как правку состояния внутри обновления вида.
        .task { keepAwake.bootstrap() }
    }

    private func row(for tool: Tool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: tool.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tool.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.title).font(.system(size: 13, weight: .medium))
                Text(tool.blurb)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // Зелёная точка: keep-alive виден из любого раздела.
            if tool == .keepAwake && keepAwake.isOn {
                Circle().fill(Color.green).frame(width: 7, height: 7)
            }
        }
        .padding(.vertical, 3)
    }
}
