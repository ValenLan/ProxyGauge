import Foundation

private actor FixtureExitResolver: ExitSummaryResolving {
    private(set) var calls = 0
    let result: ExitSummarySnapshot
    init(result: ExitSummarySnapshot = .init(address: "1.1.1.1", location: "Australia")) {
        self.result = result
    }
    func resolve() async -> ExitSummarySnapshot {
        calls += 1
        return result
    }
}

@main
struct ExitInitializationCheck {
    @MainActor
    static func main() async throws {
        let fingerprint = String(repeating: "a", count: 64)
        for state in ["empty", "fingerprint-only", "summary-only", "complete"] {
            let suite = "proxygauge.initial-exit-test.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            if state == "fingerprint-only" || state == "complete" {
                ExitSummaryPersistence.recordPathFingerprint(fingerprint, clearSummary: true, defaults: defaults)
            }
            if state == "summary-only" || state == "complete" {
                ExitSummaryPersistence.saveSummary(
                    .init(address: "9.9.9.9", location: "Switzerland"), defaults: defaults
                )
            }
            let resolver = FixtureExitResolver()
            let model = ProxyModel(startImmediately: false, exitSummaryService: resolver, exitDefaults: defaults)
            let shouldLookup = model.observeExitPathFingerprint(fingerprint)
            try require(shouldLookup == (state != "complete"), "Incorrect initial lookup for \(state)")
            if shouldLookup { await model.refreshExitSummary() }
            try require(model.exitAddress == (state == "complete" ? "9.9.9.9" : "1.1.1.1"),
                        "The initial observation must display a confirmed IP: \(state)")
            for _ in 0..<3 {
                try require(!model.observeExitPathFingerprint(fingerprint), "Duplicate event requested a lookup")
            }
            let calls = await resolver.calls
            try require(calls == (state == "complete" ? 0 : 1), "Initialization must resolve at most once")
            let reopened = ProxyModel(startImmediately: false, exitSummaryService: resolver, exitDefaults: defaults)
            try require(!reopened.observeExitPathFingerprint(fingerprint), "Reopening must use the confirmed cache")
            try require(reopened.exitAddress == model.exitAddress, "Reopened cache lost the initial IP")
            let changed = String(repeating: "b", count: 64)
            try require(model.observeExitPathFingerprint(changed), "A real path change must request a lookup")
            try require(PublicIPAddress.normalize(model.exitAddress) == nil, "Path change retained the old IP")
            try require(ExitSummaryPersistence.loadSummary(defaults: defaults) == nil, "Path change retained stale cache")
            await model.refreshExitSummary()
            try require(model.exitAddress == "1.1.1.1", "Changed path did not receive the new IP")
            print("Initial exit scenario passed: \(state); initial resolver calls: \(calls)")
        }

        let suite = "proxygauge.initial-exit-failure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = FixtureExitResolver(result: .unavailable)
        let model = ProxyModel(startImmediately: false, exitSummaryService: resolver, exitDefaults: defaults)
        try require(model.observeExitPathFingerprint(fingerprint), "Missing cache must initialize")
        await model.refreshExitSummary()
        try require(model.exitAddress == ExitSummarySnapshot.unavailable.address, "Failure must settle visibly")
        try require(!model.observeExitPathFingerprint(fingerprint), "Failure must not cause event-driven retry loops")
        let reopened = ProxyModel(startImmediately: false, exitSummaryService: resolver, exitDefaults: defaults)
        try require(reopened.observeExitPathFingerprint(fingerprint), "A new session must retry a missing result")
        print("Initial exit failure/reopen scenario passed.")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "ExitInitializationCheck", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
