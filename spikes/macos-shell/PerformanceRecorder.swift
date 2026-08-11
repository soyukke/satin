import Foundation
import Metal
import QuartzCore

private struct NativePerformanceConfiguration {
    let resultPath: String
    let startPath: String
    let duration: TimeInterval

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> NativePerformanceConfiguration? {
        guard let resultPath = environment["SATIN_PERF_RESULT"], !resultPath.isEmpty,
            let startPath = environment["SATIN_PERF_START"], !startPath.isEmpty
        else {
            return nil
        }
        let requestedDuration =
            environment["SATIN_PERF_DURATION_SECONDS"]
            .flatMap(TimeInterval.init) ?? 8
        return NativePerformanceConfiguration(
            resultPath: resultPath,
            startPath: startPath,
            duration: max(1, requestedDuration)
        )
    }
}

struct NativePerformanceFrameToken: Sendable {
    let startedAt: CFTimeInterval
    let targetTimestamp: CFTimeInterval?
    let targetPresentationTimestamp: CFTimeInterval?
    let expectedInterval: CFTimeInterval?
}

/// Opt-in frame telemetry for local performance comparisons.
///
/// Production rendering pays one optional check per measured boundary. Samples
/// are retained only when SATIN_PERF_RESULT and SATIN_PERF_START are set, and
/// the report is written as an artifact instead of adding runtime log noise.
final class NativePerformanceRecorder: @unchecked Sendable {
    static let shared = NativePerformanceRecorder(
        configuration: NativePerformanceConfiguration.fromEnvironment()
    )

    private let configuration: NativePerformanceConfiguration?
    private let lock = NSLock()
    private var startedAt: CFTimeInterval?
    private var finished = false
    private var finishScheduled = false

    private var rendererCPU: [Double] = []
    private var frameCPU: [Double] = []
    private var targetTimestamps: [Double] = []
    private var targetPresentationTimestamps: [Double] = []
    private var expectedIntervals: [Double] = []
    private var scheduledLatency: [Double] = []
    private var completedLatency: [Double] = []
    private var sentinelGPU: [Double] = []
    private var presentedTimestamps: [Double] = []
    private var presentationLateness: [Double] = []
    private var mainDrainCPU: [Double] = []
    private var nvimDrainCPU: [Double] = []
    private var frameRequests = 0
    private var presentedCallbacks = 0
    private var zeroPresentedTimestamps = 0
    private var changedNvimDrains = 0

    private init(configuration: NativePerformanceConfiguration?) {
        self.configuration = configuration
    }

    var isEnabled: Bool {
        configuration != nil
    }

    func beginFrame(
        at now: CFTimeInterval,
        targetTimestamp: CFTimeInterval?,
        targetPresentationTimestamp: CFTimeInterval?,
        expectedInterval: CFTimeInterval?
    ) -> NativePerformanceFrameToken? {
        guard activateIfReady(at: now), isInsideWindow(now) else {
            return nil
        }
        return NativePerformanceFrameToken(
            startedAt: now,
            targetTimestamp: targetTimestamp,
            targetPresentationTimestamp: targetPresentationTimestamp,
            expectedInterval: expectedInterval
        )
    }

    func recordFrameSubmission(
        _ token: NativePerformanceFrameToken?,
        rendererFinishedAt: CFTimeInterval,
        committedAt: CFTimeInterval
    ) {
        guard let token else {
            return
        }
        lock.withLock {
            guard !finished else {
                return
            }
            rendererCPU.append(milliseconds(rendererFinishedAt - token.startedAt))
            frameCPU.append(milliseconds(committedAt - token.startedAt))
            if let timestamp = token.targetTimestamp {
                targetTimestamps.append(timestamp)
            }
            if let timestamp = token.targetPresentationTimestamp {
                targetPresentationTimestamps.append(timestamp)
            }
            if let interval = token.expectedInterval, interval > 0 {
                expectedIntervals.append(interval)
            }
        }
    }

