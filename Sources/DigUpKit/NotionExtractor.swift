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

    /// Block types that are page boundaries: traversed for breadcrumbs but not added as body text.
    private static let pageTypes: Set<String> = ["page", "collection_view_page", "personal_home_page"]

    // MARK: - Public API

    /// Extracts active pages from Notion's local SQLite database in read-only mode.
    /// Opens the database with `SQLITE_OPEN_READONLY` so it never locks while Notion is running.
    /// Automatically ignores deleted pages and pages nested inside trashed containers.
    ///
    /// - Parameter databasePath: Path to `notion.db`. Defaults to the standard Notion Desktop location.
    /// - Parameter modifiedSince: Unix timestamp in seconds. Only pages edited after this time are returned.
    ///   Pass `0` (default) for a full extraction.
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

        struct AncestorMeta {
            let parentID: String?
            let parentTable: String?
            let alive: Bool
            let inTrash: Bool
        }

        // 1. Load block ancestor metadata (including deleted/trashed blocks to detect trashed trees)
        var blockMeta: [String: AncestorMeta] = [:]
        let metaSql = """
            SELECT id, parent_id, parent_table, alive, moved_to_trash_time, archived_time
            FROM block
        """
        var metaStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, metaSql, -1, &metaStmt, nil) == SQLITE_OK, let stmt = metaStmt {
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idPtr = sqlite3_column_text(stmt, 0) else { continue }
                let id = String(cString: idPtr)
                let parentID = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                let parentTable = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                let alive = sqlite3_column_int(stmt, 3) == 1
                let hasTrashTime = sqlite3_column_type(stmt, 4) != SQLITE_NULL
                let hasArchivedTime = sqlite3_column_type(stmt, 5) != SQLITE_NULL
                blockMeta[id] = AncestorMeta(parentID: parentID, parentTable: parentTable,
                                             alive: alive, inTrash: hasTrashTime || hasArchivedTime)
            }
            sqlite3_finalize(stmt)
        }

        // 2. Load collection ancestor metadata (collections can also be deleted/trashed)
        var collectionMeta: [String: AncestorMeta] = [:]
        let colSql = """
            SELECT id, parent_id, parent_table, alive, moved_to_trash_time
            FROM collection
        """
        var colStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, colSql, -1, &colStmt, nil) == SQLITE_OK, let stmt = colStmt {
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idPtr = sqlite3_column_text(stmt, 0) else { continue }
                let id = String(cString: idPtr)
                let parentID = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                let parentTable = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                let alive = sqlite3_column_int(stmt, 3) == 1
                let hasTrashTime = sqlite3_column_type(stmt, 4) != SQLITE_NULL
                collectionMeta[id] = AncestorMeta(parentID: parentID, parentTable: parentTable,
                                                  alive: alive, inTrash: hasTrashTime)
            }
            sqlite3_finalize(stmt)
        }

        func isDescendantOfTrash(id: String, table: String = "block") -> Bool {
            var currID = id
            var currTable = table
            var visited: Set<String> = []
            while !visited.contains(currID) {
                visited.insert(currID)
                let meta = (currTable == "block") ? blockMeta[currID] : collectionMeta[currID]
                guard let m = meta else { break }
                if !m.alive || m.inTrash {
                    return true
                }
                guard let pid = m.parentID, let ptable = m.parentTable else { break }
                currID = pid
                currTable = ptable
            }
            return false
        }

        // 3. Load active blocks and build the in-memory tree
        let sql = """
            SELECT id, type, parent_id, parent_table, properties, last_edited_time
            FROM block
            WHERE alive = 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ExtractError.unreadable("Failed to prepare statement: \(String(cString: sqlite3_errmsg(db)))")
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
        var childrenOf: [String: [String]] = [:]
        var pageIDs: [String] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPtr = sqlite3_column_text(statement, 0),
                  let typePtr = sqlite3_column_text(statement, 1) else { continue }
            let id = String(cString: idPtr)

            // Skip any block whose container or ancestor has been trashed
            if isDescendantOfTrash(id: id, table: "block") {
                continue
            }

            let type = String(cString: typePtr)
            let parentID = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            let parentTable = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            let props = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            let lastEdited = sqlite3_column_double(statement, 5)

            let title = extractTitle(from: props)
            blockMap[id] = RawBlock(id: id, type: type, parentID: parentID, parentTable: parentTable,
                                    title: title, lastEdited: lastEdited)

            if let pid = parentID {
                childrenOf[pid, default: []].append(id)
            }

            if pageTypes.contains(type) && type != "personal_home_page" && !title.isEmpty {
                if lastEdited >= modifiedSince * 1000 {
                    pageIDs.append(id)
                }
            }
        }

        var pages: [Page] = []
        for pid in pageIDs {
            guard let root = blockMap[pid] else { continue }
            let crumbs = buildBreadcrumbs(for: pid, in: blockMap)
            let body = collectText(under: pid, in: blockMap, childrenOf: childrenOf).joined(separator: "\n")
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

    // MARK: - Helpers

    private static func extractTitle(from propertiesJSON: String?) -> String {
        guard let data = propertiesJSON?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let titleArray = json["title"] as? [[Any]] else { return "" }
        return titleArray.compactMap { $0.first as? String }
                         .joined(separator: " ")
                         .trimmingCharacters(in: .whitespaces)
    }

    private static func buildBreadcrumbs(for pageID: String, in map: [String: RawBlock],
                                         maxDepth: Int = 8) -> String {
        var crumbs: [String] = []
        var currID = pageID
        var depth = 0
        while depth < maxDepth {
            guard let block = map[currID],
                  let parentID = block.parentID,
                  block.parentTable == "block",
                  let parent = map[parentID] else { break }
            if pageTypes.contains(parent.type) && !parent.title.isEmpty {
                crumbs.append(parent.title)
            }
            currID = parentID
            depth += 1
        }
        return crumbs.reversed().joined(separator: " / ")
    }

    private static func collectText(under pageID: String,
                                    in map: [String: RawBlock],
                                    childrenOf: [String: [String]],
                                    depth: Int = 0,
                                    maxDepth: Int = 12) -> [String] {
        guard depth < maxDepth else { return [] }
        var texts: [String] = []
        for childID in childrenOf[pageID] ?? [] {
            guard let block = map[childID] else { continue }
            if pageTypes.contains(block.type) { continue }
            if !block.title.isEmpty {
                texts.append(block.title)
            }
            texts.append(contentsOf: collectText(under: childID, in: map,
                                                 childrenOf: childrenOf,
                                                 depth: depth + 1, maxDepth: maxDepth))
        }
        return texts
    }
}
