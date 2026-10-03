import Foundation

// Every preference used by ProxyModel is volatile and independent of real defaults.
final class ExitTestDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: "proxygauge.volatile-exit-test.\(UUID().uuidString)")! }
    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

actor ExitTestResolver: ExitSummaryResolving {
    private(set) var calls = 0
    var result: ExitSummarySnapshot
    private var shouldSuspend = false
    private var pending: CheckedContinuation<ExitSummarySnapshot, Never>?
    let started = AsyncStream<Int>.makeStream()
    init(result: ExitSummarySnapshot = .init(address: "1.1.1.1", location: "Australia")) {
        self.result = result
    }
    func suspendNext() { shouldSuspend = true }
    func finishSuspended(_ value: ExitSummarySnapshot) { pending?.resume(returning: value); pending = nil }
    func resolve() async -> ExitSummarySnapshot {
        calls += 1
        if shouldSuspend {
            shouldSuspend = false
            return await withCheckedContinuation { continuation in
                pending = continuation
                started.continuation.yield(calls)
            }
        }
        started.continuation.yield(calls)
        return result
    }
}

@MainActor
final class ExitTestEnvironment {
    let defaults = ExitTestDefaults()
    let resolver: ExitTestResolver
    var active = true
    var fingerprint: String? = String(repeating: "a", count: 64)
    var commands: [String] = []
    var discoveryClient = "Shadowrocket"
    var suspendedFingerprint: CheckedContinuation<String?, Never>?
    var suspendNextFingerprint = false
    let fingerprintStarted = AsyncStream<Bool>.makeStream()
    init(result: ExitSummarySnapshot = .init(address: "1.1.1.1", location: "Australia")) {
        resolver = ExitTestResolver(result: result)
    }
    func makeModel() -> ProxyModel {
        ProxyModel(
            startImmediately: false, exitSummaryService: resolver, exitDefaults: defaults,
            commandExecutor: { [self] action, _ in
                commands.append(action)
                if action == "discover" {
                    return (0, "found\t1\nclient\t\(discoveryClient)\ncore\tMacPacketTunnel\nendpoint\t127.0.0.1:1082\nmode\tShadowrocket VPN\nsource\tfixture\nactive\tok\nprivacy\tfixture\n")
                }
                if action == "probe" {
                    return (0, "overall\tok\nheadline\tfixture\ndetail\tfixture\ncore\tMacPacketTunnel\tok\nport\t1082\tok\nentry\t启用\tok\t虚拟网卡\tnetwork\nsystem\t关闭\tidle\ntun\t启用\tok\nkill\t已关闭\twarning\n")
                }
                preconditionFailure("Unexpected real-command path: \(action)")
            },
            pathFingerprintProvider: { [self] in
                if suspendNextFingerprint {
                    suspendNextFingerprint = false
                    return await withCheckedContinuation { continuation in
                        suspendedFingerprint = continuation
                        fingerprintStarted.continuation.yield(true)
                    }
                }
                return fingerprint
            },
            applicationIsActive: { [self] in active }, guardSelectionReader: { nil },
            pathDebounce: .zero, exitDebounce: .zero
        )
    }
    func seedCache(path: Bool, summary: Bool) {
        if path { ExitSummaryPersistence.recordPathFingerprint(fingerprint!, clearSummary: true, defaults: defaults) }
        if summary { ExitSummaryPersistence.saveSummary(.init(address: "9.9.9.9", location: "Switzerland"), defaults: defaults) }
    }
}

func requireExit(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "ExitModelCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

#if !LIFECYCLE_TESTS
@main
struct ExitInitializationCheck {
    @MainActor static func main() async throws {
        var cases = 0
        for (label,path,summary) in [("empty",false,false),("fingerprint-only",true,false),("summary-only",false,true),("complete",true,true)] {
            let env = ExitTestEnvironment()
            env.seedCache(path: path, summary: summary)
            let model = env.makeModel()
            try requireExit(model.exitAddress != "等待出口变化", "Initialization must not wait indefinitely: \(label)")
            let lookup = model.observeExitPathFingerprint(env.fingerprint!)
            try requireExit(lookup == !(path && summary), "Wrong initialization decision: \(label)")
            if lookup { await model.refreshExitSummary() }
            let calls = await env.resolver.calls
            try requireExit(calls == (path && summary ? 0 : 1), "Wrong initial query count: \(label)")
            try requireExit(model.exitAddress == (path && summary ? "9.9.9.9" : "1.1.1.1"), "Missing confirmed initial IP: \(label)")
            for _ in 0..<3 { try requireExit(!model.observeExitPathFingerprint(env.fingerprint!), "Duplicate initialized observation") }
            await model.refreshExitSummary()
            try requireExit(await env.resolver.calls == calls, "Direct repeated lookup must respect the pending gate")
            let reopened = env.makeModel()
            try requireExit(!reopened.observeExitPathFingerprint(env.fingerprint!) && reopened.exitAddress == model.exitAddress, "Complete cache must survive reopening: \(label)")
            env.fingerprint = String(repeating: "b", count: 64)
            try requireExit(model.observeExitPathFingerprint(env.fingerprint!), "A changed path must request a new exit")
            try requireExit(PublicIPAddress.normalize(model.exitAddress) == nil && ExitSummaryPersistence.loadSummary(defaults: env.defaults) == nil, "Path change must clear visible and persisted old exit")
            await model.refreshExitSummary()
            try requireExit(await env.resolver.calls == calls + 1 && model.exitAddress == "1.1.1.1", "Changed path must resolve once")
            cases += 1
            print("PASS cache=\(label) initialCalls=\(calls); duplicate/reopen/path-change verified")
        }
        let failed = ExitTestEnvironment(result: .unavailable)
        let model = failed.makeModel()
        try requireExit(model.observeExitPathFingerprint(failed.fingerprint!), "Missing cache must attempt initialization")
        await model.refreshExitSummary()
        try requireExit(model.exitAddress == ExitSummarySnapshot.unavailable.address, "Failed attempt must settle visibly")
        for _ in 0..<3 { try requireExit(!model.observeExitPathFingerprint(failed.fingerprint!), "Same-session failure must not loop") }
        await model.refreshExitSummary()
        try requireExit(await failed.resolver.calls == 1, "Failed session must query once")
        let reopened = failed.makeModel()
        try requireExit(reopened.observeExitPathFingerprint(failed.fingerprint!), "New session without valid result must retry once")
        await reopened.refreshExitSummary()
        try requireExit(await failed.resolver.calls == 2, "Reopened failure must have exactly one new attempt")
        cases += 1
        print("PASS failure settles; no session loop; new session retries once")
        print("ProxyGauge real-model initialization scenarios: \(cases) passed; volatile defaults/mocked commands/resolver, no GUI or network.")
    }
}
#endif
