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
                let deadline = timeoutSeconds.map { Date().addingTimeInterval($0) }
                while process.isRunning {
                    if Task.isCancelled {
                        cancelled = true
                        break
                    }
                    if let deadline, Date() >= deadline {
                        timedOut = true
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if process.isRunning && (timedOut || cancelled) {
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
                    while process.isRunning && Date() < terminationDeadline {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    if process.isRunning {
                        _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                }
                process.waitUntilExit()
                let data = await reader.value
                let output = String(decoding: data, as: UTF8.self)
                if timedOut {
                    return (timeoutStatus, output.isEmpty ? "后端检测超时" : output)
                }
                if cancelled {
                    return (cancelledStatus, output)
                }
                return (process.terminationStatus, output)
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
