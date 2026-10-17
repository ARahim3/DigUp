import Foundation
import Testing
@testable import DigUpKit

@Suite struct TextBudgetTests {
    @Test func budgetIncludesTitleAndKeepsOverlappingHanAndFinalContent() throws {
        let text = String(repeating: "甲", count: 110) + "租房合同" + String(repeating: "乙", count: 300) + "尾部标记"
        let title = "公开合成标题"
        let count = { (input: String) in input.utf8.count + 2 }
        let parts = try TextBudget.chunks(text, title: title, limit: 220, count: count)
        #expect(parts.count > 3)
        #expect(parts.allSatisfy { count(Prompts.document(title: title, text: $0)) <= 220 })
        #expect(parts.contains { $0.contains("租房合同") })
        #expect(parts.last?.hasSuffix("尾部标记") == true)
        for pair in zip(parts, parts.dropFirst()) {
            #expect((1...min(200, pair.0.count / 4)).contains {
                pair.0.suffix($0) == pair.1.prefix($0)
            })
        }
    }

    @Test func smallEnglishAndBengaliArabicPassagesStayUnchanged() throws {
        for text in ["A payment error appeared.", "সুন্দরবনে আমরা কুমিরও দেখেছি।", "قَالَ إِنَّ الْمَكْتَبَةَ تُغْلَقُ"] {
            #expect(try TextBudget.chunks(text, title: "synthetic", limit: 2048,
                                        count: { $0.utf8.count + 2 }) == [text])
        }
    }

    @Test func impossibleTitleBudgetFailsInsteadOfDiscardingText() {
        #expect(throws: (any Error).self) {
            _ = try TextBudget.chunks("合同", title: String(repeating: "标题", count: 100), limit: 50,
                                      count: { $0.utf8.count + 2 })
        }
    }

}
