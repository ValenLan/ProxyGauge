struct GuardPresentation: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case enabled
        case monitoring
        case disabled
        case unconfigured
        case recovering
        case fault
        case checking
        case unknown
    }

    enum ToggleAction: Equatable, Sendable {
        case none
        case enable
        case confirmDisable
    }

    let state: State
    let title: String
    let level: HealthLevel

    var showsToggle: Bool {
        switch state {
        case .enabled, .monitoring, .disabled, .unconfigured: return true
        case .recovering, .fault, .checking, .unknown: return false
        }
    }

    var toggleIsOn: Bool { state == .enabled || state == .monitoring }

    var statusSymbol: String {
        switch state {
        case .recovering: return "arrow.triangle.2.circlepath"
        case .fault: return "exclamationmark.triangle"
        case .checking: return "clock"
        default: return "questionmark.circle"
        }
    }

    var help: String {
        switch state {
        case .monitoring:
            return "当前为网络扩展监测模式；已记录开启，但此状态未验证客户端关闭后的实际拦截。macOS root 系统进程仍豁免。"
        case .enabled:
            return "保护记录为开启；此状态未读取内核规则或验证实际流量。macOS root 系统进程仍豁免。"
        case .disabled, .unconfigured:
            return "保护记录为关闭；开启时需要管理员授权。"
        case .recovering:
            return "保护正在恢复，当前无法确认开关状态；恢复完成前不可切换。"
        case .fault:
            return "保护记录报告故障，不能据此判断已关闭；状态确认前不可切换。"
        case .checking, .unknown:
            return "尚未确认保护的开关状态；确认前不可切换。"
        }
    }

    func action(requestedOn: Bool, isBusy: Bool) -> ToggleAction {
        guard showsToggle, !isBusy, requestedOn != toggleIsOn else { return .none }
        return requestedOn ? .enable : .confirmDisable
    }

    static func make(value: String, level: HealthLevel) -> GuardPresentation {
        // The health level is not the enabled flag. Only explicit, consistent
        // backend states permit a boolean control; every uncertain state is inert.
        switch (value, level) {
        case ("已开启", .ok):
            return .init(state: .enabled, title: value, level: .ok)
        case ("监测中", .ok):
            return .init(state: .monitoring, title: value, level: .warning)
        case ("已关闭", .warning):
            return .init(state: .disabled, title: value, level: .warning)
        case ("未配置", .idle):
            return .init(state: .unconfigured, title: "未开启", level: .idle)
        case ("恢复中", _):
            return .init(state: .recovering, title: value, level: .warning)
        case ("需要修复", _):
            return .init(state: .fault, title: value, level: .error)
        case ("检查中", _):
            return .init(state: .checking, title: value, level: .idle)
        case ("待确认", _):
            return .init(state: .unknown, title: value, level: .idle)
        case ("状态不可用", _):
            return .init(state: .unknown, title: value, level: .error)
        default:
            return .init(state: .unknown, title: "状态未知", level: .idle)
        }
    }
}

@MainActor
extension ProxyModel {
    var guardPresentation: GuardPresentation {
        GuardPresentation.make(value: killSwitch.value, level: killSwitch.level)
    }
}
