import Foundation
import Testing

struct SecurityScopedAccessTests {
    @Test func successfulGrantsSurviveBackgroundWorkAndStopExactlyOnce() async throws {
        let starts = ResultLog(), stops = ResultLog()
        let url = URL(filePath: "/selected/folder")
        var lease: SecurityScopedAccess? = SecurityScopedAccess(url, start: { starts.record($0); return true },
                                                               stop: { stops.record($0) })
        let worker = Task { [access = lease] in
            try await Task.sleep(for: .milliseconds(30))
            #expect(stops.count == 0)
            withExtendedLifetime(access) { }
        }
        lease = nil // Replacing/removing a selected item must not revoke a still-running worker's grant.
        #expect(starts.count == 1 && stops.count == 0)
        try await worker.value
        #expect(stops.count == 1)
    }

    @Test func ordinaryAccessibleURLsDoNotReceiveAnUnbalancedStop() throws {
        let dir = try TempDir(), stops = ResultLog()
        let url = try dir.file("photo.jpg")
        do {
            let access = SecurityScopedAccess(url, start: { _ in false }, stop: { stops.record($0) })
            #expect(try Data(contentsOf: access.url) == Data("x".utf8))
        }
        #expect(stops.count == 0)
    }
}
