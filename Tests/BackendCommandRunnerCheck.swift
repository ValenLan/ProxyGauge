import Foundation

@main
struct BackendCommandRunnerCheck {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw CheckError.failed("A backend fixture path is required.")
        }
        let fixture = CommandLine.arguments[1]

        let normalStart = Date()
        let normal = await BackendCommandRunner.run(
            scriptPath: fixture,
            action: "normal",
            environment: ProcessInfo.processInfo.environment,
            timeoutSeconds: 2
        )
        try require(normal.status == 0, "A normal backend command must retain its status.")
        try require(normal.output == "normal-output\n", "Job-control messages must not pollute backend output.")
        try require(Date().timeIntervalSince(normalStart) < 1, "A completed command must not wait for timeout cleanup.")

        let preCancelled = await Task {
            withUnsafeCurrentTask { task in task?.cancel() }
            return await BackendCommandRunner.run(
                scriptPath: fixture,
                action: "normal",
                environment: ProcessInfo.processInfo.environment,
                timeoutSeconds: 2
            )
        }.value
        try require(
            preCancelled.status == BackendCommandRunner.cancelledStatus && preCancelled.output.isEmpty,
            "A task cancelled before invocation must not spawn the backend command."
        )

        let start = Date()
        let timeout = await BackendCommandRunner.run(
            scriptPath: fixture,
            action: "hang",
            environment: ProcessInfo.processInfo.environment,
            timeoutSeconds: 0.25
        )
        let elapsed = Date().timeIntervalSince(start)
        try require(timeout.status == BackendCommandRunner.timeoutStatus, "A hung process tree must return status 124.")
        try require(elapsed < 3, "A descendant holding stdout must not keep the runner blocked.")

        let partialTimeout = await BackendCommandRunner.run(
            scriptPath: fixture,
            action: "partial-hang",
            environment: ProcessInfo.processInfo.environment,
            timeoutSeconds: 0.25
        )
        try require(
            partialTimeout.status == BackendCommandRunner.timeoutStatus &&
                partialTimeout.output.contains("✅ 已完成项目"),
            "A timed-out health command must retain partial output while reporting status 124."
        )

        for _ in 0..<5 {
            let cancellationStart = Date()
            let cancellable = Task {
                await BackendCommandRunner.run(
                    scriptPath: fixture,
                    action: "hang",
                    environment: ProcessInfo.processInfo.environment,
                    timeoutSeconds: 10
                )
            }
            cancellable.cancel()
            let cancelled = await cancellable.value
            try require(cancelled.status == BackendCommandRunner.cancelledStatus, "Immediate cancellation must stop the process tree.")
            try require(Date().timeIntervalSince(cancellationStart) < 3, "Cancellation must not wait for the old timeout.")
        }

        let shutdownStart = Date()
        let runningDuringShutdown = Task {
            await BackendCommandRunner.run(
                scriptPath: fixture,
                action: "hang",
                environment: ProcessInfo.processInfo.environment,
                timeoutSeconds: 10
            )
        }
        while BackendCommandRunner.activeProcessCountForTesting == 0,
              Date().timeIntervalSince(shutdownStart) < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(
            BackendCommandRunner.activeProcessCountForTesting == 1,
            "The running backend must be registered for application shutdown."
        )
        BackendCommandRunner.cancelAll()
        let shutdownResult = await runningDuringShutdown.value
        try require(
            shutdownResult.status == BackendCommandRunner.timeoutStatus,
            "Application shutdown must terminate the registered backend process tree."
        )
        try require(
            Date().timeIntervalSince(shutdownStart) < 3,
            "Application shutdown must not leave an orphaned backend process."
        )
        try require(
            BackendCommandRunner.activeProcessCountForTesting == 0,
            "A finished backend must leave the shutdown registry."
        )

        print("ProxyGauge backend process-tree timeout tests passed.")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw CheckError.failed(message)
        }
    }

    private enum CheckError: Error {
        case failed(String)
    }
}
