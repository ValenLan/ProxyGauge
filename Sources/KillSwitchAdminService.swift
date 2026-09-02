import Foundation

enum KillSwitchAdminService {
    private static let allowedActions: Set<String> = ["on", "off"]

    static func run(action: String, bundle: Bundle = .main) async -> (status: Int32, output: String) {
        guard allowedActions.contains(action) else {
            return (2, "非法的 Kill Switch 操作。")
        }
        do {
            try BundledResourceIntegrity.validatePrivilegedBundle(bundle)
        } catch {
            return (1, error.localizedDescription)
        }
        guard let helper = bundle.url(forResource: "proxygauge-killswitch", withExtension: nil),
              let template = bundle.url(
                forResource: "proxygauge.conf",
                withExtension: "template"
              ) else {
            return (1, "应用内缺少 Kill Switch 安全组件，请从正式渠道重新安装。")
        }

        do {
            try BundledResourceIntegrity.validateRegularFile(
                at: helper,
                expectedSHA256: BundledResourceIntegrity.killSwitchHelperSHA256
            )
            try BundledResourceIntegrity.validateRegularFile(
                at: template,
                expectedSHA256: BundledResourceIntegrity.killSwitchTemplateSHA256
            )
        } catch {
            return (1, error.localizedDescription)
        }

        return await invokeAdministratorBridge(
            action: action,
            helper: helper,
            template: template,
            osascript: URL(fileURLWithPath: "/usr/bin/osascript")
        )
    }

    static let rootBootstrap = #"""
    set -euo pipefail
    umask 077

    helper_source=${1:-}
    template_source=${2:-}
    helper_expected=${3:-}
    template_expected=${4:-}
    action=${5:-}

