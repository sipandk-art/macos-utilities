import AppKit

/// Решает, набрано ли слово не в той раскладке.
///
/// Проверка идёт по системному словарю macOS (`NSSpellChecker`) — своих словарей
/// приложение не носит. Но есть ловушка, ради которой здесь и написан отдельный
/// тип: английский словарь macOS считает ЛЮБУЮ кириллицу правильным словом,
/// он просто пропускает чужую письменность мимо.
///
///     checkSpelling("руддщ", language: "en")  ->  ошибок нет
///     checkSpelling("ъъъъъ", language: "en")  ->  ошибок нет
///
/// Поэтому язык проверки выбирается по письменности самого слова, а не по
/// раскладке: латиницу спрашиваем только у английского словаря, кириллицу —
/// только у русского. Без этой поправки переключатель портил бы текст.
@MainActor
final class WordChecker {

    enum Verdict {
        case leaveAlone          // слово в порядке или судить не о чем
        case wrongLayout         // набрано не в той раскладке, надо переписать
    }

    private let spell = NSSpellChecker.shared

    /// Слово из этих букв существует в языке своей письменности?
    func isRealWord(_ word: String) -> Bool {
        let language: String
        switch LayoutService.script(of: word) {
        case .cyrillic: language = "ru"
        case .latin:    language = "en"
        case .other:    return false      // цифры и знаки словарём не проверить
        }
        let range = spell.checkSpelling(of: word, startingAt: 0, language: language,
                                        wrap: false, inSpellDocumentWithTag: 0,
                                        wordCount: nil)
        return range.location == NSNotFound
    }

    /// Главное решение по фрагменту между пробелами. `typed` — то, что видно
    /// на экране, `alternative` — те же нажатия в другой раскладке.
    ///
    /// Фрагмент может содержать знаки: семь русских букв (х ъ ж э б ю ё) живут
    /// на клавишах, которые в латинице являются скобками, запятой, точкой
    /// и кавычкой. Поэтому «[jhjij» — это не скобка и слово, а «хорошо».
    /// Решение принимается по «сердцевине» — фрагменту без знаков по краям,
    /// а переписывается фрагмент целиком, со всеми знаками.
    func judge(typed: String, alternative: String) -> Verdict {
        // Цифры — это коды, даты, версии, номера. Весь фрагмент не трогаем.
        if typed.contains(where: \.isNumber) || alternative.contains(where: \.isNumber) {
            return .leaveAlone
        }
        let typedCore = Self.core(typed)
        let alternativeCore = Self.core(alternative)

        // То, во что собираемся превратить, должно быть похоже на слово:
        // буквы, внутри допускаются дефис и апостроф («что-то», «don't»).
        // Порог длины считается по результату, а не по набранному: «'nj»
        // даёт «это», и две буквы на экране — это три буквы по смыслу.
        guard Self.isWordShaped(alternativeCore),
              alternativeCore.filter(\.isLetter).count >= Self.minimumLetters
        else { return .leaveAlone }

        if !typedCore.isEmpty {
            // ВЕРХНИЙ РЕГИСТР и camelCase — это сокращения и имена в коде,
            // а не опечатки раскладки.
            if Self.isAllCaps(typedCore) || Self.isCamelCase(typedCore) { return .leaveAlone }
            // Набранное — настоящее слово: переписывать нечего.
            if isRealWord(typedCore) { return .leaveAlone }
        }
        return isRealWord(alternativeCore) ? .wrongLayout : .leaveAlone
    }

    /// Порог в три буквы, а не в две. На трёх ложных срабатываний не нашлось
    /// вовсе: «црн» становится «why», а «png», «sql», «как», «the» остаются
    /// как есть. На двух они появляются — «ns» превратилось бы в «ты».
    static let minimumLetters = 3

    /// Фрагмент без знаков по краям: «(привет),» → «привет».
    static func core(_ s: String) -> String {
        let chars = Array(s)
        guard let first = chars.firstIndex(where: \.isLetter),
              let last = chars.lastIndex(where: \.isLetter) else { return "" }
        return String(chars[first...last])
    }

    /// Буквы, а внутри — только дефис и апостроф.
    static func isWordShaped(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || "-'’".contains($0) }
    }

    static func isAllCaps(_ s: String) -> Bool {
        let letters = s.filter(\.isLetter)
        return letters.count >= 2 && letters == letters.uppercased() && letters != letters.lowercased()
    }

    /// Заглавная не в начале слова: «someVariable», «iPhone».
    static func isCamelCase(_ s: String) -> Bool {
        s.filter(\.isLetter).dropFirst().contains(where: \.isUppercase)
    }
}
