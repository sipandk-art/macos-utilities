import SwiftUI

// MARK: - Оформление

enum Metrics {
    static let cardRadius: CGFloat = 12
    static let gutter: CGFloat = 20
    static let cardPadding: CGFloat = 16
    static let stack: CGFloat = 14
}

/// Пружина без перелёта — состояние карточек меняется мягко, но не «пружинит»:
/// перелёт уместен там, где был бросок пальцем, а не там, где сменился статус.
extension Animation {
    static let calm = Animation.spring(response: 0.34, dampingFraction: 1.0)
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.cardPadding)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

// MARK: - Заголовок раздела

struct PageHeader: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(tint.gradient)
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .shadow(color: tint.opacity(0.28), radius: 6, y: 2)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.3)          // крупный текст читается плотнее
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Шапка карточки: название и кнопка повторной проверки. Пока проверка идёт,
/// вместо кнопки крутится индикатор — нажимать всё равно нечего.
struct CardHeader: View {
    let title: String
    let busy: Bool
    let hint: String
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Button(action: action) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(hint)
            }
        }
    }
}

// MARK: - Статусы

enum StatusKind {
    case idle, running, ok, warn, fail

    var symbol: String {
        switch self {
        case .idle:    return "circle.dashed"
        case .running: return "clock"
        case .ok:      return "checkmark.circle.fill"
        case .warn:    return "exclamationmark.triangle.fill"
        case .fail:    return "xmark.octagon.fill"
        }
    }
    var color: Color {
        switch self {
        case .idle:    return .secondary
        case .running: return .accentColor
        case .ok:      return .green
        case .warn:    return .orange
        case .fail:    return .red
        }
    }
}

struct StatusPill: View {
    let kind: StatusKind
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(kind.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(kind.color.opacity(0.12)))
    }
}

/// Строка «параметр — значение» с иконкой состояния. Из таких строк собран
/// блок диагностики: всё, что приложение проверило перед запуском.
struct CheckRow: View {
    let title: String
    let value: String
    var kind: StatusKind = .ok
    var hint: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: kind.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(kind.color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5))
                if let hint {
                    Text(hint).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Итог операции

struct ResultBanner: View {
    let kind: StatusKind
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: kind.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(kind.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(kind.color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(kind.color.opacity(0.22), lineWidth: 1)
        )
    }
}

// MARK: - Журнал выполнения

struct LogPanel: View {
    let lines: [String]
    @EnvironmentObject private var loc: Localization
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.calm) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(loc.t("Журнал выполнения", "Activity log"))
                        .font(.system(size: 12, weight: .medium))
                    Text("\(lines.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView {
                    Text(lines.joined(separator: "\n"))
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 170)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Модальное окно с исходником скрипта

struct ScriptSheet: View {
    let title: String
    let script: String
    @EnvironmentObject private var loc: Localization
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "curlybraces")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(loc.t("Ровно этот код приложение и выполняет — ничего скрытого",
                               "This is exactly the code the app runs — nothing hidden"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(script, forType: .string)
                    withAnimation(.calm) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        withAnimation(.calm) { copied = false }
                    }
                } label: {
                    Label(copied ? loc.t("Скопировано", "Copied")
                                : loc.t("Копировать", "Copy"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button(loc.t("Закрыть", "Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            ScrollView([.vertical, .horizontal]) {
                Text(script)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(width: 760, height: 560)
    }
}

// MARK: - Мелочи

/// Кнопка «Поделиться»: кладёт ссылку на репозиторий в буфер обмена
/// и на пару секунд подтверждает это на себе же.
struct ShareRepoButton: View {
    @EnvironmentObject private var loc: Localization
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(AppInfo.repositoryURL, forType: .string)
            withAnimation(.calm) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation(.calm) { copied = false }
            }
        } label: {
            Label(copied ? loc.t("Ссылка скопирована", "Link copied")
                        : loc.t("Поделиться", "Share"),
                  systemImage: copied ? "checkmark" : "square.and.arrow.up")
        }
        .help(AppInfo.repositoryURL)
    }
}

struct BusyLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}