    case "$action" in on|off) ;; *) echo "非法的 Kill Switch 操作。" >&2; exit 2 ;; esac
    case "$helper_expected" in ''|*[!0-9a-f]*|?????????????????????????????????????????????????????????????????*) exit 2 ;; esac
    case "$template_expected" in ''|*[!0-9a-f]*|?????????????????????????????????????????????????????????????????*) exit 2 ;; esac
    [ "${#helper_expected}" -eq 64 ] && [ "${#template_expected}" -eq 64 ] || exit 2
    [ -f "$helper_source" ] && [ ! -L "$helper_source" ] || exit 2
    [ -f "$template_source" ] && [ ! -L "$template_source" ] || exit 2

    stage=$(/usr/bin/mktemp -d /private/var/tmp/com.valenlan.proxygauge.XXXXXX)
    cleanup() {
      status=$?
      trap - EXIT HUP INT TERM
      /bin/rm -rf "$stage"
      exit "$status"
    }
    trap cleanup EXIT HUP INT TERM

    staged_helper="$stage/proxygauge-killswitch"
    staged_template="$stage/proxygauge.conf.template"
    /usr/bin/install -o root -g wheel -m 700 "$helper_source" "$staged_helper"
    /usr/bin/install -o root -g wheel -m 600 "$template_source" "$staged_template"
    [ "$(/usr/bin/shasum -a 256 "$staged_helper" | /usr/bin/awk '{print $1}')" = "$helper_expected" ] || {
      echo "Kill Switch helper 完整性校验失败。" >&2
      exit 1
    }
    [ "$(/usr/bin/shasum -a 256 "$staged_template" | /usr/bin/awk '{print $1}')" = "$template_expected" ] || {
      echo "Kill Switch 规则模板完整性校验失败。" >&2
      exit 1
    }

    /bin/launchctl bootout system/com.valenlan.proxygauge.killswitch >/dev/null 2>&1 || true

    helper_dir=/Library/PrivilegedHelperTools/com.valenlan.proxygauge
    fixed_helper="$helper_dir/proxygauge-killswitch"
    fixed_template="$helper_dir/proxygauge.conf.template"
    helper_parent=/Library/PrivilegedHelperTools
    if [ ! -e "$helper_parent" ]; then
      /usr/bin/install -d -o root -g wheel -m 755 "$helper_parent"
    fi
    [ -d "$helper_parent" ] && [ ! -L "$helper_parent" ] || exit 1
    [ "$(/usr/bin/stat -f '%u' "$helper_parent")" = 0 ] || exit 1
    helper_parent_mode=$(/usr/bin/stat -f '%Lp' "$helper_parent")
    [ $((8#$helper_parent_mode & 022)) -eq 0 ] || exit 1
    helper_parent_acl=$(/bin/ls -lde "$helper_parent" | /usr/bin/awk 'NR == 1 { print $1 }')
    case "$helper_parent_acl" in *+*) exit 1 ;; esac
    if [ ! -e "$helper_dir" ]; then
      /usr/bin/install -d -o root -g wheel -m 755 "$helper_dir"
    fi
    [ -d "$helper_dir" ] && [ ! -L "$helper_dir" ] || exit 1
    /bin/chmod -N "$helper_dir"
    /usr/sbin/chown root:wheel "$helper_dir"
    /bin/chmod 700 "$helper_dir"
    [ "$(/usr/bin/stat -f '%u' "$helper_dir")" = 0 ] || exit 1
    helper_dir_mode=$(/usr/bin/stat -f '%Lp' "$helper_dir")
    [ $((8#$helper_dir_mode & 022)) -eq 0 ] || exit 1

    helper_tmp="$helper_dir/.com.valenlan.proxygauge.killswitch.$$"
    template_tmp="$helper_dir/.proxygauge.conf.template.$$"
    /usr/bin/install -o root -g wheel -m 755 "$staged_helper" "$helper_tmp"
    /usr/bin/install -o root -g wheel -m 644 "$staged_template" "$template_tmp"
    [ "$(/usr/bin/shasum -a 256 "$helper_tmp" | /usr/bin/awk '{print $1}')" = "$helper_expected" ] || exit 1
    [ "$(/usr/bin/shasum -a 256 "$template_tmp" | /usr/bin/awk '{print $1}')" = "$template_expected" ] || exit 1
    /bin/mv -f "$helper_tmp" "$fixed_helper"
    /bin/mv -f "$template_tmp" "$fixed_template"
    [ ! -L "$fixed_helper" ] && [ ! -L "$fixed_template" ] || exit 1
    [ "$(/usr/bin/stat -f '%u' "$fixed_helper")" = 0 ] || exit 1
    [ "$(/usr/bin/stat -f '%u' "$fixed_template")" = 0 ] || exit 1
    [ "$(/usr/bin/shasum -a 256 "$fixed_helper" | /usr/bin/awk '{print $1}')" = "$helper_expected" ] || exit 1
    [ "$(/usr/bin/shasum -a 256 "$fixed_template" | /usr/bin/awk '{print $1}')" = "$template_expected" ] || exit 1

    /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
      "$fixed_helper" "$action"
    /bin/rm -f \
      /Library/PrivilegedHelperTools/com.valenlan.proxygauge.killswitch \
      /Library/PrivilegedHelperTools/proxygauge.conf.template
    """#

    static let administratorAppleScript = #"""
    use scripting additions
    on run argv
        if (count of argv) is not 6 then error "Invalid ProxyGauge administrator arguments"
        set bootstrapText to item 1 of argv
        set helperPath to item 2 of argv
        set templatePath to item 3 of argv
        set helperHash to item 4 of argv
        set templateHash to item 5 of argv
        set actionName to item 6 of argv
        if actionName is not in {"on", "off"} then error "Invalid ProxyGauge administrator action"
        set commandText to "/usr/bin/lockf -k -t 120 /private/var/run/com.valenlan.proxygauge.killswitch.lock /bin/bash -p -c " & quoted form of bootstrapText & " proxygauge-killswitch-bootstrap " & quoted form of helperPath & " " & quoted form of templatePath & " " & quoted form of helperHash & " " & quoted form of templateHash & " " & quoted form of actionName
        «event sysoexec» commandText given «class badm»:true
    end run
    """#

    static func invokeAdministratorBridge(
        action: String,
        helper: URL,
        template: URL,
        osascript: URL
    ) async -> (status: Int32, output: String) {
        guard allowedActions.contains(action) else {
            return (2, "非法的 Kill Switch 操作。")
        }
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = osascript
            process.arguments = [
                "-e", administratorAppleScript,
                "--", rootBootstrap,
                helper.path, template.path,
                BundledResourceIntegrity.killSwitchHelperSHA256,
                BundledResourceIntegrity.killSwitchTemplateSHA256,
                action
            ]
            process.environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LC_ALL": "C"
            ]
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                let outputTask = Task.detached(priority: .utility) {
                    pipe.fileHandleForReading.readDataToEndOfFile()
                }
                while process.isRunning && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if process.isRunning {
                    process.terminate()
                }
                process.waitUntilExit()
                let rawOutput = String(decoding: await outputTask.value, as: UTF8.self)
                let output = sanitize(rawOutput, bundlePath: helper.deletingLastPathComponent().path)
                if process.terminationStatus != 0,
                   rawOutput.range(
                    of: #"(^|[^0-9])-128([^0-9]|$)|User canceled|用户已取消"#,
                    options: .regularExpression
                   ) != nil {
                    return (process.terminationStatus, "已取消管理员授权，未修改 Kill Switch。")
                }
                if process.terminationStatus == 0 && output.isEmpty {
                    return (1, "管理员操作没有返回状态。")
                }
                return (process.terminationStatus, output)
            } catch {
                return (1, error.localizedDescription)
            }
        }.value
    }

    private static func sanitize(_ raw: String, bundlePath: String) -> String {
        raw.replacingOccurrences(of: bundlePath, with: "<应用资源>")
            .replacingOccurrences(
                of: #"^.*execution error: "#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #" \([-0-9]+\)\s*$"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
