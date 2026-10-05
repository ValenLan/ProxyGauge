import Foundation

@MainActor
private final class DiagnosticEnvironment {
    let defaults = ExitTestDefaults()
    let resolver = ExitTestResolver()
    var mode = "系统代理 + Shadowrocket VPN"
    var probeResult: (status: Int32, output: String) = (0, DiagnosticEnvironment.probe())
    var discoveryStatus: Int32 = 0
    var suspendProbe = false
    var pendingProbe: CheckedContinuation<(status: Int32, output: String), Never>?
    var heldProbe: (status: Int32, output: String)?
    let probeStarted = AsyncStream<Bool>.makeStream()

    static func probe(overall: String = "ok", entry: String = "ok") -> String {
        "overall\t\(overall)\nheadline\tfixture\ndetail\tfixture\ncore\tMacPacketTunnel\tok\nport\t1082\tok\nentry\tfixture\t\(entry)\t双重入口\tarrow.triangle.2.circlepath\nsystem\t启用\tok\ntun\t启用\tok\nkill\t监测中\tok\n"
    }

    func makeModel() -> ProxyModel {
        ProxyModel(
            startImmediately: false, exitSummaryService: resolver, exitDefaults: defaults,
            commandExecutor: { [self] action, _ in
                switch action {
                case "probe":
                    let result = probeResult
                    if suspendProbe {
                        suspendProbe = false
                        heldProbe = result
                        return await withCheckedContinuation { continuation in
                            pendingProbe = continuation
                            probeStarted.continuation.yield(true)
                        }
                    }
                    return result
                case "discover":
                    return (discoveryStatus, "found\t1\nclient\tShadowrocket\ncore\tMacPacketTunnel\nendpoint\t127.0.0.1:1082\nmode\t\(mode)\nsource\tfixture\nactive\tok\nprivacy\tfixture\n")
                default:
                    preconditionFailure("Unexpected nonlocal command: \(action)")
                }
            },
            pathFingerprintProvider: { nil }, applicationIsActive: { true },
            guardSelectionReader: { nil }, pathDebounce: .zero, exitDebounce: .zero
        )
    }

    func releaseProbe() {
        precondition(pendingProbe != nil && heldProbe != nil)
        pendingProbe?.resume(returning: heldProbe!)
        pendingProbe = nil
        heldProbe = nil
    }
}

@main
struct ConnectionStatusDiagnosticCheck {
    @MainActor static func main() async {
        do {
            try await check()
        } catch {
            FileHandle.standardError.write(Data(("Connection diagnostic failure: \(error.localizedDescription)\n").utf8))
            exit(1)
        }
    }