    func observeCommandBuffer(
        _ commandBuffer: MTLCommandBuffer,
        drawable: CAMetalDrawable,
        token: NativePerformanceFrameToken?,
        committedAt: CFTimeInterval
    ) {
        guard let token else {
            return
        }
        commandBuffer.addScheduledHandler { [weak self] _ in
            self?.recordScheduledLatency(from: committedAt)
        }
        commandBuffer.addCompletedHandler { [weak self] buffer in
            self?.recordCompletion(buffer, committedAt: committedAt)
        }
        drawable.addPresentedHandler { [weak self] presentedDrawable in
            self?.recordPresentation(
                presentedDrawable.presentedTime,
                target: token.targetPresentationTimestamp
            )
        }
    }

    func recordMainDrain(milliseconds: Double) {
        _ = recordDrain(milliseconds, destination: \.mainDrainCPU)
    }

    func recordNvimDrain(milliseconds: Double, changed: Bool) {
        guard recordDrain(milliseconds, destination: \.nvimDrainCPU) else {
            return
        }
        if changed {
            lock.withLock {
                changedNvimDrains += 1
            }
        }
    }

    func recordFrameRequest() {
        guard configuration != nil else {
            return
        }
        let now = CACurrentMediaTime()
        guard activateIfReady(at: now), isInsideWindow(now) else {
            return
        }
        lock.withLock {
            frameRequests += 1
        }
    }

    private func recordDrain(
        _ milliseconds: Double,
        destination: ReferenceWritableKeyPath<NativePerformanceRecorder, [Double]>
    ) -> Bool {
        let now = CACurrentMediaTime()
        guard activateIfReady(at: now), isInsideWindow(now) else {
            return false
        }
        return lock.withLock {
            guard !finished else {
                return false
            }
            self[keyPath: destination].append(milliseconds)
            return true
        }
    }

