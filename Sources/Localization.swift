import Foundation

enum L10n {
    static func string(
        _ key: String,
        bundle: Bundle = .main,
        language: String? = nil
    ) -> String {
        let localizationBundle: Bundle
        if let language,
           let path = bundle.path(forResource: language, ofType: "lproj"),
           let selectedBundle = Bundle(path: path) {
            localizationBundle = selectedBundle
        } else {
            localizationBundle = bundle
        }
        return localizationBundle.localizedString(forKey: key, value: nil, table: nil)
    }

    static func formatted(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: Locale.current, arguments: arguments)
    }
}
