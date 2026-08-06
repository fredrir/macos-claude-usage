import Foundation
import Testing

@testable import UsageCore

@Suite("Usage response decoding")
struct UsageResponseDTOTests {
    private let decoder = JSONDecoder()

    @Test("Decodes snake-case fields into camel-case properties")
    func decodesCamelCaseProperties() throws {
        let response = try decoder.decode(
            UsageResponseDTO.self,
            from: Data(
                #"""
                {
                  "five_hour": { "utilization": 42, "resets_at": "2026-08-06T21:00:00Z" },
                  "limits": [{
                    "kind": "weekly_scoped",
                    "percent": 73,
                    "severity": "warning",
                    "resets_at": "2026-08-10T00:00:00Z",
                    "is_active": true,
                    "scope": { "model": { "id": "model-1", "display_name": "Fable" } }
                  }]
                }
                """#.utf8
            )
        )

        #expect(response.fiveHour?.utilization == 42)
        #expect(response.fiveHour?.resetsAt == "2026-08-06T21:00:00Z")
        #expect(response.limits?.first?.resetsAt == "2026-08-10T00:00:00Z")
        #expect(response.limits?.first?.isActive == true)
        #expect(response.limits?.first?.scope?.model?.displayName == "Fable")
        #expect(response.limits?.first?.severity == .warning)
    }

    @Test("Accepts a recognized root whose values are all null")
    func acceptsRecognizedNullPayload() throws {
        let response = try decoder.decode(
            UsageResponseDTO.self,
            from: Data(#"{ "five_hour": null, "limits": null }"#.utf8)
        )

        #expect(response.fiveHour == nil)
        #expect(response.limits == nil)
    }

    @Test(
        "Rejects empty and unknown-only roots",
        arguments: [
            "{}",
            #"{ "new_schema": { "utilization": 12 } }"#,
        ])
    func rejectsUnrecognizedRoots(json: String) {
        #expect(throws: DecodingError.self) {
            try decoder.decode(UsageResponseDTO.self, from: Data(json.utf8))
        }
    }

    @Test("Rejects a malformed recognized field")
    func rejectsMalformedKnownField() {
        #expect(throws: DecodingError.self) {
            try decoder.decode(
                UsageResponseDTO.self,
                from: Data(#"{ "five_hour": "not-an-object" }"#.utf8)
            )
        }
    }

    @Test("Preserves unknown severity values")
    func preservesUnknownSeverity() throws {
        let response = try decoder.decode(
            UsageResponseDTO.self,
            from: Data(#"{ "limits": [{ "severity": "elevated" }] }"#.utf8)
        )

        #expect(response.limits?.first?.severity == .unknown("elevated"))
    }
}
