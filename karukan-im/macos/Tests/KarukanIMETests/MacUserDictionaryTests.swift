import XCTest

@testable import KarukanIME

final class MacUserDictionaryTests: XCTestCase {
    func testEntriesAreFilteredAndSortedWithoutChangingText() {
        let entries = MacUserDictionary.entries(from: [
            "": "ignored",
            "びー": "B",
            "えー": "A",
            "empty": "",
        ])

        XCTAssertEqual(
            entries,
            [
                MacUserDictionaryEntry(reading: "えー", surface: "A"),
                MacUserDictionaryEntry(reading: "びー", surface: "B"),
            ])
    }

    func testDatabaseAndPublicEntriesCanBeMergedWithoutDuplicates() {
        let entries = MacUserDictionary.deduplicatedAndSorted([
            MacUserDictionaryEntry(reading: "ced", surface: "address@example.com"),
            MacUserDictionaryEntry(reading: "さな", surface: "紗奈"),
            MacUserDictionaryEntry(reading: "ced", surface: "address@example.com"),
        ])

        XCTAssertEqual(
            entries,
            [
                MacUserDictionaryEntry(reading: "ced", surface: "address@example.com"),
                MacUserDictionaryEntry(reading: "さな", surface: "紗奈"),
            ])
    }
}
