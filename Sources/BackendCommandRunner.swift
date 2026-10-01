import Darwin
import Foundation

enum BackendCommandRunner {
    static let timeoutStatus: Int32 = 124
    static let cancelledStatus: Int32 = 130

    private static let processGroupWrapper = #"""
    exec 3>&2
    exec 2>/dev/null
    child=""
    terminate_requested=0

    stop_group() {
      trap - TERM INT
      [ -n "$child" ] || return
      if kill -TERM -- -"$child" 2>/dev/null; then
        /bin/sleep 0.2
        kill -KILL -- -"$child" 2>/dev/null || true
      fi
      wait "$child" 2>/dev/null || true
    }

    timed_out() {
      terminate_requested=1
      [ -n "$child" ] || return
      stop_group
      exit 124
    }

    trap timed_out TERM INT
    set -m
    /bin/bash "$1" "$2" "${@:3}" 2>&3 3>&- &
    child=$!
    exec 3>&-
    if [ "$terminate_requested" = 1 ]; then
      stop_group
      exit 124
    fi
    wait "$child"
    status=$?
    trap - TERM INT
    stop_group
    exit "$status"
    """#

    private static let processRegistry = BackendProcessRegistry()

    // Foundation can lose track of a terminated child: the process is already
    // reaped, yet isRunning never clears and every waitUntilExit() spins its
    // runloop forever (observed repeatedly on macOS 27, including from inside
    // a bounded reap fallback). Nothing in NSTask's wait machinery is reliable
    // here, so the whole child lifecycle is driven from the kernel instead:
    // waitpid(WNOHANG) is the only liveness and exit-status source, and a
    // probe that reaps the child itself keeps no zombies behind.
    private enum KernelChildState {
        case running
        case exited(Int32)
        case reaped
    }

    private static func probeChild(_ pid: pid_t) -> KernelChildState {
        while true {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                return .exited(decodeWaitStatus(status))
            }
            if result == 0 {
                return .running
            }
            if errno == EINTR {
                continue
            }
            if errno == ECHILD {
                return .reaped
            }
            return .running
        }
    }

    // Resolve the exit status without ever consulting NSTask's wait machinery.
    // A status already decoded by an earlier probe is authoritative. When
    // NSTask's watcher won the reap race, terminationStatus is read only once
    // the task no longer claims to run (the accessor raises otherwise); if
    // that state never comes, return a bounded synthetic failure instead of
    // hanging. waitUntilExit() is deliberately never called.
    private static func finalExitStatus(
        of process: Process,
        kernelExitStatus: Int32?,
        statusIsDiscarded: Bool
    ) async -> Int32 {
        if let kernelExitStatus {
            return kernelExitStatus
        }
        let pid = process.processIdentifier
        let budgetDeadline = Date().addingTimeInterval(30)
        var graceDeadline: Date?
        while true {
            switch probeChild(pid) {
            case .exited(let status):
                return status
            case .reaped:
                if !process.isRunning {
                    return process.terminationStatus
                }
                if graceDeadline == nil {
                    graceDeadline = Date().addingTimeInterval(1)
                }
                if let graceDeadline, Date() >= graceDeadline {
                    return statusIsDiscarded ? 0 : 1
                }
            case .running:
                if Date() >= budgetDeadline {
                    return statusIsDiscarded ? 0 : 1
                }
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func decodeWaitStatus(_ status: Int32) -> Int32 {
        let lowBits = status & 0x7f
        if lowBits == 0 {
            return (status >> 8) & 0xff
        }
        if lowBits != 0x7f {
            return 128 + lowBits
        }
        return status
    }

    static func cancelAll() {
        processRegistry.cancelAll()
    }

    static var activeProcessCountForTesting: Int {
        processRegistry.count
    }

    static func run(
        scriptPath: String,
        action: String,
        arguments: [String] = [],
        environment: [String: String],
        timeoutSeconds: TimeInterval?
    ) async -> (status: Int32, output: String) {
        guard !Task.isCancelled else {
            return (cancelledStatus, "")
        }
        let worker = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else {
                return (cancelledStatus, "")
            }
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [
                "-c",
                processGroupWrapper,
                "proxygauge-command",
                scriptPath,
                action
            ] + arguments
            process.standardOutput = pipe
            process.standardError = pipe
            process.environment = environment

            do {
                try Task.checkCancellation()
                try process.run()
                processRegistry.register(process)
                defer { processRegistry.unregister(process) }
                let reader = Task.detached(priority: .utility) {
                    pipe.fileHandleForReading.readDataToEndOfFile()
                }
                var timedOut = false
                var cancelled = false
                var kernelExitStatus: Int32?
                var childGone = false
                let deadline = timeoutSeconds.map { Date().addingTimeInterval($0) }
                while !childGone {
                    if Task.isCancelled {
                        cancelled = true
                        break
                    }
                    if let deadline, Date() >= deadline {
                        timedOut = true
                        break
                    }
                    switch probeChild(process.processIdentifier) {
                    case .running:
                        try? await Task.sleep(for: .milliseconds(50))
                    case .exited(let status):
                        kernelExitStatus = status
                        childGone = true
                    case .reaped:
                        childGone = true
                    }
                }
                if !childGone && (timedOut || cancelled) {
                    if cancelled {
                        // Cancellation may arrive immediately after posix_spawn,
                        // before bash has installed its TERM trap. Give the tiny
                        // wrapper preamble a bounded startup window.
                        _ = Darwin.usleep(50_000)
                    }
                    // The wrapper owns a separate job-control process group for
                    // the backend. Its TERM trap closes the whole tree, including
                    // descendants that inherited this output pipe.
                    process.terminate()
                    let terminationDeadline = Date().addingTimeInterval(1)
                    while !childGone && Date() < terminationDeadline {
                        switch probeChild(process.processIdentifier) {
                        case .running:
                            try? await Task.sleep(for: .milliseconds(50))
                        case .exited(let status):
                            kernelExitStatus = status
                            childGone = true
                        case .reaped:
                            childGone = true
                        }
                    }
                    if !childGone {
                        _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                }
                let exitStatus = await finalExitStatus(
                    of: process,
                    kernelExitStatus: kernelExitStatus,
                    statusIsDiscarded: timedOut || cancelled
                )
                let data = await reader.value
                let output = String(decoding: data, as: UTF8.self)
                if timedOut {
                    return (timeoutStatus, output.isEmpty ? "后端检测超时" : output)
                }
                if cancelled {
                    return (cancelledStatus, output)
                }
                return (exitStatus, output)
            } catch is CancellationError {
                return (cancelledStatus, "")
            } catch {
                return (1, error.localizedDescription)
            }
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

private final class BackendProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return processes.count
    }

    func register(_ process: Process) {
        lock.lock()
        processes[ObjectIdentifier(process)] = process
        lock.unlock()
    }

    func unregister(_ process: Process) {
        lock.lock()
        processes.removeValue(forKey: ObjectIdentifier(process))
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let running = Array(processes.values)
        lock.unlock()
        for process in running where process.isRunning {
            process.terminate()
        }
    }
}
