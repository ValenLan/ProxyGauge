import Foundation

@main
struct ExitLifecycleCheck {
    @MainActor static func main() async throws {
        var cases = 0
        let a = String(repeating: "a", count: 64)
        let b = String(repeating: "b", count: 64)
        let c = String(repeating: "c", count: 64)

        // Actual callback entry points refresh discovery even with no exit change.
        do {
            let env = ExitTestEnvironment(); env.seedCache(path: true, summary: true)
            let model = env.makeModel()
            model.networkPathDidChange(true); await model.waitForPendingNetworkUpdates()
            try requireExit(await env.resolver.calls == 0 && model.discovery.client == "Shadowrocket", "Initial complete cache must update only local state")
            env.discoveryClient = "Fresh local client"
            model.systemNetworkDidChange(); await model.waitForPendingNetworkUpdates()
            try requireExit(model.discovery.client == env.discoveryClient && model.exitAddress == "9.9.9.9", "Same fingerprint must refresh current discovery without dropping cache")
            env.fingerprint = nil; env.discoveryClient = "Fresh despite fingerprint failure"
            model.systemNetworkDidChange(); await model.waitForPendingNetworkUpdates()
            try requireExit(model.discovery.client == env.discoveryClient, "Fingerprint failure must not gate local discovery")
            await model.refresh()
            try requireExit(await env.resolver.calls == 0, "Local events/manual refresh must not query an unchanged exit")
            cases += 1; print("PASS same/failed fingerprint events and manual refresh update local state; public calls=0")
        }
        do {
            let env = ExitTestEnvironment(); env.seedCache(path: true, summary: true)
            let model = env.makeModel()
            for _ in 0..<8 { model.systemNetworkDidChange() }
            await model.waitForPendingNetworkUpdates()
            try requireExit(env.commands.filter { $0 == "probe" }.count == 1 && env.commands.filter { $0 == "discover" }.count == 1, "A synchronous event burst must coalesce local refresh")
            try requireExit(await env.resolver.calls == 0, "Coalescing must preserve the public gate")
            cases += 1; print("PASS 8-event burst coalesces to one local snapshot, no public lookup")
        }
        do {
            let env = ExitTestEnvironment(); env.seedCache(path: true, summary: true); env.active = false
            let model = env.makeModel(); env.fingerprint = b
            model.systemNetworkDidChange(); await model.waitForPendingNetworkUpdates()
            try requireExit(await env.resolver.calls == 0 && PublicIPAddress.normalize(model.exitAddress) == nil, "Background path change must invalidate old IP and defer public lookup")
            try requireExit(ExitSummaryPersistence.loadSummary(defaults: env.defaults) == nil, "Background change must clear persisted old IP")
            model.systemNetworkDidChange(); await model.waitForPendingNetworkUpdates()
            env.active = true; model.applicationDidBecomeActive(); await model.waitForPendingNetworkUpdates()
            try requireExit(await env.resolver.calls == 1 && model.exitAddress == "1.1.1.1", "Activation must consume the pending changed path once")
            model.applicationDidBecomeActive(); await model.waitForPendingNetworkUpdates()
            try requireExit(await env.resolver.calls == 1, "Repeated activation must not query again")
            cases += 1; print("PASS background change/duplicate event/activation coalesce into one lookup")
        }
        do {
            let env = ExitTestEnvironment(); env.seedCache(path: true, summary: true)
            let model = env.makeModel()
            model.networkPathDidChange(true); await model.waitForPendingNetworkUpdates()
            env.fingerprint = nil; model.networkPathDidChange(false); await model.waitForPendingNetworkUpdates()
            try requireExit(model.exitAddress == ExitSummarySnapshot.disconnected.address && model.connectionValue == "无网络连接", "Disconnection must replace both visible statuses")
            try requireExit(ExitSummaryPersistence.loadSummary(defaults: env.defaults) == nil, "Disconnection must invalidate confirmed cache")
            env.fingerprint = a; model.networkPathDidChange(true); await model.waitForPendingNetworkUpdates()
            try requireExit(await env.resolver.calls == 1 && model.exitAddress == "1.1.1.1" && model.connectionValue == "虚拟网卡", "Same-path reconnect must converge with one new confirmation")
            model.networkPathDidChange(true); await model.waitForPendingNetworkUpdates()
            try requireExit(await env.resolver.calls == 1, "Repeated satisfied path must not query again")
            cases += 1; print("PASS disconnect + failed fingerprint + same-path reconnect confirms once")
        }
        do {
            let env = ExitTestEnvironment(); let model = env.makeModel()
            model.networkPathDidChange(false); await model.waitForPendingNetworkUpdates()
            try requireExit(await env.resolver.calls == 0 && model.exitAddress == ExitSummarySnapshot.disconnected.address, "Offline startup must not issue public lookup")
            model.networkPathDidChange(true); await model.waitForPendingNetworkUpdates()
            try requireExit(await env.resolver.calls == 1 && model.exitAddress == "1.1.1.1", "Offline initialization must remain pending until connected")
            cases += 1; print("PASS offline initialization defers until connected")
        }
        do {
            let env = ExitTestEnvironment(); env.fingerprint = nil
            let model = env.makeModel()
            await model.evaluateCurrentPathChange(isStartup: true)
            try requireExit(model.exitAddress == ExitSummarySnapshot.unavailable.address, "Unavailable first fingerprint must settle instead of checking forever")
            await model.evaluateCurrentPathChange(isStartup: true)
            try requireExit(await env.resolver.calls == 0, "Missing fingerprint must not issue public lookup")
            env.fingerprint = a
            await model.evaluateCurrentPathChange(isStartup: true); await model.waitForPendingNetworkUpdates()
            try requireExit(await env.resolver.calls == 1 && model.exitAddress == "1.1.1.1", "A later usable fingerprint must initialize once")
            cases += 1; print("PASS unavailable initial fingerprint settles; later available path initializes once")
        }
        do {
            let env = ExitTestEnvironment(); env.seedCache(path: true, summary: true); env.active = false
            let model = env.makeModel(); env.suspendNextFingerprint = true
            let older = Task { await model.evaluateCurrentPathChange(isStartup: false) }
            for await _ in env.fingerprintStarted.stream { break }
            env.fingerprint = b; await model.evaluateCurrentPathChange(isStartup: false)
            env.suspendedFingerprint!.resume(returning: a); await older.value
            try requireExit(ExitSummaryPersistence.loadPathFingerprint(defaults: env.defaults) == b, "Late older A must not replace B baseline")
            await model.evaluateCurrentPathChange(isStartup: false)
            env.active = true; model.applicationDidBecomeActive(); await model.waitForPendingNetworkUpdates()
            try requireExit(await env.resolver.calls == 1, "Late A must not create a redundant lookup for unchanged B")
            cases += 1; print("PASS controlled late A cannot overwrite B or cause redundant lookup")
        }
        do {
            let env = ExitTestEnvironment(); env.seedCache(path: true, summary: true); env.active = false
            let model = env.makeModel(); env.suspendNextFingerprint = true
            let canceled = Task { await model.evaluateCurrentPathChange(isStartup: false) }
            for await _ in env.fingerprintStarted.stream { break }
            canceled.cancel(); env.suspendedFingerprint!.resume(returning: b); await canceled.value
            try requireExit(ExitSummaryPersistence.loadPathFingerprint(defaults: env.defaults) == a && model.exitAddress == "9.9.9.9", "Canceled fingerprint result must not modify state or cache")
            cases += 1; print("PASS canceled non-cooperative fingerprint result is rejected")
        }
        do {
            let env = ExitTestEnvironment(); let model = env.makeModel()
            model.systemNetworkDidChange()
            await model.evaluateCurrentPathChange(isStartup: true)
            await model.waitForPendingNetworkUpdates()
            try requireExit(await env.resolver.calls == 1, "Startup/callback overlap must initialize once and drain completed tasks")
            cases += 1; print("PASS startup/callback overlap drains without busy loop and initializes once")
        }
        do {
            let env = ExitTestEnvironment(); env.seedCache(path: true, summary: true)
            let model = env.makeModel(); try requireExit(model.observeExitPathFingerprint(b), "Changed B must request exit")
            await env.resolver.suspendNext()
            let older = Task { await model.refreshExitSummary() }
            for await _ in env.resolver.started.stream { break }
            try requireExit(model.observeExitPathFingerprint(c), "Changed C must supersede B")
            await model.refreshExitSummary()
            await env.resolver.finishSuspended(.init(address: "8.8.8.8", location: "Old B")); await older.value
            try requireExit(model.exitAddress == "1.1.1.1" && ExitSummaryPersistence.loadSummary(defaults: env.defaults)?.address == "1.1.1.1", "Late canceled exit B must not replace current C")
            cases += 1; print("PASS non-cooperative old exit result cannot overwrite current summary/cache")
        }
        do {
            let env = ExitTestEnvironment(); env.seedCache(path: true, summary: true)
            let model = env.makeModel(); try requireExit(model.observeExitPathFingerprint(b), "Changed B must request exit")
            await env.resolver.suspendNext()
            let lookup = Task { await model.refreshExitSummary() }
            for await _ in env.resolver.started.stream { break }
            env.active = false; model.applicationDidResignActive()
            await env.resolver.finishSuspended(.init(address: "1.1.1.1", location: "Australia")); await lookup.value
            env.active = true; env.fingerprint = b; model.applicationDidBecomeActive(); await model.waitForPendingNetworkUpdates()
            try requireExit(await env.resolver.calls == 1 && model.exitAddress == "1.1.1.1", "Finishing already issued query in background must not create activation retry")
            cases += 1; print("PASS already issued lookup finishes while inactive without activation retry")
        }
        for label in ["监测中", "已开启"] {
            let env = ExitTestEnvironment(result: .unavailable)
            let model = env.makeModel()
            model.guardSelection = GuardSelectionSnapshot.parse("AUTO\n/Applications/Proxy.app/Contents/MacOS/mihomo\n0\nlo0\n")
            model.killSwitch = MetricState(title: "Kill Switch", symbol: "shield", value: label, level: .ok)
            try requireExit(model.observeExitPathFingerprint(a), "Missing cache must attempt lookup")
            await model.refreshExitSummary()
            try requireExit(model.exitAddress == ExitSummarySnapshot.unavailable.address, "Guard intent/monitoring must not turn failed exit query into asserted disconnection")
            cases += 1
            print("PASS failed exit with Guard \(label) intent stays unavailable; no inferred disconnection")
        }
        print("ProxyGauge real-model lifecycle scenarios: \(cases) passed; controlled continuations, volatile defaults, injected state/commands/resolver, no GUI/network/Guard.")
    }
}
