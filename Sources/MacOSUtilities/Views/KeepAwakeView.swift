import SwiftUI

/// Нажатие отзывается сразу, а не по отпусканию — так кнопка ощущается живой.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 1.0), value: configuration.isPressed)
    }
}

struct KeepAwakeView: View {
    @EnvironmentObject private var keepAwake: KeepAwake
    @State private var showScript = false

    var body: some View {
        ToolPage(
            header: PageHeader(
                symbol: Tool.keepAwake.symbol,
                tint: Tool.keepAwake.tint,
                title: "Mac не уходит в сон",
                subtitle: """
                Пока тумблер включён, Mac не засыпает и не рвёт сетевые соединения — \
                долгая задача нейросети-агента или выгрузка не оборвутся на середине. \
                Экран при этом продолжает гаснуть по системному таймеру: подсветка \
                не тратится впустую, машина остаётся в работе.
                """
            ),
            script: nil,
            showScript: $showScript
        ) {
            bigToggle
            infoCard
        }
        .animation(.calm, value: keepAwake.isOn)
        .task { keepAwake.refreshDisplaySleep() }
    }

    // MARK: Главный тумблер

    private var bigToggle: some View {
        Button {
            keepAwake.toggle()
        } label: {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(keepAwake.isOn
                              ? AnyShapeStyle(Color.white.opacity(0.18))
                              : AnyShapeStyle(Color.primary.opacity(0.06)))
                        .frame(width: 84, height: 84)
                    Image(systemName: keepAwake.isOn ? "bolt.fill" : "bolt.slash")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(keepAwake.isOn ? .white : Color.secondary)
                }

                VStack(spacing: 5) {
                    Text(keepAwake.isOn ? "Включено" : "Выключено")
                        .font(.system(size: 20, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(keepAwake.isOn ? .white : .primary)

                    if keepAwake.isOn {
                        TimelineView(.periodic(from: .now, by: 15)) { _ in
                            Text("режим держится \(keepAwake.uptimeText)")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    } else {
                        Text("нажмите, чтобы Mac перестал засыпать")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(keepAwake.isOn
                          ? AnyShapeStyle(Color.green.gradient)
                          : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(keepAwake.isOn ? Color.clear : Color.primary.opacity(0.08),
                                  lineWidth: 1)
            )
            .shadow(color: keepAwake.isOn ? Color.green.opacity(0.25) : .clear, radius: 14, y: 5)
        }
        .buttonStyle(PressScale())
    }

    // MARK: Что именно происходит

    private var infoCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 11) {
                Text("Что делает режим").font(.system(size: 13, weight: .semibold))
                Divider()

                CheckRow(title: "Сон системы по бездействию",
                         value: keepAwake.isOn ? "заблокирован" : "по настройкам",
                         kind: keepAwake.isOn ? .ok : .idle,
                         hint: "штатное утверждение питания IOKit, как у команды caffeinate")

                CheckRow(title: "Сетевые соединения",
                         value: keepAwake.isOn ? "удерживаются" : "по настройкам",
                         kind: keepAwake.isOn ? .ok : .idle,
                         hint: "Wi-Fi и VPN не рвутся при простое")

                CheckRow(title: "Экран гаснет через",
                         value: displaySleepText,
                         kind: .idle,
                         hint: "не блокируется — подсветка выключается как обычно")

                Divider()

                HStack(spacing: 10) {
                    Button("Настройки экрана") { keepAwake.openDisplaySettings() }
                    Spacer()
                }

                Text("""
                Режим действует, пока приложение запущено. Закроете приложение — Mac \
                вернётся к обычным настройкам сна. Состояние тумблера запоминается: \
                при следующем запуске режим включится сам.
                """)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var displaySleepText: String {
        guard let m = keepAwake.displaySleepMinutes else { return "—" }
        return m == 0 ? "никогда" : "\(m) мин"
    }
}
