import Foundation
import SwiftUI

enum Lang: String, CaseIterable, Identifiable {
    case ru, en
    var id: String { rawValue }
    var label: String { self == .ru ? "RU" : "EN" }
}

/// Язык интерфейса. Строки хранятся парами прямо в местах использования —
/// `loc.t("Применить", "Apply")` — чтобы перевод было видно рядом с оригиналом
/// и он не разъезжался с кодом при правках.
///
/// Тот же язык передаётся скриптам флагом `--lang`: их вывод попадает
/// в журнал и в баннер с итогом, поэтому переводить только интерфейс было бы полумерой.
@MainActor
final class Localization: ObservableObject {

    @Published var lang: Lang {
        didSet { UserDefaults.standard.set(lang.rawValue, forKey: key) }
    }

    private let key = "interfaceLanguage"

    init() {
        if let saved = UserDefaults.standard.string(forKey: key),
           let l = Lang(rawValue: saved) {
            lang = l
        } else {
            // Первый запуск: берём язык системы, русский — только если он первый
            // в списке предпочитаемых.
            let prefers = Locale.preferredLanguages.first?.hasPrefix("ru") ?? false
            lang = prefers ? .ru : .en
        }
    }

    func t(_ ru: String, _ en: String) -> String {
        lang == .ru ? ru : en
    }
}
