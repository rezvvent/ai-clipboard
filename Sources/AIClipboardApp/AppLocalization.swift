import AIClipboardCore
import Foundation

enum AppDateStyle {
    case long
    case abbreviated
}

enum AppLocalization {
    static func string(_ key: String, languageCode: String) -> String {
        let code = languageCode == "ru" ? "ru" : "en"
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return Bundle.main.localizedString(forKey: key, value: key, table: nil)
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func date(
        _ date: Date,
        style: AppDateStyle,
        languageCode: String
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: languageCode == "ru" ? "ru_RU" : "en_US")
        formatter.dateStyle = style == .long ? .long : .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func relativeDate(_ date: Date, languageCode: String) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 {
            return string("time.now", languageCode: languageCode)
        }
        let key: String
        let value: Int
        if seconds < 3_600 {
            key = "time.minutes"
            value = Int(seconds / 60)
        } else if seconds < 86_400 {
            key = "time.hours"
            value = Int(seconds / 3_600)
        } else {
            key = "time.days"
            value = Int(seconds / 86_400)
        }
        return String(
            format: string(key, languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            value
        )
    }
}

extension ClipboardItem {
    func localizedTypeName(languageCode: String) -> String {
        AppLocalization.string("type.\(contentType.rawValue)", languageCode: languageCode)
    }

    func localizedStatus(languageCode: String) -> String {
        AppLocalization.string("status.\(processingStatus.rawValue)", languageCode: languageCode)
    }

    func localizedTitle(languageCode: String) -> String {
        guard let title, !title.isEmpty else {
            return localizedTypeName(languageCode: languageCode)
        }
        // Older server records store the English fallback type as their title.
        // Treat that value as generated metadata rather than user-authored text.
        if title.caseInsensitiveCompare(contentType.displayName) == .orderedSame {
            return localizedTypeName(languageCode: languageCode)
        }
        return title
    }

    func localizedTag(_ tag: String, languageCode: String) -> String {
        let key = "tag.\(tag.lowercased())"
        let translated = AppLocalization.string(key, languageCode: languageCode)
        return translated == key ? tag : translated
    }
}
