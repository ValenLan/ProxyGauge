import Foundation

@main
struct AppStatePoliciesCheck {
    static func main() throws {
        try checkHealthPlanPolicy()
        try checkHealthPlanPreferences()
        try checkProbeParser()
        try checkRefreshLifecyclePolicy()
        try checkUpdateSchedule()
        try checkGuardSelection()
        try checkConnectionPresentation()
        print("ProxyGauge app-state policy tests passed.")
    }

    private static func checkConnectionPresentation() throws {
        let system = ConnectionPathPresentation.make(mode: "系统代理")
        try require(system.value == "系统代理" && system.isActive && !system.isCombined,
                    "A system proxy must have a green single-path presentation.")
        let tunnel = ConnectionPathPresentation.make(mode: "其他 VPN / TUN")
        try require(tunnel.value == "虚拟网卡" && tunnel.isActive && !tunnel.isCombined,
                    "An active VPN/TUN must be presented as a virtual adapter.")
        let combined = ConnectionPathPresentation.make(mode: "系统代理 + 其他 VPN / TUN")
        try require(combined.value == "系统代理 + 虚拟网卡" && combined.isCombined,
                    "A simultaneous system proxy and virtual adapter must remain orange.")
        try require(ConnectionPathPresentation.make(mode: "未开启").value == nil,
                    "An inactive path must not fabricate a connection type.")
        let offline = ConnectionStatusPresentation.make(
            mode: "TUN", networkAvailable: false, probeAvailable: true)
        try require(offline == .init(value: "无网络连接", detailOverride: "请检查网络连接", tone: .error),
                    "A disconnected network must take precedence over stale proxy-path evidence.")
        let direct = ConnectionStatusPresentation.make(
            mode: "未开启", networkAvailable: true, probeAvailable: true)
        try require(direct == .init(value: "未检测到代理", detailOverride: "当前使用直连网络", tone: .idle),
                    "A connected network without a proxy must be a neutral direct connection.")
        try require(ConnectionStatusPresentation.make(
            mode: "状态不可用", networkAvailable: true, probeAvailable: false) == nil,
                    "A failed probe must not be misreported as confirmed direct networking.")
    }

    private static func checkGuardSelection() throws {
        let sample = "AUTO\n/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo\n0\nlo0 utun0\n"
        let snapshot = GuardSelectionSnapshot.parse(sample)
        try require(snapshot?.tunnels == ["lo0", "utun0"], "Trusted runtime TUN selection must parse.")
        try require(snapshot?.trustedMihomoTunnels == ["utun0"], "A root-selected Mihomo core must export only its TUN interfaces.")
        try require(snapshot?.detectedClientName == "Clash Verge Rev", "The selected core must provide a privacy-safe client label.")
        let otherCore = GuardSelectionSnapshot.parse(sample.replacingOccurrences(of: "verge-mihomo", with: "other-vpn"))
        try require(otherCore?.trustedMihomoTunnels == nil, "Another VPN selection must not be attributed to Mihomo.")
        let ambiguous = GuardSelectionSnapshot.parse(sample.replacingOccurrences(of: "\n0\n", with: "\n1\n"))
        try require(ambiguous?.trustedMihomoTunnels == nil, "An ambiguous core selection must fail closed.")
        try require(GuardRuntimeState.parse("enabled\n"), "The exact enabled runtime record must be accepted.")
        try require(!GuardRuntimeState.parse("enabled\tfault\n"), "A decorated runtime record must not enable attribution.")
        try require(!GuardRuntimeState.parse("disabled\n"), "A disabled guard must not export stale attribution.")
        try require(GuardSelectionSnapshot.parse(sample + "extra\n") == nil, "Unexpected runtime records must fail closed.")
        try require(GuardSelectionSnapshot.parse(sample.replacingOccurrences(of: "utun0", with: "en0")) == nil, "Physical interfaces cannot be granted as tunnels.")
        try require(!GuardApplicationPolicy.validPath("/Applications/../bin/core"), "Traversal cannot reach root helper selection.")
        try require(!GuardApplicationPolicy.validPath("/Applications/core\nother"), "Newline path cannot reach root helper selection.")
        let choices = GuardApplicationPolicy.parseChoices("0\t/Applications/Clash Verge.app/core\n501\t/Applications/core\n0\t/Applications/Clash Verge.app/core\n")
        try require(choices.count == 2 && choices[0].uid == 0, "Selection must preserve spaces and deduplicate paths.")
        var loading = ExitLoadingGate()
        let start = Date(timeIntervalSince1970: 0)
        try require(loading.begin(at: start), "Initial refresh must show checking.")
        try require(loading.begin(at: start.addingTimeInterval(7)), "Checking remains within deadline.")
        try require(!loading.begin(at: start.addingTimeInterval(8)), "Repeated refresh cannot restart the eight-second deadline.")
        loading.finish()
        try require(loading.begin(at: start.addingTimeInterval(9)), "Completed refresh must allow a future fresh check.")
    }

