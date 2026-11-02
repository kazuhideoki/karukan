#if canImport(Testing)
    import Cocoa
    import Testing

    @testable import KarukanIME

    struct InputDiagnosticEventMetadataTests {
        @Test func commandEventRetainsFlagsWithoutKeyContents() throws {
            let secret = "保存しない入力"
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                    timestamp: 0, windowNumber: 0, context: nil, characters: secret,
                    charactersIgnoringModifiers: secret, isARepeat: false, keyCode: 0))
            let details = inputDiagnosticEventDetails(event)
            #expect(details.eventKind == .keyDown)
            #expect(details.eventModifiers == UInt64(NSEvent.ModifierFlags([.command, .shift]).rawValue))
            #expect(details.hasCharacters == true)
            let data = try JSONEncoder().encode(details)
            #expect(!String(decoding: data, as: UTF8.self).contains(secret))
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["keyCode"] == nil)
            #expect(json["characters"] == nil)
            #expect(json["charactersIgnoringModifiers"] == nil)
        }

        @Test func emptyCharacterPayloadIsDistinguishableFromMissingEvent() throws {
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: 0))
            let details = inputDiagnosticEventDetails(event)
            #expect(details.eventKind == .keyDown)
            #expect(details.hasCharacters == false)
            #expect(details.hasCharactersIgnoringModifiers == false)
        }

        @Test func modifierEventsDoNotRequestTextPayload() throws {
            let event = try #require(
                NSEvent.keyEvent(
                    with: .flagsChanged, location: .zero, modifierFlags: [.command], timestamp: 0,
                    windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: 54))
            let details = inputDiagnosticEventDetails(event)
            #expect(details.eventKind == .flagsChanged)
            #expect(details.hasCharacters == nil)
            #expect(details.hasCharactersIgnoringModifiers == nil)
        }
    }
#endif
