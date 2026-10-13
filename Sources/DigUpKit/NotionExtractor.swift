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

    /// Block types whose text is extracted and included in the page body.
    /// Container types (column, toggle, callout, table, etc.) are traversed into but only
    /// contribute text if they carry a `title` field (e.g. callout, toggle summary).
    private static let containerTypes: Set<String> = ["column", "column_list", "table"]

    // MARK: - Public API

    /// Extracts active pages from Notion's local SQLite database in read-only mode.
    /// Opens the database with `SQLITE_OPEN_READONLY` so it never locks while Notion is running.
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

        // Load the entire block table once — one round-trip for the whole workspace.
        // At ~10k blocks this is under 120 ms and lets us walk the tree in memory.
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
            let title: String       // text extracted from `properties.title`
            let lastEdited: Double  // milliseconds since epoch (0 when NULL)
        }

        // blockMap: id → RawBlock for O(1) parent lookups and tree traversal
        var blockMap: [String: RawBlock] = [:]
        // childrenOf: parentID → [childID] for top-down recursive traversal
        var childrenOf: [String: [String]] = [:]
        var pageIDs: [String] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPtr = sqlite3_column_text(statement, 0),
                  let typePtr = sqlite3_column_text(statement, 1) else { continue }
            let id = String(cString: idPtr)
            let type = String(cString: typePtr)
            let parentID = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            let parentTable = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            let props = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            let lastEdited = sqlite3_column_double(statement, 5)   // 0.0 for NULL — safe

            let title = extractTitle(from: props)
            blockMap[id] = RawBlock(id: id, type: type, parentID: parentID, parentTable: parentTable,
                                    title: title, lastEdited: lastEdited)

            // Build the parent→children index for all blocks
            if let pid = parentID {
                childrenOf[pid, default: []].append(id)
            }

            // A page qualifies if it has a non-empty title and was edited after the cutoff.
            // personal_home_page is Notion's internal home block, not a user page.
            if pageTypes.contains(type) && type != "personal_home_page" && !title.isEmpty {
                if lastEdited >= modifiedSince * 1000 {  // convert caller's seconds to ms
                    pageIDs.append(id)
                }
            }
        }

        var pages: [Page] = []
        for pid in pageIDs {
            guard let root = blockMap[pid] else { continue }
            let crumbs = buildBreadcrumbs(for: pid, in: blockMap)
            // Full recursive traversal — every nested block type is walked
            let body = collectText(under: pid, in: blockMap, childrenOf: childrenOf).joined(separator: "\n")
            pages.append(Page(
                id: pid,
                title: root.title,
                path: crumbs,
                text: body,
                modified: root.lastEdited / 1000.0   // return seconds to callers
            ))
        }
        return pages
    }

    // MARK: - Helpers

    /// Extracts the plain-text content of Notion's `properties.title` rich-text array.
    private static func extractTitle(from propertiesJSON: String?) -> String {
        guard let data = propertiesJSON?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let titleArray = json["title"] as? [[Any]] else { return "" }
        // Each element is [text, optional_annotations...]; we only need element[0].
        return titleArray.compactMap { $0.first as? String }
                         .joined(separator: " ")
                         .trimmingCharacters(in: .whitespaces)
    }

    /// Walks ancestors to build a "Parent / Grandparent" breadcrumb string.
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

    /// Recursively collects text from every block under `pageID`.
    ///
    /// - Traverses into container blocks (columns, toggles, callouts, tables, etc.)
    ///   so no nested text is missed.
    /// - Does **not** cross page boundaries — sub-pages are skipped (they are indexed separately).
    /// - Capped at `maxDepth` levels to guard against any malformed circular references.
    private static func collectText(under pageID: String,
                                    in map: [String: RawBlock],
                                    childrenOf: [String: [String]],
                                    depth: Int = 0,
                                    maxDepth: Int = 12) -> [String] {
        guard depth < maxDepth else { return [] }
        var texts: [String] = []
        for childID in childrenOf[pageID] ?? [] {
            guard let block = map[childID] else { continue }
            // Stop at page boundaries — sub-pages are their own index entries.
            if pageTypes.contains(block.type) { continue }
            // Add the block's own text (empty for pure containers like column_list).
            if !block.title.isEmpty {
                texts.append(block.title)
            }
            // Always recurse — even container blocks can have text-bearing children.
            texts.append(contentsOf: collectText(under: childID, in: map,
                                                 childrenOf: childrenOf,
                                                 depth: depth + 1, maxDepth: maxDepth))
        }
        return texts
    }
}
