import Foundation

struct HealthCheckPlan: Sendable, Equatable {
    var secondaryEnabled = false
    var secondaryLabel = "Google / Gemini / Claude"
    var secondaryGroup = "Google-Chain"
    var defaultGroup = "PROXY"
    var secondaryEndpoint = "127.0.0.1:7891"
    var secondaryDomains = "gemini.google.com, generativelanguage.googleapis.com, www.google.com, claude.ai, api.anthropic.com, platform.claude.com, bridge.claudeusercontent.com"

    static let currentTemplate = HealthCheckPlan()

    var normalizedDomains: [String] {
        HealthPlanPolicy.normalizedDomains(secondaryDomains)
    }

    var hasValidStoredFields: Bool {
        HealthPlanPolicy.isValid(
            secondaryLabel: secondaryLabel,
            secondaryGroup: secondaryGroup,
            defaultGroup: defaultGroup,
            secondaryEndpoint: secondaryEndpoint,
            secondaryDomains: secondaryDomains
        )
    }

    var isValid: Bool {
        !secondaryEnabled || hasValidStoredFields
    }
}

enum ProxyGaugePreferences {
    static let setupCompletedKey = "proxygauge.connectionSetupCompleted.v1"
    static let selectedEndpointKey = "proxygauge.selectedMixedEndpoint"
    static let secondaryEnabledKey = "proxygauge.health.secondaryEnabled.v1"
    static let secondaryLabelKey = "proxygauge.health.secondaryLabel.v1"
    static let secondaryGroupKey = "proxygauge.health.secondaryGroup.v1"
    static let defaultGroupKey = "proxygauge.health.defaultGroup.v1"
    static let secondaryEndpointKey = "proxygauge.health.secondaryEndpoint.v1"
    static let secondaryDomainsKey = "proxygauge.health.secondaryDomains.v1"

    static func loadHealthPlan(defaults: UserDefaults = .standard) -> HealthCheckPlan {
        let template = HealthCheckPlan.currentTemplate
        let candidate = HealthCheckPlan(
            secondaryEnabled: defaults.bool(forKey: secondaryEnabledKey),
            secondaryLabel: defaults.string(forKey: secondaryLabelKey) ?? template.secondaryLabel,
            secondaryGroup: defaults.string(forKey: secondaryGroupKey) ?? template.secondaryGroup,
            defaultGroup: defaults.string(forKey: defaultGroupKey) ?? template.defaultGroup,
            secondaryEndpoint: defaults.string(forKey: secondaryEndpointKey) ?? template.secondaryEndpoint,
            secondaryDomains: defaults.string(forKey: secondaryDomainsKey) ?? template.secondaryDomains
        )
        return candidate.hasValidStoredFields ? candidate : template
    }

    static func saveHealthPlan(_ plan: HealthCheckPlan, defaults: UserDefaults = .standard) {
        guard plan.isValid else { return }
        var persistedPlan = plan
        if !persistedPlan.hasValidStoredFields {
            persistedPlan = .currentTemplate
            persistedPlan.secondaryEnabled = false
        }
        defaults.set(persistedPlan.secondaryEnabled, forKey: secondaryEnabledKey)
        defaults.set(persistedPlan.secondaryLabel, forKey: secondaryLabelKey)
        defaults.set(persistedPlan.secondaryGroup, forKey: secondaryGroupKey)
        defaults.set(persistedPlan.defaultGroup, forKey: defaultGroupKey)
        defaults.set(persistedPlan.secondaryEndpoint, forKey: secondaryEndpointKey)
        defaults.set(
            persistedPlan.normalizedDomains.joined(separator: ","),
            forKey: secondaryDomainsKey
        )
    }
}

enum HealthPlanPolicy {
    private static let forbiddenDirectionalScalars: Set<UInt32> = [
        0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069
    ]

    static func normalizedDomains(_ rawValue: String) -> [String] {
        rawValue
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }

    static func isValid(
        secondaryLabel: String,
        secondaryGroup: String,
        defaultGroup: String,
        secondaryEndpoint: String,
        secondaryDomains: String
    ) -> Bool {
        guard isSafeText(secondaryLabel, maximumScalars: 32),
              isSafeText(secondaryGroup, maximumScalars: 64),
              isSafeText(defaultGroup, maximumScalars: 64),
              LocalEndpointPolicy.normalize(secondaryEndpoint) != nil,
              secondaryDomains.utf8.count <= 2_048 else {
            return false
        }

        let domains = normalizedDomains(secondaryDomains)
        guard !domains.isEmpty,
              domains.count <= 8,
              domains.allSatisfy({ !$0.isEmpty && isValidDomain($0) }),
              Set(domains).count == domains.count else {
            return false
        }
        return true
    }

