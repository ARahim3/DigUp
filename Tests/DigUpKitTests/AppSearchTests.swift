import Testing
@testable import DigUpKit

@Suite struct AppSearchTests {
    static let apps = ["Safari", "Calculator", "Calendar", "Visual Studio Code", "iTerm", "Notes", "Notion", "Contacts",
                       "System Settings", "Café Racer", "1Password 8", "zoom.us", "FaceTime", "Screen Sharing"]

    func find(_ query: String, boost: [String: Int] = [:], also: [String: String] = [:], limit: Int = 4) -> [String] {
        AppSearch.rank(query, Self.apps, names: { [AppName($0)] + (also[$0].map { [AppName($0)] } ?? []) },
                       boost: { boost[$0] ?? 0 }, limit: limit)
    }

    @Test func wordsOfNames() {
        #expect(AppName.words(of: "Visual Studio Code") == ["Visual", "Studio", "Code"])
        #expect(AppName.words(of: "iTerm") == ["i", "Term"])
        #expect(AppName.words(of: "zoom.us") == ["zoom", "us"])
        #expect(AppName.words(of: "1Password 8") == ["1", "Password", "8"])
        #expect(AppName.words(of: "OBS") == ["OBS"])
    }

    @Test func startsOfNamesAndWords() {
        #expect(find("saf") == ["Safari"])
        #expect(find("code") == ["Visual Studio Code"])
        #expect(find("term") == ["iTerm"])
        #expect(find("vis stu") == ["Visual Studio Code"])
        #expect(find("visual   studio") == ["Visual Studio Code"])
        #expect(find("pass") == ["1Password 8"])
        #expect(find("time") == ["FaceTime"])
        #expect(find("SYSTEM set") == ["System Settings"])
    }

    @Test func initials() {
        #expect(find("vsc") == ["Visual Studio Code"])
        #expect(find("ss") == ["Screen Sharing", "System Settings"])
        #expect(find("v") == ["Visual Studio Code"])   // one letter is the start of a word, never initials
    }

    @Test func neverTheMiddleOfAWord() {
        #expect(find("cat").isEmpty)                    // not Calculator, not Contacts
        #expect(find("ari").isEmpty)                    // not Safari
        #expect(find("a dog on the beach").isEmpty)
    }

    @Test func accentsAndCaseDontMatter() {
        #expect(find("cafe") == ["Café Racer"])
        #expect(find("CALC") == ["Calculator"])
    }

    @Test func betterMatchesFirstThenShorterNames() {
        #expect(find("notes") == ["Notes"])
        #expect(find("no") == ["Notes", "Notion"])      // as good a match: the shorter name first
        #expect(find("cal") == ["Calendar", "Calculator"])
        #expect(find("c", limit: 2) == ["Calendar", "Contacts"])
    }

    @Test func favoredAppsComeFirst() {
        #expect(find("cal", boost: ["Calculator": 60]) == ["Calculator", "Calendar"])
        #expect(find("no", boost: ["Notion": 1]) == ["Notion", "Notes"])
        // The start of a later word, favored enough, beats the start of a name.
        #expect(find("co", boost: ["Visual Studio Code": 260]) == ["Visual Studio Code", "Contacts"])
    }

    @Test func otherNamesMatchALittleLessWell() {
        let also = ["Visual Studio Code": "Code"]
        #expect(find("code", also: also) == ["Visual Studio Code"])
        #expect(find("co", also: also) == ["Contacts", "Visual Studio Code"])
    }

    @Test func nothingTypedFindsNothing() {
        #expect(find("").isEmpty)
        #expect(find("   ").isEmpty)
        #expect(find("saf", limit: 0).isEmpty)
    }
}
