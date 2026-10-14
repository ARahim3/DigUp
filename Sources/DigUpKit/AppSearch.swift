import Foundation

/// An app's name, ready to match what's typed against it the way launchers do: the whole name from its start, the start
/// of a word in it ("code" for Visual Studio Code, "term" for iTerm), the starts of several of its words in order
/// ("vis stu"), or its initials ("vsc"). Never the middle of a word: "cat" must not launch Calculator when you're
/// looking for a cat.
public struct AppName: Sendable, Equatable {
    public let name: String
    let folded: String
    let words: [String]
    let initials: String

    public init(_ name: String) {
        self.name = name
        folded = Self.fold(name)
        words = Self.words(of: name).map(Self.fold)
        initials = String(words.compactMap(\.first))
    }

    /// How well `query` matches (already `AppSearch.normalized`): nil for not at all, higher for better.
    func score(_ query: String) -> Int? {
        guard !query.isEmpty else { return nil }
        if folded == query { return 1000 }
        if folded.hasPrefix(query) { return 800 }
        let parts = query.split(separator: " ").map(String.init)
        if Self.startsWords(parts, of: words) { return 600 }
        if parts.count == 1, query.count >= 2, initials.hasPrefix(query) { return 500 }
        return nil
    }

    /// Each part starts one of `words`, in order: "vis stu" in Visual Studio Code, "code" in it too.
    private static func startsWords(_ parts: [String], of words: [String]) -> Bool {
        var next = 0
        for part in parts {
            guard let found = words[next...].firstIndex(where: { $0.hasPrefix(part) }) else { return false }
            next = found + 1
        }
        return true
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// "Visual Studio Code" → Visual, Studio, Code; "iTerm" → i, Term; "zoom.us" → zoom, us; "1Password 8" → 1,
    /// Password, 8. Words end at anything that isn't a letter or a digit, and inside one where a capital follows a
    /// small letter or letters and digits meet.
    static func words(of name: String) -> [String] {
        var words: [String] = []
        var word = ""
        var previous: Character?
        for character in name {
            guard character.isLetter || character.isNumber else {
                if !word.isEmpty { words.append(word) }
                word = ""
                previous = nil
                continue
            }
            if let previous, !word.isEmpty,
               (previous.isLowercase && character.isUppercase) || (previous.isNumber != character.isNumber) {
                words.append(word)
                word = ""
            }
            word.append(character)
            previous = character
        }
        if !word.isEmpty { words.append(word) }
        return words
    }
}

/// Finds apps by name as you type (`AppName`), best match first. Among matches as good, the ones favored (`boost`:
/// launched most, used lately) come first, then the shorter name ("Notes" before "Notes Helper").
public enum AppSearch {
    /// A name the app also goes by (the bundle's own, "Code" for Visual Studio Code) matches a little less well than
    /// the one Finder shows.
    static let otherNamePenalty = 50

    /// The query as names are matched against it: folded like them, single spaces.
    static func normalized(_ query: String) -> String {
        AppName.fold(query).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The best of `apps` for `query`, at most `limit`. `names`: an app's names, the one Finder shows first.
    public static func rank<App>(_ query: String, _ apps: [App], names: (App) -> [AppName],
                                 boost: (App) -> Int = { _ in 0 }, limit: Int) -> [App] {
        let query = normalized(query)
        guard !query.isEmpty, limit > 0 else { return [] }
        var scored: [(app: App, score: Int, length: Int, name: String)] = []
        for app in apps {
            let all = names(app)
            guard let first = all.first else { continue }
            let best = all.enumerated().compactMap { index, name in
                name.score(query).map { $0 - (index == 0 ? 0 : otherNamePenalty) }
            }.max()
            guard let best else { continue }
            scored.append((app, best + boost(app), first.name.count, first.folded))
        }
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.length != $1.length { return $0.length < $1.length }
            return $0.name < $1.name
        }
        return scored.prefix(limit).map(\.app)
    }
}
