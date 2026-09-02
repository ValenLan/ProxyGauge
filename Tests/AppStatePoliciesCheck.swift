import Foundation

@main
struct AppStatePoliciesCheck {
    static func main() throws {
        try checkHealthPlanPolicy()
        try checkHealthPlanPreferences()
        try checkProbeParser()
        try checkRefreshLifecyclePolicy()
        try checkUpdateSchedule()
        print("ProxyGauge app-state policy tests passed.")
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
        try require(!RefreshLifecyclePolicy.shouldSchedulePathRefresh(
            isSatisfied: true,
            isInitialPath: false,
            isApplicationActive: false
        ), "A background path change must not start a public exit lookup.")
        try require(RefreshLifecyclePolicy.shouldSchedulePathRefresh(
            isSatisfied: false,
            isInitialPath: true,
            isApplicationActive: true
        ), "An active app must refresh local state when its initial path is offline.")
        try require(!RefreshLifecyclePolicy.shouldSchedulePathRefresh(
            isSatisfied: true,
            isInitialPath: true,
            isApplicationActive: true
        ), "The initial satisfied callback must not duplicate the startup refresh.")
        try require(RefreshLifecyclePolicy.shouldSchedulePathRefresh(
            isSatisfied: true,
            isInitialPath: false,
            isApplicationActive: true
        ), "A foreground route change must refresh the actual exit.")
        try require(RefreshLifecyclePolicy.shouldRefreshOnActivation(
            secondsSinceLastRequest: 0.5,
            hasPendingInvalidation: true
        ), "A background invalidation must bypass the ordinary activation debounce.")
        try require(!RefreshLifecyclePolicy.shouldRefreshOnActivation(
            secondsSinceLastRequest: 0.5,
            hasPendingInvalidation: false
        ), "A duplicate activation without invalidation must remain debounced.")
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