    private func activateIfReady(at now: CFTimeInterval) -> Bool {
        guard let configuration else {
            return false
        }
        var shouldScheduleFinish = false
        let active = lock.withLock {
            guard !finished else {
                return false
            }
            if startedAt == nil,
                FileManager.default.fileExists(atPath: configuration.startPath)
            {
                startedAt = now
            }
            if startedAt != nil, !finishScheduled {
                finishScheduled = true
                shouldScheduleFinish = true
            }
            return startedAt != nil
        }
        if shouldScheduleFinish {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + configuration.duration + 0.25
            ) { [weak self] in
                self?.finish()
            }
        }
        return active
    }

    private func isInsideWindow(_ now: CFTimeInterval) -> Bool {
        lock.withLock {
            guard let configuration, let startedAt, !finished else {
                return false
            }
            return now - startedAt <= configuration.duration
        }
    }

    private func recordScheduledLatency(from committedAt: CFTimeInterval) {
        let latency = milliseconds(CACurrentMediaTime() - committedAt)
        lock.withLock {
            guard !finished else {
                return
            }
            scheduledLatency.append(latency)
        }
    }

    private func recordCompletion(
        _ commandBuffer: MTLCommandBuffer,
        committedAt: CFTimeInterval
    ) {
        let latency = milliseconds(CACurrentMediaTime() - committedAt)
        let gpuDuration =
            commandBuffer.gpuEndTime > commandBuffer.gpuStartTime
            ? milliseconds(commandBuffer.gpuEndTime - commandBuffer.gpuStartTime)
            : nil
        lock.withLock {
            guard !finished else {
                return
            }
            completedLatency.append(latency)
            if let gpuDuration {
                sentinelGPU.append(gpuDuration)
            }
        }
    }

    private func recordPresentation(
        _ presentedAt: CFTimeInterval,
        target: CFTimeInterval?
    ) {
        lock.withLock {
            guard !finished else {
                return
            }
            presentedCallbacks += 1
            guard presentedAt > 0 else {
                zeroPresentedTimestamps += 1
                return
            }
            presentedTimestamps.append(presentedAt)
            if let target {
                presentationLateness.append(milliseconds(presentedAt - target))
            }
        }
    }

    private func finish() {
        guard let configuration else {
            return
        }
        let report: [String: Any]? = lock.withLock {
            guard !finished, let startedAt else {
                return nil
            }
            finished = true
            return makeReport(startedAt: startedAt, duration: configuration.duration)
        }
        guard let report,
            let data = try? JSONSerialization.data(
                withJSONObject: report,
                options: [.prettyPrinted, .sortedKeys]
            )
        else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: configuration.resultPath), options: .atomic)
    }

    private func makeReport(
        startedAt: CFTimeInterval,
        duration: TimeInterval
    ) -> [String: Any] {
        let expectedInterval = percentile(expectedIntervals, fraction: 0.5)
        let targetIntervals = intervals(targetPresentationTimestamps)
        let presentedIntervals = intervals(presentedTimestamps)
        return [
            "schema_version": 1,
            "started_at": startedAt,
            "duration_ms": milliseconds(duration),
            "frames": [
                "count": frameCPU.count,
                "request_count": frameRequests,
                "presented_callback_count": presentedCallbacks,
                "zero_presented_timestamp_count": zeroPresentedTimestamps,
                "renderer_cpu_ms": distribution(rendererCPU),
                "submission_cpu_ms": distribution(frameCPU),
                "target_interval_ms": distribution(targetIntervals.map(milliseconds)),
                "presented_interval_ms": distribution(presentedIntervals.map(milliseconds)),
                "presentation_lateness_ms": distribution(presentationLateness),
                "expected_interval_ms": expectedInterval.map(milliseconds) ?? 0,
                "missed_target_intervals": missedIntervals(
                    targetIntervals,
                    expectedInterval: expectedInterval
                ),
                "missed_presented_intervals": missedIntervals(
                    presentedIntervals,
                    expectedInterval: expectedInterval
                ),
            ],
            "gpu_queue": [
                "scheduled_count": scheduledLatency.count,
                "completed_count": completedLatency.count,
                "schedule_latency_ms": distribution(scheduledLatency),
                "completion_latency_ms": distribution(completedLatency),
                "sentinel_gpu_ms": distribution(sentinelGPU),
            ],
            "main_thread": [
                "drain_count": mainDrainCPU.count,
                "drain_cpu_ms": distribution(mainDrainCPU),
                "nvim_drain_count": nvimDrainCPU.count,
                "changed_nvim_drain_count": changedNvimDrains,
                "nvim_drain_cpu_ms": distribution(nvimDrainCPU),
            ],
        ]
    }
}

private func milliseconds(_ seconds: Double) -> Double {
    seconds * 1_000
}

private func intervals(_ timestamps: [Double]) -> [Double] {
    zip(timestamps, timestamps.dropFirst()).compactMap { previous, current in
        let interval = current - previous
        return interval > 0 ? interval : nil
    }
}

private func missedIntervals(
    _ intervals: [Double],
    expectedInterval: Double?
) -> Int {
    guard let expectedInterval, expectedInterval > 0 else {
        return 0
    }
    return intervals.reduce(0) { total, interval in
        total + max(0, Int((interval / expectedInterval).rounded()) - 1)
    }
}

private func distribution(_ values: [Double]) -> [String: Any] {
    guard !values.isEmpty else {
        return [
            "count": 0,
            "mean": 0,
            "p50": 0,
            "p95": 0,
            "p99": 0,
            "max": 0,
        ]
    }
    return [
        "count": values.count,
        "mean": values.reduce(0, +) / Double(values.count),
        "p50": percentile(values, fraction: 0.50) ?? 0,
        "p95": percentile(values, fraction: 0.95) ?? 0,
        "p99": percentile(values, fraction: 0.99) ?? 0,
        "max": values.max() ?? 0,
    ]
}

private func percentile(_ values: [Double], fraction: Double) -> Double? {
    guard !values.isEmpty else {
        return nil
    }
    let sorted = values.sorted()
    let index = Int((Double(sorted.count - 1) * fraction).rounded(.up))
    return sorted[index]
}

extension NSLock {
    fileprivate func withLock<Result>(_ operation: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return operation()
    }
}
