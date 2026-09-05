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

    /// Главное решение: `typed` — то, что видно на экране сейчас,
    /// `alternative` — то же нажатия в другой раскладке.
    func judge(typed: String, alternative: String) -> Verdict {
        guard Self.looksLikeWord(typed), Self.looksLikeWord(alternative) else { return .leaveAlone }
        // Переписываем только когда набранное словом не является, а вариант
        // в другой раскладке — является. Если верны оба или неверны оба,
        // угадывать нечего: молчим.
        if !isRealWord(typed) && isRealWord(alternative) { return .wrongLayout }
        return .leaveAlone
    }

    /// Отсев того, что вообще не стоит проверять: слишком короткое, с цифрами,
    /// ВЕРХНИМ РЕГИСТРОМ, camelCase или похожее на путь и адрес. Именно на этом
    /// добре автопереключатели обычно и портят текст.
    static func looksLikeWord(_ s: String) -> Bool {
        // Порог в три буквы, а не в две. На трёх буквах ложных срабатываний
        // не нашлось вовсе: «црн» становится «why», а «png», «sql», «как»,
        // «the» остаются как есть. На двух буквах появляются — например
        // «ns» превратилось бы в «ты», а это частое техническое сокращение.
        guard s.count >= 3 else { return false }
        if s.contains(where: { $0.isNumber }) { return false }
        if s.contains(where: { "/\\@:._-+=#$~".contains($0) }) { return false }
        let letters = s.filter { $0.isLetter }
        guard letters.count == s.count else { return false }
        if s == s.uppercased() && s != s.lowercased() { return false }   // ВЕРХНИЙ РЕГИСТР
        // camelCase: заглавная не в начале слова
        if s.dropFirst().contains(where: { $0.isUppercase }) { return false }
        return true
    }
}
