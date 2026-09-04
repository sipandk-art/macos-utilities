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
    @EnvironmentObject private var loc: Localization
    @State private var showScript = false

    var body: some View {
        ToolPage(
            header: PageHeader(
                symbol: Tool.keepAwake.symbol,
                tint: Tool.keepAwake.tint,
                title: loc.t("Mac не уходит в сон", "Keeping the Mac awake"),
                subtitle: loc.t(
                    """
                    Пока режим включён, Mac не засыпает и не теряет интернет — долгая \
                    задача не оборвётся на середине. Экран при этом гаснет как обычно.
                    """,
                    """
                    While this is on, your Mac won't fall asleep or lose its internet \
                    connection, so a long task won't be cut off halfway. The screen still \
                    turns off as usual.
                    """)
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
                    Text(keepAwake.isOn ? loc.t("Включено", "On") : loc.t("Выключено", "Off"))
                        .font(.system(size: 20, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(keepAwake.isOn ? .white : .primary)

                    Text(keepAwake.isOn
                         ? loc.t("нажмите, чтобы Mac снова засыпал", "click to let the Mac sleep again")
                         : loc.t("нажмите, чтобы Mac перестал засыпать", "click to keep the Mac awake"))
                        .font(.system(size: 12))
                        .foregroundStyle(keepAwake.isOn ? AnyShapeStyle(Color.white.opacity(0.85))
                                                        : AnyShapeStyle(Color.secondary))
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
                Text(loc.t("Что происходит", "What this does"))
                    .font(.system(size: 13, weight: .semibold))
                Divider()

                CheckRow(title: loc.t("Уход в сон", "Falling asleep"),
                         value: keepAwake.isOn ? loc.t("запрещён", "blocked")
                                               : loc.t("как в настройках", "as set in Settings"),
                         kind: keepAwake.isOn ? .ok : .idle)

                CheckRow(title: loc.t("Интернет", "Internet"),
                         value: keepAwake.isOn ? loc.t("не отключается", "stays connected")
                                               : loc.t("как в настройках", "as set in Settings"),
                         kind: keepAwake.isOn ? .ok : .idle,
                         hint: loc.t("Wi-Fi и VPN не рвутся при простое",
                                     "Wi-Fi and VPN don't drop while idle"))

                CheckRow(title: loc.t("Экран гаснет через", "The screen turns off after"),
                         value: displaySleepText,
                         kind: .idle,
                         hint: loc.t("не меняется — подсветка выключается как обычно",
                                     "unchanged — the backlight goes off as usual"))

                Divider()

                HStack(spacing: 10) {
                    Button(loc.t("Настройки экрана", "Screen settings")) {
                        keepAwake.openDisplaySettings()
                    }
                    Spacer()
                }

                Text(loc.t(
                    """
                    Режим работает, пока открыто приложение. Закроете — Mac вернётся \
                    к обычным настройкам сна. Положение переключателя запоминается: \
                    при следующем запуске режим включится сам.
                    """,
                    """
                    This works while the app is open. Quit it and your Mac goes back to its \
                    normal sleep settings. The switch remembers its position: next time you \
                    open the app it turns itself back on.
                    """))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var displaySleepText: String {
        guard let m = keepAwake.displaySleepMinutes else { return "—" }
        return m == 0 ? loc.t("никогда", "never") : loc.t("\(m) мин", "\(m) min")
    }
}
