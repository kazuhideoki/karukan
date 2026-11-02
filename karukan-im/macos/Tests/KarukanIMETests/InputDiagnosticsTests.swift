#if canImport(Testing)
import Foundation
import Testing

@testable import KarukanIME

struct InputDiagnosticsTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("karukan-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func actionContentsDoNotReachLog() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("diagnostics.log")
        let logger = InputDiagnostics(enabled: true, fileURL: url)
        let secrets = ["入力内容🔑", "確定した文字", "変換候補", "候補説明", "周辺テキスト"]
        let actions: [EngineAction] = [
            .updatePreedit(text: secrets[0], caret: 0, attributes: []),
            .commit(text: secrets[1]),
            .showCandidates(
                candidates: [CandidateItem(text: secrets[2], description: secrets[3])],
                cursor: 0, page: 0, totalPages: 1),
            .updateAux(text: secrets[4]),
        ]
        logger.record(
            .engineResult,
            details: InputDiagnosticDetails(consumed: true, actions: actions.map(InputDiagnosticAction.init)))
        logger.flush()

        let data = try Data(contentsOf: url)
        let raw = String(decoding: data, as: UTF8.self)
        for secret in secrets { #expect(!raw.contains(secret)) }
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let details = try #require(json["details"] as? [String: Any])
        let summaries = try #require(details["actions"] as? [[String: Any]])
        #expect(summaries[0]["textUTF16Length"] as? Int == secrets[0].utf16.count)
        #expect(summaries[2]["candidateCount"] as? Int == 1)
        #expect(Set(summaries.flatMap(\.keys)) == ["kind", "textUTF16Length", "candidateCount"])
    }

    @Test func disabledLoggerDoesNotCreateFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("unused/diagnostics.log")
        let logger = InputDiagnostics(enabled: false, fileURL: url)
        logger.record(.startup)
        logger.flush()
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    @Test func rotationKeepsBoundedCompleteRecordsAndLatestEvent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("diagnostics.log")
        let logger = InputDiagnostics(enabled: true, fileURL: url, maxBytes: 1200, archiveCount: 2)
        for index in 0..<100 {
            logger.record(.inputReceived, details: InputDiagnosticDetails(textUTF16Length: index))
        }
        logger.flush()

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(Set(files.map(\.lastPathComponent)) == ["diagnostics.log", "diagnostics.log.1", "diagnostics.log.2"])
        for file in files {
            let data = try Data(contentsOf: file)
            #expect(data.count <= 1200)
            #expect(data.last == 0x0A)
            for line in data.split(separator: 0x0A) {
                #expect(throws: Never.self) { try JSONSerialization.jsonObject(with: Data(line)) }
            }
        }
        let last = try #require(String(contentsOf: url, encoding: .utf8).split(separator: "\n").last)
        let json = try #require(JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any])
        let details = try #require(json["details"] as? [String: Any])
        #expect(details["textUTF16Length"] as? Int == 99)
    }

    @Test func logIsPrivateAndSurvivesReopening() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("diagnostics.log")
        for _ in 0..<2 {
            let logger = InputDiagnostics(enabled: true, fileURL: url)
            logger.record(.startup)
            logger.flush()
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let runs = try lines.map { line -> String in
            let json = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try #require(json["run"] as? String)
        }
        #expect(runs[0] != runs[1])
    }

    @Test func unavailableRangeIsNotAnEmptyMarkedRange() {
        let unavailable = InputDiagnosticDetails.range(NSRange(location: NSNotFound, length: NSNotFound))
        #expect(unavailable.rangeAvailable == false)
        #expect(unavailable.rangeLength == nil)
        let empty = InputDiagnosticDetails.range(NSRange(location: 0, length: 0))
        #expect(empty.rangeAvailable == true)
        #expect(empty.rangeLength == 0)
    }

    @Test func unwritableDestinationDoesNotInterruptCaller() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("file")
        try Data().write(to: blocker)
        let logger = InputDiagnostics(enabled: true, fileURL: blocker.appendingPathComponent("diagnostics.log"))
        for _ in 0..<10 { logger.record(.inputReceived) }
        logger.flush()
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["file"])
    }
}
#endif