    private static func checkHealthPlanPolicy() throws {
        let valid = HealthPlanPolicy.isValid(
            secondaryLabel: "Google / Gemini / Claude",
            secondaryGroup: "Google-Chain",
            defaultGroup: "PROXY",
            secondaryEndpoint: "127.0.0.1:7891",
            secondaryDomains: "gemini.google.com, api.anthropic.com"
        )
        try require(valid, "The supported health plan must remain valid.")
        try require(!HealthPlanPolicy.isValid(
            secondaryLabel: "Bad\0Label",
            secondaryGroup: "Google-Chain",
            defaultGroup: "PROXY",
            secondaryEndpoint: "127.0.0.1:7891",
            secondaryDomains: "gemini.google.com"
        ), "Control characters must never reach a child-process environment.")
        try require(!HealthPlanPolicy.isValid(
            secondaryLabel: "Plan",
            secondaryGroup: "Google-Chain",
            defaultGroup: "PROXY",
            secondaryEndpoint: "10.0.0.1:7891",
            secondaryDomains: "gemini.google.com"
        ), "Only a local loopback endpoint is valid.")
        try require(!HealthPlanPolicy.isValid(
            secondaryLabel: "Plan",
            secondaryGroup: "Google-Chain",
            defaultGroup: "PROXY",
            secondaryEndpoint: "127.0.0.1:7891",
            secondaryDomains: "good.example, bad..example"
        ), "Malformed DNS labels must be rejected.")
        try require(!HealthPlanPolicy.isValid(
            secondaryLabel: "Plan",
            secondaryGroup: "Google-Chain",
            defaultGroup: "PROXY",
            secondaryEndpoint: "127.0.0.1:7891",
            secondaryDomains: "good.example, GOOD.EXAMPLE"
        ), "Duplicate normalized domains must be rejected.")
    }

    private static func checkHealthPlanPreferences() throws {
        let suiteName = "com.valenlan.proxygauge.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CheckError.failed("Could not create isolated preferences.")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: ProxyGaugePreferences.secondaryEnabledKey)
        defaults.set("Bad\0Label", forKey: ProxyGaugePreferences.secondaryLabelKey)
        let corruptedEnabled = ProxyGaugePreferences.loadHealthPlan(defaults: defaults)
        try require(
            corruptedEnabled == .currentTemplate,
            "An enabled but corrupted persisted plan must fail closed to the safe template."
        )

        defaults.set(false, forKey: ProxyGaugePreferences.secondaryEnabledKey)
        defaults.set("Bad\0Label", forKey: ProxyGaugePreferences.secondaryLabelKey)
        let corruptedDisabled = ProxyGaugePreferences.loadHealthPlan(defaults: defaults)
        try require(
            corruptedDisabled == .currentTemplate,
            "Disabled stale fields must not leak unsafe values into every backend environment."
        )

        var disabledDraft = HealthCheckPlan.currentTemplate
        disabledDraft.secondaryEnabled = false
        disabledDraft.secondaryLabel = "Bad\0Label"
        ProxyGaugePreferences.saveHealthPlan(disabledDraft, defaults: defaults)
        let sanitizedDisabled = ProxyGaugePreferences.loadHealthPlan(defaults: defaults)
        try require(
            !sanitizedDisabled.secondaryEnabled
                && sanitizedDisabled.secondaryLabel == HealthCheckPlan.currentTemplate.secondaryLabel
                && sanitizedDisabled.hasValidStoredFields,
            "Disabling an invalid draft must persist a clean disabled template."
        )

        let validPlan = HealthCheckPlan(
            secondaryEnabled: true,
            secondaryLabel: "Custom",
            secondaryGroup: "AI",
            defaultGroup: "PROXY",
            secondaryEndpoint: "localhost:7891",
            secondaryDomains: "Gemini.Google.com, API.Anthropic.com"
        )
        ProxyGaugePreferences.saveHealthPlan(validPlan, defaults: defaults)
        let restored = ProxyGaugePreferences.loadHealthPlan(defaults: defaults)
        try require(restored.secondaryEnabled, "A valid enabled plan must remain enabled.")
        try require(
            restored.secondaryDomains == "gemini.google.com,api.anthropic.com",
            "Saved domains must use their normalized canonical representation."
        )
    }

