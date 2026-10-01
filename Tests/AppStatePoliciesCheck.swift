import Foundation

@main
struct AppStatePoliciesCheck {
    static func main() throws {
        try checkHealthPlanPolicy()
        try checkHealthPlanPreferences()
        try checkProbeParser()
        try checkDiscoveryParser()
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
        let clientTunnel = ConnectionPathPresentation.make(mode: "Shadowrocket VPN")
        try require(clientTunnel.value == "虚拟网卡" && clientTunnel.isActive && !clientTunnel.isCombined,
                    "An attributed client VPN path must be presented as a virtual adapter.")
        let clientCombined = ConnectionPathPresentation.make(mode: "系统代理 + Shadowrocket VPN")
        try require(clientCombined.value == "系统代理 + 虚拟网卡" && clientCombined.isCombined,
                    "An attributed client VPN combined with a system proxy must remain orange.")
        let clientStatus = ConnectionStatusPresentation.make(
            mode: "Shadowrocket VPN", networkAvailable: true, probeAvailable: true)
        try require(clientStatus == .init(value: "虚拟网卡", detailOverride: nil, tone: .ok),
                    "An attributed client VPN path must be a green single-path status.")
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
            mode: "状态不可用", networkAvailable: true, probeAvailable: false)
                    == .init(value: "代理状态不可用", detailOverride: "暂时无法确认当前代理状态", tone: .error),
                    "Failed discovery must remain unavailable independently of health-probe results.")
        var pathMatrixCases = 0
        for (mode, expectedValue, expectedTone): (String, String, ConnectionStatusTone) in [
            ("系统代理", "系统代理", .ok),
            ("Shadowrocket VPN", "虚拟网卡", .ok),
            ("系统代理 + Shadowrocket VPN", "系统代理 + 虚拟网卡", .warning)
        ] {
            for network: Bool? in [true, false, nil] {
                for healthProbeAvailable in [true, false] {
                    let expected: ConnectionStatusPresentation = network == false
                        ? .init(value: "无网络连接", detailOverride: "请检查网络连接", tone: .error)
                        : .init(value: expectedValue, detailOverride: nil, tone: expectedTone)
                    try require(ConnectionStatusPresentation.make(
                        mode: mode, networkAvailable: network, probeAvailable: healthProbeAvailable) == expected,
                        "A fresh path stays factual when health diagnostics fail; known disconnection always takes precedence.")
                    pathMatrixCases += 1
                }
            }
        }
        for healthProbeAvailable in [true, false] {
            try require(ConnectionStatusPresentation.make(
                mode: "未开启", networkAvailable: nil, probeAvailable: healthProbeAvailable) == nil,
                "An unknown network must not be presented as confirmed direct networking.")
            pathMatrixCases += 1
        }
        for network: Bool? in [true, false, nil] {
            for healthProbeAvailable in [true, false] {
                let expected: ConnectionStatusPresentation = network == false
                    ? .init(value: "无网络连接", detailOverride: "请检查网络连接", tone: .error)
                    : .init(value: "代理状态不可用", detailOverride: "暂时无法确认当前代理状态", tone: .error)
                try require(ConnectionStatusPresentation.make(
                    mode: "状态不可用", networkAvailable: network, probeAvailable: healthProbeAvailable) == expected,
                    "Failed discovery must not inherit a successful health-probe card; known disconnection still wins.")
                pathMatrixCases += 1
            }
        }
        print("Connection presentation matrix cases: \(pathMatrixCases).")
    }

    private static func checkDiscoveryParser() throws {
        let valid = "found\t1\nclient\tShadowrocket\ncore\tMacPacketTunnel\nendpoint\t127.0.0.1:1082\nmode\t系统代理 + Shadowrocket VPN\nsource\tmacOS 系统代理\nactive\tok\nprivacy\t仅读取本地端口与运行模式，不读取订阅和节点\n"
        let records = valid.split(separator: "\n").map(String.init)
        var positiveCases = 0
        var rejectedCases = 0
        var resultCases = 0
        let parsed = DiscoveryOutputParser.parse(valid)
        try require(parsed?.client == "Shadowrocket" && parsed?.core == "MacPacketTunnel"
                    && parsed?.found == true && parsed?.active == true,
                    "A complete discovery must retain the actual client, core and listener state.")
        positiveCases += 1
        for mode in ["Shadowrocket VPN", "其他 VPN / TUN", "Mihomo TUN（代表性路由不一致）"] {
            let tunnelOnly = valid.replacingOccurrences(of: "found\t1", with: "found\t0")
                .replacingOccurrences(of: "active\tok", with: "active\tidle")
                .replacingOccurrences(of: "mode\t系统代理 + Shadowrocket VPN", with: "mode\t\(mode)")
            try require(DiscoveryOutputParser.parse(tunnelOnly)?.mode == mode,
                        "A virtual path without a local listening endpoint is a valid discovery.")
            positiveCases += 1
        }
        let unknown = valid.replacingOccurrences(of: "client\tShadowrocket", with: "client\t未识别")
            .replacingOccurrences(of: "core\tMacPacketTunnel", with: "core\t")
        try require(DiscoveryOutputParser.parse(unknown)?.core == "",
                    "An empty core is valid unknown attribution, not a missing record.")
        positiveCases += 1
        let direct = unknown.replacingOccurrences(of: "mode\t系统代理 + Shadowrocket VPN", with: "mode\t未开启")
            .replacingOccurrences(of: "found\t1", with: "found\t0")
            .replacingOccurrences(of: "active\tok", with: "active\tidle")
        try require(DiscoveryOutputParser.parse(direct)?.mode == "未开启",
                    "Confirmed direct networking must remain distinguishable from failed discovery.")
        positiveCases += 1
        try require(DiscoveryOutputParser.parse(valid.replacingOccurrences(of: "active\tok", with: "active\tidle"))?.found == true,
                    "A discovered configured endpoint may be idle without invalidating the snapshot.")
        positiveCases += 1
        try require(DiscoveryOutputParser.parse(records.reversed().joined(separator: "\n")) == parsed,
                    "Discovery records form an atomic snapshot regardless of record order.")
        positiveCases += 1

        for mode in [
            "未开启", "系统代理", "PAC / 自动代理", "双重入口", "TUN",
            "系统代理 + 其他 VPN / TUN", "其他 VPN / TUN",
            "系统代理 + Shadowrocket VPN", "Shadowrocket VPN",
            "系统代理 + Mihomo VPN", "Mihomo VPN",
            "PAC / 自动代理 + Mihomo TUN", "系统代理路径 + Mihomo TUN",
            "系统代理 + Mihomo TUN（路由待确认）",
            "系统代理 + Mihomo TUN（代表性路由不一致）",
            "系统代理 + Mihomo TUN（路由查询失败）",
            "Mihomo TUN（路由待确认）", "Mihomo TUN（代表性路由不一致）",
            "Mihomo TUN（路由查询失败）"
        ] {
            let modeFixture = valid.replacingOccurrences(of: "mode\t系统代理 + Shadowrocket VPN", with: "mode\t\(mode)")
            try require(DiscoveryOutputParser.parse(modeFixture)?.mode == mode,
                        "Every current backend mode must retain its existing presentation semantics: \(mode).")
            positiveCases += 1
        }

        for record in records {
            let incomplete = records.filter { $0 != record }.joined(separator: "\n")
            try require(DiscoveryOutputParser.parse(incomplete) == nil,
                        "Missing discovery record must invalidate the snapshot: \(record.prefix { $0 != "\t" }).")
            rejectedCases += 1
            try require(DiscoveryOutputParser.parse(valid + record + "\n") == nil,
                        "A duplicate discovery record must not overwrite an earlier observation.")
            rejectedCases += 1
        }
        let malformed = [
            "",
            valid + "extra\tvalue\n",
            valid + "malformed-line\n",
            valid.replacingOccurrences(of: "client\tShadowrocket", with: "client\tShadowrocket\textra"),
            valid.replacingOccurrences(of: "found\t1", with: "found\ttrue"),
            valid.replacingOccurrences(of: "active\tok", with: "active\tunknown"),
            valid.replacingOccurrences(of: "found\t1", with: "found\t0"),
            valid.replacingOccurrences(of: "mode\t系统代理 + Shadowrocket VPN", with: "mode\t"),
            valid.replacingOccurrences(of: "mode\t系统代理 + Shadowrocket VPN", with: "mode\tgarbage"),
            valid.replacingOccurrences(of: "mode\t系统代理 + Shadowrocket VPN", with: "mode\t未开启 VPN"),
            valid.replacingOccurrences(of: "client\tShadowrocket", with: "client\t"),
            valid.replacingOccurrences(of: "endpoint\t127.0.0.1:1082", with: "endpoint\t10.0.0.1:1082"),
            valid.replacingOccurrences(of: "client\tShadowrocket", with: "client\tShadow\0rocket"),
            valid.replacingOccurrences(of: "core\tMacPacketTunnel", with: "core\t\u{202E}MacPacketTunnel"),
            valid.replacingOccurrences(of: "client\tShadowrocket", with: "client\t" + String(repeating: "x", count: 257)),
            String(repeating: valid, count: 1_000)
        ]
        for output in malformed {
            try require(DiscoveryOutputParser.parse(output) == nil,
                        "Malformed, contradictory or unsafe discovery output must not fabricate a path.")
            rejectedCases += 1
        }
        for status: Int32 in [1, 124, 130] {
            var current = parsed!
            current = DiscoveryResultPolicy.make(status: status, output: valid, fallbackEndpoint: "localhost:1082")
            try require(current.mode == "状态不可用" && !current.found && !current.active
                        && current.client == "未识别" && current.core.isEmpty
                        && current.endpoint == "127.0.0.1:1082",
                        "A failed, timed out or cancelled command must discard stale client and path evidence.")
            try require(ConnectionStatusPresentation.make(mode: current.mode, networkAvailable: true, probeAvailable: false)?.tone == .error,
                        "Unavailable discovery must not be presented as confirmed direct networking.")
            resultCases += 1
        }
        for output in ["", valid + "mode\tShadowrocket VPN\n"] {
            let unavailable = DiscoveryResultPolicy.make(status: 0, output: output, fallbackEndpoint: nil)
            try require(unavailable.mode == "状态不可用" && unavailable.core.isEmpty,
                        "Exit zero alone must not make incomplete or duplicate discovery output trustworthy.")
            resultCases += 1
        }
        try require(DiscoveryResultPolicy.make(status: 0, output: valid, fallbackEndpoint: "localhost:7890") == parsed,
                    "Fresh valid discovery must retain its own endpoint rather than a saved endpoint.")
        resultCases += 1
        try require(DiscoveryResultPolicy.make(status: 1, output: "", fallbackEndpoint: "10.0.0.1:1082").endpoint == "127.0.0.1:7890",
                    "The unavailable snapshot must not retain a nonlocal fallback endpoint.")
        resultCases += 1
        print("Discovery snapshot cases: \(positiveCases) valid, \(rejectedCases) rejected, \(resultCases) result transitions.")
    }

    private static func checkGuardSelection() throws {
        let sample = "AUTO\n/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo\n0\nlo0 utun0\n"
        let snapshot = GuardSelectionSnapshot.parse(sample)
        try require(snapshot?.tunnels == ["lo0", "utun0"], "Trusted runtime TUN selection must parse.")
        try require(snapshot?.trustedMihomoTunnels == ["utun0"], "A root-selected Mihomo core must export only its TUN interfaces.")
        try require(snapshot?.detectedClientName == "Clash Verge Rev", "The selected core must provide a privacy-safe client label.")
        let neSelection = GuardSelectionSnapshot.parse(
            "AUTO\n/Applications/Shadowrocket.app/Contents/PlugIns/MacPacketTunnel.appex/Contents/MacOS/MacPacketTunnel\n0\nlo0 utun5\n")
        try require(neSelection?.detectedClientName == "Shadowrocket",
                    "A selected MacPacketTunnel engine must map to the Shadowrocket client name.")
        let shadowrocketSelection = GuardSelectionSnapshot.parse(
            "AUTO\n/Applications/Shadowrocket.app/Contents/MacOS/Shadowrocket\n0\nlo0 utun5\n")
        try require(shadowrocketSelection?.detectedClientName == "Shadowrocket",
                    "A selected Shadowrocket executable must map to the Shadowrocket client name.")
        try require(neSelection?.trustedMihomoTunnels == nil,
                    "A selected NE client must not export Mihomo tunnel trust.")
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
