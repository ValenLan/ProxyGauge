import Foundation
import SwiftUI

@main
struct GuardPresentationCheck {
    @MainActor
    static func main() {
        let levels: [HealthLevel] = [.ok, .warning, .error, .idle]
        let values = [
            "已开启", "监测中", "已关闭", "未配置", "恢复中", "需要修复",
            "检查中", "待确认", "状态不可用", "unexpected", "", "已开启 "
        ]
        var stateCases = 0
        var actionCases = 0
        for value in values {
            for level in levels {
                let expected = expectation(value: value, level: level)
                let model = ProxyModel(value: value, level: level)
                let dashboard = GuardDashboardBindingProbe(model: model)
                require(model.guardPresentation.state == expected.state,
                        "Wrong explicit state for \(value)/\(level.rawValue).")
                require(model.guardPresentation.level == expected.presentationLevel,
                        "Wrong status tone for \(value)/\(level.rawValue): normal is green, recovering is orange, and fault is red.")
                let expectedColor: Color = switch expected.presentationLevel {
                case .ok: .green
                case .warning: .orange
                case .error: .red
                case .idle: .gray
                }
                require(model.guardPresentation.level.color == expectedColor,
                        "The actual Dashboard color must follow the presentation tone for \(value)/\(level.rawValue).")
                require(dashboard.showsToggle == expected.visible,
                        "Actual Dashboard branch must hide the boolean control for \(value)/\(level.rawValue).")
                require(dashboard.guardToggleBinding.wrappedValue == expected.isOn,
                        "Actual Dashboard getter must use the explicit armed state.")
                require(!model.guardPresentation.help.isEmpty,
                        "Every state needs a precise explanation.")
                stateCases += 1

                for busy in [false, true] {
                    for requestedOn in [false, true] {
                        model.isBusy = busy
                        model.enableCalls = 0
                        model.showDisableConfirmation = false
                        dashboard.guardToggleBinding.wrappedValue = requestedOn
                        let expectedEnable = expected.visible && !busy && !expected.isOn && requestedOn
                        let expectedDisable = expected.visible && !busy && expected.isOn && !requestedOn
                        require(model.enableCalls == (expectedEnable ? 1 : 0),
                                "Actual Dashboard setter dispatched enable for \(value)/\(level.rawValue), busy=\(busy), request=\(requestedOn).")
                        require(model.showDisableConfirmation == expectedDisable,
                                "Actual Dashboard setter dispatched disable confirmation for \(value)/\(level.rawValue), busy=\(busy), request=\(requestedOn).")
                        actionCases += 1
                    }
                }
            }
        }

        let monitoring = GuardPresentation.make(value: "监测中", level: .ok)
        require(monitoring.title == "监测中" && monitoring.toggleIsOn && monitoring.level == .ok,
                "Normal NE monitoring must be green while retaining its distinct title and armed state.")
        require(monitoring.help.contains("监测模式") && monitoring.help.contains("未验证"),
                "Monitoring help must not imply verified fallback blocking.")
        let enabled = GuardPresentation.make(value: "已开启", level: .ok)
        require(enabled.help.contains("未读取内核规则") && enabled.help.contains("root"),
                "Enabled record must not claim kernel/traffic verification or hide root scope.")
        require(GuardPresentation.make(value: "未配置", level: .idle).title == "未开启",
                "Unconfigured is a confirmed initial off state, not an unknown failure.")
        require(GuardPresentation.make(value: "状态不可用", level: .error).title == "状态不可用",
                "A failed probe must remain visibly unavailable.")

        // A binding kept by SwiftUI must consult the latest state at action time.
        let changed = ProxyModel(value: "已开启", level: .ok)
        let dashboard = GuardDashboardBindingProbe(model: changed)
        let oldBinding = dashboard.guardToggleBinding
        changed.killSwitch.value = "状态不可用"
        changed.killSwitch.level = .error
        oldBinding.wrappedValue = false
        oldBinding.wrappedValue = true
        require(!dashboard.showsToggle && changed.enableCalls == 0 && !changed.showDisableConfirmation,
                "A previously created binding must not act after state becomes unknown.")
        changed.killSwitch.value = "已关闭"
        changed.killSwitch.level = .warning
        require(!oldBinding.wrappedValue && dashboard.showsToggle,
                "The real binding must follow a freshly confirmed off state.")
        changed.isBusy = true
        oldBinding.wrappedValue = true
        require(changed.enableCalls == 0, "Busy state must suppress action in the setter too.")
        changed.isBusy = false
        oldBinding.wrappedValue = true
        require(changed.enableCalls == 1, "A confirmed off state must still enable normally.")

        print("Guard presentation: \(stateCases) state/color cases, \(actionCases) actual Dashboard binding actions, monitoring/help and dynamic-state checks passed without GUI or Guard operations.")
    }

    private static func expectation(value: String, level: HealthLevel) ->
        (state: GuardPresentation.State, visible: Bool, isOn: Bool, presentationLevel: HealthLevel) {
        switch value {
        case "已开启" where level == .ok: return (.enabled, true, true, .ok)
        case "监测中" where level == .ok: return (.monitoring, true, true, .ok)
        case "已关闭" where level == .warning: return (.disabled, true, false, .warning)
        case "未配置" where level == .idle: return (.unconfigured, true, false, .idle)
        case "恢复中": return (.recovering, false, false, .warning)
        case "需要修复": return (.fault, false, false, .error)
        case "检查中": return (.checking, false, false, .idle)
        case "状态不可用": return (.unknown, false, false, .error)
        default: return (.unknown, false, false, .idle)
        }
    }

    private static func require(_ condition: Bool, _ message: String) {
        guard condition else {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(1)
        }
    }
}
