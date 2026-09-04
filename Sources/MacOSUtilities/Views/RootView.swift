import SwiftUI

struct RootView: View {
    @State private var selection: Tool
    @StateObject private var keepAwake = KeepAwake()
    @StateObject private var loc = Localization()

    init(initial: Tool = .inputSource) {
        _selection = State(initialValue: initial)
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Обычный List с тегами, без NavigationLink: колонка деталей
                // строится ниже по selection, отдельный стек навигации не нужен.
                List(selection: $selection) {
                    Section(loc.t("Утилиты", "Utilities")) {
                        ForEach(Tool.allCases) { tool in
                            row(for: tool).tag(tool)
                        }
                    }
                }
                .listStyle(.sidebar)

                Divider()
                HStack(spacing: 8) {
                    Text("MacOS Utilities \(AppInfo.version)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    Picker("", selection: $loc.lang) {
                        ForEach(Lang.allCases) { l in Text(l.label).tag(l) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 76)
                    .help(loc.t("Язык интерфейса", "Interface language"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            // Ширина подобрана под самую длинную строку боковой панели
            // (152 pt у «Caps Lock переключает язык») плюс иконка, отступы
            // и место под точку активного режима — подсказки не обрезаются
            // ни на русском, ни на английском.
            .navigationSplitViewColumnWidth(min: 244, ideal: 244, max: 300)
        } detail: {
            switch selection {
            case .inputSource: InputSourceView()
            case .airdrop:     AirDropView()
            case .keepAwake:   KeepAwakeView()
            }
        }
        .environmentObject(keepAwake)
        .environmentObject(loc)
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
                Text(tool.title(loc)).font(.system(size: 13, weight: .medium))
                Text(tool.blurb(loc))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
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
