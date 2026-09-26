import SwiftUI

struct ClipboardView: View {
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var history: ClipboardHistory
    @State private var showScript = false
    @State private var justCopied: UUID?
    @State private var hasAccessibility = Permissions.hasAccessibility
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        ToolPage(
            header: PageHeader(
                symbol: Tool.clipboard.symbol,
                tint: Tool.clipboard.tint,
                title: loc.t("История буфера обмена", "Clipboard history"),
                subtitle: loc.t(
                    """
                    Обычно в буфере лежит только последнее скопированное. Здесь — всё, \
                    что вы копировали. Выберите запись в меню значка или по ⌃⌘V — она \
                    сразу вставится туда, где стоит курсор.
                    """,
                    """
                    Normally the clipboard holds only the last thing you copied. Here you \
                    get everything. Pick an entry from the menu bar icon or with ⌃⌘V and \
                    it's pasted right where your cursor is.
                    """)
            ),
            script: nil,
            showScript: $showScript
        ) {
            mainToggle
            if history.isEnabled { settingsCard }
            listCard
        }
        .animation(.calm, value: history.isEnabled)
        .animation(.calm, value: history.items)
        .task { hasAccessibility = Permissions.hasAccessibility }
    }

    // MARK: Главный переключатель

    private var mainToggle: some View {
        Card {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(history.isEnabled ? loc.t("Включено", "On") : loc.t("Выключено", "Off"))
                        .font(.system(size: 15, weight: .semibold))
                    Text(statusText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: Binding(get: { history.isEnabled }, set: { history.isEnabled = $0 }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }

    private var statusText: String {
        guard history.isEnabled else {
            return loc.t("История не ведётся — ничего не записывается",
                         "Nothing is being recorded")
        }
        let n = history.items.count
        return n == 0
            ? loc.t("Скопируйте что-нибудь — оно появится здесь", "Copy something — it will show up here")
            : loc.t("Записей: \(n) · открыть историю: ⌃⌘V или значок в строке меню",
                    "Entries: \(n) · open history: ⌃⌘V or the menu bar icon")
    }

    // MARK: Настройки

    private var settingsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 11) {
                Picker(selection: Binding(get: { history.limit }, set: { history.limit = $0 })) {
                    ForEach(ClipboardHistory.limits, id: \.self) { Text("\($0)").tag($0) }
                } label: {
                    Text(loc.t("Хранить последних", "Keep the last")).font(.system(size: 12.5))
                }
                .pickerStyle(.menu)
                .fixedSize()

                Toggle(isOn: Binding(get: { history.pasteImmediately },
                                     set: { history.pasteImmediately = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc.t("Вставлять сразу после выбора", "Paste right after picking"))
                            .font(.system(size: 12.5))
                        Text(loc.t("иначе запись просто окажется в буфере — вставите ⌘V сами",
                                   "otherwise the entry just lands in the clipboard for your own ⌘V"))
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .toggleStyle(.checkbox)

                if history.pasteImmediately && !hasAccessibility {
                    HStack(spacing: 8) {
                        Image(systemName: StatusKind.warn.symbol)
                            .foregroundStyle(StatusKind.warn.color)
                            .font(.system(size: 11, weight: .semibold))
                        Text(loc.t("Чтобы вставлять за вас, нужен универсальный доступ",
                                   "Pasting for you needs Accessibility access"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button(loc.t("Выдать", "Grant")) {
                            Permissions.requestAccessibility()
                            Permissions.openSettings(.accessibility)
                        }
                        .controlSize(.small)
                        Button {
                            hasAccessibility = Permissions.hasAccessibility
                        } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(loc.t("Проверить заново", "Check again"))
                    }
                }

                Toggle(isOn: Binding(get: { history.hotkeyEnabled }, set: { history.hotkeyEnabled = $0 })) {
                    Text(loc.t("Открывать историю сочетанием ⌃⌘V", "Open the history with ⌃⌘V"))
                        .font(.system(size: 12.5))
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    // MARK: Список

    private var listCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(loc.t("Что вы копировали", "What you copied"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if history.items.contains(where: { !$0.pinned }) {
                        Button(loc.t("Очистить", "Clear")) { history.clearUnpinned() }
                            .controlSize(.small)
                            .help(loc.t("Закреплённые записи останутся", "Pinned entries stay"))
                    }
                }
                Divider()

                if history.items.isEmpty {
                    Text(history.isEnabled
                         ? loc.t("Пока пусто. Скопируйте текст где угодно — он появится здесь.",
                                 "Empty for now. Copy some text anywhere and it will appear here.")
                         : loc.t("Включите историю, и всё скопированное начнёт появляться здесь.",
                                 "Turn the history on and everything you copy will start showing up here."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else if snapshotMode {
                    // Снимку прокрутка мешает: рендер не рисует её содержимое.
                    VStack(spacing: 2) {
                        ForEach(history.displayItems) { item in row(item) }
                    }
                    .frame(height: listHeight, alignment: .top)
                    .clipped()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(history.displayItems) { item in row(item) }
                        }
                    }
                    .frame(height: listHeight)
                }

                Text(loc.t(
                    "История хранится только на этом Mac, в файле, доступном лишь вам. Пароли из менеджеров паролей не записываются. Щелчок по записи кладёт её в буфер.",
                    "The history stays on this Mac, in a file only you can read. Passwords from password managers are never recorded. Click an entry to put it on the clipboard."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Высота списка: сколько влезает, не вызывая прокрутки всей страницы.
    private var listHeight: CGFloat { history.isEnabled ? 246 : 366 }

    private func row(_ item: ClipItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button { history.togglePin(item) } label: {
                Image(systemName: item.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(item.pinned ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help(item.pinned ? loc.t("Открепить", "Unpin")
                              : loc.t("Закрепить — запись не вытеснится новыми", "Pin — keeps it from being pushed out"))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 12.5))
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text(meta(item))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)

            if justCopied == item.id {
                Label(loc.t("В буфере", "Copied"), systemImage: "checkmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }

            Button { history.remove(item) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help(loc.t("Удалить из истории", "Remove from history"))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(justCopied == item.id ? Color.green.opacity(0.08) : Color.primary.opacity(0.035))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // Из собственного окна вставлять некуда — только кладём в буфер.
            history.pick(item, paste: false)
            withAnimation(.calm) { justCopied = item.id }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation(.calm) { if justCopied == item.id { justCopied = nil } }
            }
        }
        .help(loc.t("Щёлкните, чтобы положить в буфер", "Click to put it on the clipboard"))
    }

    private func meta(_ item: ClipItem) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: loc.lang == .ru ? "ru_RU" : "en_US")
        f.unitsStyle = .short
        let when = f.localizedString(for: item.date, relativeTo: Date())
        if let app = item.app { return "\(app) · \(when)" }
        return when
    }
}