    private static func isSafeText(_ value: String, maximumScalars: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              value.unicodeScalars.count <= maximumScalars else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.newlines.contains(scalar)
                && !forbiddenDirectionalScalars.contains(scalar.value)
        }
    }

    private static func isValidDomain(_ value: String) -> Bool {
        guard value.utf8.count <= 253,
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 45, 46, 48...57, 97...122:
                      return true
                  default:
                      return false
                  }
              }) else {
            return false
        }

        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        return !labels.isEmpty && labels.allSatisfy { label in
            !label.isEmpty
                && label.utf8.count <= 63
                && label.first != "-"
                && label.last != "-"
        }
    }
}

struct ProbeMetricPayload: Equatable, Sendable {
    let value: String
    let level: String
    let title: String?
    let symbol: String?
}

struct ProbeOutputPayload: Equatable, Sendable {
    let overallLevel: String
    let headline: String
    let detail: String
    let core: ProbeMetricPayload
    let port: ProbeMetricPayload
    let entry: ProbeMetricPayload
    let killSwitch: ProbeMetricPayload
}

enum ProbeOutputParser {
    private static let allowedLevels: Set<String> = ["ok", "warning", "error", "idle"]
    private static let allowedKeys: Set<String> = [
        "overall", "headline", "detail", "core", "port", "entry", "system", "tun", "kill"
    ]
    private static let forbiddenDirectionalScalars: Set<UInt32> = [
        0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069
    ]

    static func parse(_ output: String) -> ProbeOutputPayload? {
        guard !output.isEmpty, output.utf8.count <= 64 * 1_024 else { return nil }
        var records: [String: [String]] = [:]
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard rawLine.utf8.count <= 1_024 else { return nil }
            let fields = rawLine.split(
                separator: "\t",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard let key = fields.first,
                  allowedKeys.contains(key),
                  records[key] == nil else {
                return nil
            }
            records[key] = Array(fields.dropFirst())
        }

        guard records.keys.count == allowedKeys.count,
              let overall = scalar(records["overall"], maximumScalars: 16),
              allowedLevels.contains(overall),
              let headline = scalar(records["headline"], maximumScalars: 128),
              let detail = scalar(records["detail"], maximumScalars: 256),
              let core = metric(records["core"]),
              let port = metric(records["port"]),
              let entry = metric(records["entry"], includesPresentation: true),
              metric(records["system"]) != nil,
              metric(records["tun"]) != nil,
              let killSwitch = metric(records["kill"]) else {
            return nil
        }

        return ProbeOutputPayload(
            overallLevel: overall,
            headline: headline,
            detail: detail,
            core: core,
            port: port,
            entry: entry,
            killSwitch: killSwitch
        )
    }

    private static func metric(
        _ fields: [String]?,
        includesPresentation: Bool = false
    ) -> ProbeMetricPayload? {
        let expectedCount = includesPresentation ? 4 : 2
        guard let fields,
              fields.count == expectedCount,
              isSafeField(fields[0], maximumScalars: 256),
              allowedLevels.contains(fields[1]) else {
            return nil
        }
        if includesPresentation {
            guard isSafeField(fields[2], maximumScalars: 64),
                  fields[3].range(
                    of: #"^[a-z0-9.]+$"#,
                    options: .regularExpression
                  ) != nil,
                  fields[3].count <= 64 else {
                return nil
            }
            return ProbeMetricPayload(
                value: fields[0],
                level: fields[1],
                title: fields[2],
                symbol: fields[3]
            )
        }
        return ProbeMetricPayload(value: fields[0], level: fields[1], title: nil, symbol: nil)
    }

    private static func scalar(_ fields: [String]?, maximumScalars: Int) -> String? {
        guard let fields,
              fields.count == 1,
              isSafeField(fields[0], maximumScalars: maximumScalars) else {
            return nil
        }
        return fields[0]
    }

    private static func isSafeField(_ value: String, maximumScalars: Int) -> Bool {
        guard !value.isEmpty, value.unicodeScalars.count <= maximumScalars else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.newlines.contains(scalar)
                && !forbiddenDirectionalScalars.contains(scalar.value)
        }
    }
}

enum RefreshLifecyclePolicy {
    static func shouldSchedulePathRefresh(
        isSatisfied: Bool,
        isInitialPath: Bool,
        isApplicationActive: Bool
    ) -> Bool {
        guard isApplicationActive else { return false }
        return !isSatisfied || !isInitialPath
    }

    static func shouldRefreshOnActivation(
        secondsSinceLastRequest: TimeInterval,
        hasPendingInvalidation: Bool
    ) -> Bool {
        hasPendingInvalidation || secondsSinceLastRequest >= 2
    }
}

enum UpdateCheckSchedule {
    static let interval: TimeInterval = 24 * 60 * 60

    static func shouldCheck(lastSuccessfulCheck: Date, now: Date = Date()) -> Bool {
        let elapsed = now.timeIntervalSince(lastSuccessfulCheck)
        return elapsed < 0 || elapsed >= interval
    }
}
