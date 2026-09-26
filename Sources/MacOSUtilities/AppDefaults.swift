import Foundation

/// Где приложение хранит настройки и файлы.
///
/// Режим `--test-profile` уводит всё это в отдельное место. Без него сквозные
/// стенды писали бы в то же хранилище, что и установленная копия: настройки
/// привязаны к идентификатору приложения, а он у сборки и у установленной
/// программы один. Тест, включающий и выключающий переключатели, молча сбивал бы
/// настройки человека.
enum AppDefaults {
    static let isTestProfile = CommandLine.arguments.contains("--test-profile")

    /// Имя отдельного хранилища для тестов — им же пользуются стенды
    /// (`defaults write com.sipandk.macosutilities.test …`).
    static let testSuiteName = "com.sipandk.macosutilities.test"

    static let store: UserDefaults = isTestProfile
        ? UserDefaults(suiteName: testSuiteName) ?? .standard
        : .standard

    /// Папка для файлов приложения — истории буфера обмена и подобного.
    static var supportFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(isTestProfile ? "MacOS Utilities (test)" : "MacOS Utilities")
    }
}