    private static func checkProbeParser() throws {
        let valid = """
        overall\tok
        headline\t代理已接管
        detail\t流量入口当前工作正常
        core\t运行中\tok
        port\t127.0.0.1:7890\tok
        entry\t已启用\tok\t系统代理\tarrow.left.arrow.right
        system\t已启用\tok
        tun\t未启用\tidle
        kill\t已开启\tok
        """
        let parsed = ProbeOutputParser.parse(valid)
        try require(parsed?.overallLevel == "ok", "A complete probe must parse.")
        try require(parsed?.entry.title == "系统代理", "Entry presentation fields must parse atomically.")
        try require(parsed?.killSwitch.value == "已开启", "Kill Switch must be part of the same snapshot.")

        let missingKill = valid
            .split(separator: "\n")
            .filter { !$0.hasPrefix("kill\t") }
            .joined(separator: "\n")
        try require(
            ProbeOutputParser.parse(missingKill) == nil,
            "A partial probe must not preserve an old Kill Switch value."
        )
        try require(
            ProbeOutputParser.parse(valid + "kill\t已关闭\twarning\n") == nil,
            "Duplicate records must not override an earlier snapshot field."
        )
        try require(
            ProbeOutputParser.parse(valid.replacingOccurrences(
                of: "detail\t流量入口当前工作正常",
                with: "detail\t伪造\u{202E}内容"
            )) == nil,
            "Directional-control text must not reach the dashboard."
        )
        try require(
            ProbeOutputParser.parse(valid.replacingOccurrences(
                of: "entry\t已启用\tok\t系统代理\tarrow.left.arrow.right",
                with: "entry\t已启用\tok\t系统代理\tinvalid symbol"
            )) == nil,
            "Unexpected icon identifiers must invalidate the snapshot."
        )
    }

    private static func checkRefreshLifecyclePolicy() throws {
        try require(!ExitRefreshTriggerPolicy.pathDidChange(
            previous: nil, current: "path-a"
        ), "The first local fingerprint must establish a baseline without a public lookup.")
        try require(!ExitRefreshTriggerPolicy.pathDidChange(
            previous: "path-a", current: "path-a"
        ), "An unchanged route notification must not query the actual exit.")
        try require(ExitRefreshTriggerPolicy.pathDidChange(
            previous: "path-a", current: "path-b"
        ), "A changed route fingerprint must request a new actual-exit lookup.")
        try require(!ExitRefreshTriggerPolicy.shouldStartLookup(
            isApplicationActive: true, hasPendingPathChange: false
        ), "Opening or activating the dashboard alone must not query the actual exit.")
        try require(!ExitRefreshTriggerPolicy.shouldStartLookup(
            isApplicationActive: false, hasPendingPathChange: true
        ), "A background path change must remain pending instead of issuing public traffic.")
        try require(ExitRefreshTriggerPolicy.shouldStartLookup(
            isApplicationActive: true, hasPendingPathChange: true
        ), "A real path change may query once the application is active.")
    }

    private static func checkUpdateSchedule() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        try require(!UpdateCheckSchedule.shouldCheck(
            lastSuccessfulCheck: now.addingTimeInterval(-UpdateCheckSchedule.interval + 1),
            now: now
        ), "A recent successful check must remain throttled.")
        try require(UpdateCheckSchedule.shouldCheck(
            lastSuccessfulCheck: now.addingTimeInterval(-UpdateCheckSchedule.interval),
            now: now
        ), "A successful check at the interval boundary must be eligible.")
        try require(UpdateCheckSchedule.shouldCheck(
            lastSuccessfulCheck: now.addingTimeInterval(60 * 60),
            now: now
        ), "A corrupt future timestamp must not suppress updates indefinitely.")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckError.failed(message) }
    }

    private enum CheckError: Error {
        case failed(String)
    }
}
