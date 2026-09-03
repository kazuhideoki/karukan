import AppKit
import SQLite3

struct MacUserDictionaryEntry: Equatable, Hashable {
    let reading: String
    let surface: String

    var jsonObject: [String: String] {
        ["reading": reading, "surface": surface]
    }
}

enum MacUserDictionary {
    static func currentEntries() -> [MacUserDictionaryEntry] {
        let publicEntries = entries(from: NSSpellChecker.shared.userReplacementsDictionary)
        let databaseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/KeyboardServices/TextReplacements.db")
        guard let databaseEntries = entriesFromTextReplacementsDatabase(at: databaseURL) else {
            return publicEntries
        }
        return deduplicatedAndSorted(databaseEntries + publicEntries)
    }

    static func entries(from replacements: [String: String]) -> [MacUserDictionaryEntry] {
        deduplicatedAndSorted(
            replacements.compactMap { reading, surface in
                guard !reading.isEmpty, !surface.isEmpty else { return nil }
                return MacUserDictionaryEntry(reading: reading, surface: surface)
            })
    }

    static func deduplicatedAndSorted(_ entries: [MacUserDictionaryEntry])
        -> [MacUserDictionaryEntry]
    {
        Array(Set(entries)).sorted {
            ($0.reading, $0.surface) < ($1.reading, $1.surface)
        }
    }

    /// Read the unified macOS text-replacement store. Apple does not expose
    /// Japanese-reading entries through NSSpellChecker, although they live in
    /// the same store as its ASCII replacements. Keep this read-only and fall
    /// back to the public API if the private schema changes.
    static func entriesFromTextReplacementsDatabase(at databaseURL: URL)
        -> [MacUserDictionaryEntry]?
    {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }

        var database: OpaquePointer?
        guard
            sqlite3_open_v2(
                databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
                == SQLITE_OK,
            let database
        else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }

        let sql = """
            SELECT ZSHORTCUT, ZPHRASE
            FROM ZTEXTREPLACEMENTENTRY
            WHERE ZWASDELETED = 0
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            if let statement { sqlite3_finalize(statement) }
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var entries: [MacUserDictionaryEntry] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let readingText = sqlite3_column_text(statement, 0),
                    let surfaceText = sqlite3_column_text(statement, 1)
                else { continue }
                let reading = String(cString: readingText)
                let surface = String(cString: surfaceText)
                guard !reading.isEmpty, !surface.isEmpty else { continue }
                entries.append(MacUserDictionaryEntry(reading: reading, surface: surface))
            case SQLITE_DONE:
                return entries
            default:
                return nil
            }
        }
    }
}