    @MainActor private static func check() async throws {
        var cases = 0
        for (overall, entry, expected): (String, String, HealthLevel) in [
            ("ok", "ok", .ok), ("warning", "ok", .warning),
            ("ok", "warning", .warning), ("error", "ok", .error),
            ("ok", "error", .error), ("warning", "error", .error)
        ] {
            let environment = DiagnosticEnvironment()
            environment.probeResult = (0, DiagnosticEnvironment.probe(overall: overall, entry: entry))
            let model = environment.makeModel()
            await model.refresh()
            try requireExit(model.connectionValue == "系统代理 + 虚拟网卡" && model.connectionLevel == expected,
                            "Valid current-generation \(overall)/\(entry) must color the actual model \(expected.rawValue) without changing its path fact.")
            cases += 1
        }

        for result: (status: Int32, output: String) in [
            (0, "invalid probe"), (124, DiagnosticEnvironment.probe(overall: "error")),
            (130, DiagnosticEnvironment.probe(overall: "warning"))
        ] {
            let environment = DiagnosticEnvironment()
            environment.probeResult = result
            let model = environment.makeModel()
            await model.refresh()
            try requireExit(model.connectionLevel == .ok && model.connectionValue == "系统代理 + 虚拟网卡",
                            "Invalid, failed or cancelled probe must not turn independent valid discovery into a fault.")
            cases += 1
        }

        let unavailable = DiagnosticEnvironment()
        unavailable.discoveryStatus = 124
        let unavailableModel = unavailable.makeModel()
        await unavailableModel.refresh()
        try requireExit(unavailableModel.connectionLevel == .error && unavailableModel.connectionValue == "代理状态不可用",
                        "Failed discovery must remain red even when probe is valid and healthy.")
        cases += 1

        let replaced = DiagnosticEnvironment()
        replaced.probeResult = (0, DiagnosticEnvironment.probe(overall: "warning"))
        let replacedModel = replaced.makeModel()
        await replacedModel.refresh()
        try requireExit(replacedModel.connectionLevel == .warning, "The first valid diagnosis should be orange.")
        replaced.mode = "Shadowrocket VPN"
        await replacedModel.discoverConnection()
        try requireExit(replacedModel.connectionValue == "虚拟网卡" && replacedModel.connectionLevel == .ok,
                        "Standalone newer discovery must not inherit a previous generation's diagnosis.")
        cases += 1

        let late = DiagnosticEnvironment()
        late.probeResult = (0, DiagnosticEnvironment.probe(overall: "error"))
        late.suspendProbe = true
        let lateModel = late.makeModel()
        let lateWork = Task { await lateModel.refresh() }
        try requireExit(await waitForSignal(late.probeStarted.stream), "Controlled late probe did not start.")
        late.mode = "Shadowrocket VPN"
        await lateModel.discoverConnection()
        late.releaseProbe()
        await lateWork.value
        try requireExit(lateModel.connectionValue == "虚拟网卡" && lateModel.connectionLevel == .ok,
                        "Late old-generation probe must not recolor a newer independently discovered path.")
        cases += 1

        let retained = DiagnosticEnvironment()
        retained.probeResult = (0, DiagnosticEnvironment.probe(overall: "warning"))
        let retainedModel = retained.makeModel()
        await retainedModel.refresh()
        retained.suspendProbe = true
        let retainedWork = Task { await retainedModel.refresh() }
        try requireExit(await waitForSignal(retained.probeStarted.stream), "Retained-diagnosis refresh did not start.")
        try requireExit(retainedModel.connectionLevel == .warning,
                        "Pending refresh must keep the diagnosis associated with the still displayed facts.")
        retained.mode = "Shadowrocket VPN"
        await retainedModel.discoverConnection()
        try requireExit(retainedModel.connectionLevel == .ok && retainedModel.connectionValue == "虚拟网卡",
                        "Accepted new normal discovery must clear the previous displayed diagnosis.")
        retained.releaseProbe()
        await retainedWork.value
        try requireExit(retainedModel.connectionLevel == .ok && retainedModel.connectionValue == "虚拟网卡",
                        "Late old warning must not restore the previous displayed diagnosis.")
        cases += 1

        let queued = DiagnosticEnvironment()
        queued.probeResult = (0, DiagnosticEnvironment.probe(overall: "error"))
        queued.suspendProbe = true
        let queuedModel = queued.makeModel()
        let first = Task { await queuedModel.refresh() }
        try requireExit(await waitForSignal(queued.probeStarted.stream), "Controlled cancelled refresh did not start.")
        queued.probeResult = (0, DiagnosticEnvironment.probe())
        queued.mode = "Shadowrocket VPN"
        let secondStarted = AsyncStream<Bool>.makeStream()
        let second = Task { @MainActor in
            secondStarted.continuation.yield(true)
            await queuedModel.refresh()
        }
        // The MainActor producer enters refresh and requests its generations
        // before it can suspend and let this signal's consumer continue.
        try requireExit(await waitForSignal(secondStarted.stream), "Queued refresh did not enter.")
        queued.releaseProbe()
        await first.value
        await second.value
        try requireExit(queuedModel.connectionValue == "虚拟网卡" && queuedModel.connectionLevel == .ok,
                        "Cancelled older refresh must not override the queued current healthy path.")
        cases += 1

        let offline = DiagnosticEnvironment()
        offline.probeResult = (0, DiagnosticEnvironment.probe(overall: "warning"))
        let offlineModel = offline.makeModel()
        offlineModel.networkPathDidChange(false)
        await offlineModel.waitForPendingNetworkUpdates()
        try requireExit(offlineModel.connectionLevel == .error && offlineModel.connectionValue == "无网络连接",
                        "Explicit offline state must take precedence over a valid warning diagnosis.")
        cases += 1

        let direct = DiagnosticEnvironment()
        direct.mode = "未开启"
        direct.probeResult = (0, DiagnosticEnvironment.probe(overall: "error"))
        let directModel = direct.makeModel()
        directModel.networkPathDidChange(true)
        await directModel.waitForPendingNetworkUpdates()
        try requireExit(directModel.connectionLevel == .idle && directModel.connectionValue == "未检测到代理",
                        "Confirmed direct networking must stay neutral rather than inherit proxy diagnostics.")
        let directExitCalls = await direct.resolver.calls
        let offlineExitCalls = await offline.resolver.calls
        try requireExit(directExitCalls == 0 && offlineExitCalls == 0,
                        "Local color checks must not start any public-exit query.")
        cases += 1
        print("Actual ProxyModel connection diagnosis colors: \(cases) cases passed; injected commands/volatile defaults, no GUI, proxy, Guard or public query.")
    }

    private static func waitForSignal(_ stream: AsyncStream<Bool>) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await signal in stream { return signal }
                return false
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(2)) } catch { return false }
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}
