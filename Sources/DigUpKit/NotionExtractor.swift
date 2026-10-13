import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// Extracts Notion pages and block text from Notion Desktop's local SQLite database
/// (`~/Library/Application Support/Notion/notion.db`).
public enum NotionExtractor {
    public struct Page: Sendable {
        public let id: String
        public let title: String
        public let path: String
        public let text: String
        public let modified: Double

        /// Direct URL to open this page inside Notion Desktop.
        public var notionURL: URL? {
            let cleanID = id.replacingOccurrences(of: "-", with: "")
            return URL(string: "notion://www.notion.so/\(cleanID)")
        }

        /// Web fallback URL.
        public var webURL: URL? {
            let cleanID = id.replacingOccurrences(of: "-", with: "")
            return URL(string: "https://www.notion.so/\(cleanID)")
        }
    }

    public static var defaultDatabasePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Notion/notion.db"
    }

    /// Checks if Notion's local SQLite database exists on disk.
    public static var isNotionInstalled: Bool {
        FileManager.default.fileExists(atPath: defaultDatabasePath)
    }

    /// Extracts active pages from Notion's local SQLite database in read-only mode.
    public static func extractPages(from databasePath: String = defaultDatabasePath,
                                    since modifiedSince: Double = 0.0) throws -> [Page] {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let uri = "file:\(databasePath)?mode=ro"
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(databasePath)"
            sqlite3_close(db)
            throw ExtractError.unreadable(message)
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT id, type, parent_id, parent_table, properties, last_edited_time
            FROM block
            WHERE alive = 1
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(db))
            throw ExtractError.unreadable("Failed to prepare statement: \(message)")
        }
        defer { sqlite3_finalize(statement) }

        struct RawBlock {
            let id: String
            let type: String
            let parentID: String?
            let parentTable: String?
            let title: String
            let lastEdited: Double
        }

        var blockMap: [String: RawBlock] = [:]
        var pageIDs: [String] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPtr = sqlite3_column_text(statement, 0),
                  let typePtr = sqlite3_column_text(statement, 1) else { continue }
            let id = String(cString: idPtr)
            let type = String(cString: typePtr)

            let parentID = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            let parentTable = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            let props = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            let lastEdited = sqlite3_column_double(statement, 5)

            let title = extractTitle(from: props)
            let block = RawBlock(id: id, type: type, parentID: parentID, parentTable: parentTable,
                                 title: title, lastEdited: lastEdited)
            blockMap[id] = block

            if (type == "page" || type == "collection_view_page") && !title.isEmpty {
                if lastEdited >= modifiedSince {
                    pageIDs.append(id)
                }
            }
        }

        var pages: [Page] = []
        for pid in pageIDs {
            guard let root = blockMap[pid] else { continue }
            let crumbs = buildBreadcrumbs(for: pid, in: blockMap)
            let childTexts = collectChildrenText(for: pid, in: blockMap)
            let body = childTexts.joined(separator: "\n")
            pages.append(Page(
                id: pid,
                title: root.title,
                path: crumbs,
                text: body,
                modified: root.lastEdited / 1000.0
            ))
        }

        return pages
    }

    private static func extractTitle(from propertiesJSON: String?) -> String {
        guard let data = propertiesJSON?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let titleArray = json["title"] as? [[Any]] else { return "" }
        return titleArray.compactMap { $0.first as? String }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func buildBreadcrumbs(for pageID: String, in map: [String: RawBlock], maxDepth: Int = 6) -> String {
        var crumbs: [String] = []
        var curr = map[pageID]
        var depth = 0
        while let c = curr, depth < maxDepth {
            if let pid = c.parentID, c.parentTable == "block", let parent = map[pid] {
                if (parent.type == "page" || parent.type == "collection_view_page") && !parent.title.isEmpty {
                    crumbs.append(parent.title)
                }
                curr = parent
                depth += 1
            } else {
                break
            }
        }
        return crumbs.reversed().joined(separator: " / ")
    }

    private static func collectChildrenText(for pageID: String, in map: [String: RawBlock]) -> [String] {
        var texts: [String] = []
        for (_, b) in map {
            if b.parentID == pageID && b.type != "page" && !b.title.isEmpty {
                texts.append(b.title)
            }
        }
        return texts
    }
}
