import Foundation

struct NativePaneControlStatus {
    let status: String
    let summary: String
    let revision: UInt64
    let updatedAt: Date

    var json: [String: Any] {
        [
            "status": status,
            "summary": summary,
            "revision": revision,
            "updatedAt": updatedAt.timeIntervalSince1970,
        ]
    }
}

private struct NativeStatusWaiter {
    let token: UUID
    let reply: NativeControlReply
    let timeout: DispatchWorkItem
}

final class NativePaneStatusStore {
    private var statuses: [Int: NativePaneControlStatus] = [:]
    private var waiters: [Int: [NativeStatusWaiter]] = [:]
    private var nextRevision: UInt64 = 1

    func status(for paneId: Int) -> NativePaneControlStatus? {
        statuses[paneId]
    }

    @discardableResult
    func update(paneId: Int, status: String, summary: String) -> NativePaneControlStatus {
        let value = NativePaneControlStatus(
            status: status,
            summary: summary,
            revision: nextRevision,
            updatedAt: Date()
        )
        if nextRevision < UInt64.max {
            nextRevision += 1
        }
        statuses[paneId] = value
        resolveWaiters(for: paneId, with: .success(value.json))
        return value
    }

    func wait(
        paneId: Int,
        timeoutMilliseconds: UInt64,
        reply: @escaping NativeControlReply
    ) {
        if let current = statuses[paneId],
            ["done", "failed", "blocked"].contains(current.status)
        {
            reply(.success(current.json))
            return
        }

        let token = UUID()
        let timeout = DispatchWorkItem { [weak self] in
            self?.timeout(paneId: paneId, token: token)
        }
        waiters[paneId, default: []].append(
            NativeStatusWaiter(token: token, reply: reply, timeout: timeout)
        )
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Int(timeoutMilliseconds)),
            execute: timeout
        )
    }

    func remove(paneId: Int) {
        statuses.removeValue(forKey: paneId)
        resolveWaiters(
            for: paneId,
            with: .failure(
                NativeControlFailure(code: "pane_closed", message: "The pane was closed.")
            )
        )
    }

    private func timeout(paneId: Int, token: UUID) {
        guard var paneWaiters = waiters[paneId],
            let index = paneWaiters.firstIndex(where: { $0.token == token })
        else {
            return
        }
        let waiter = paneWaiters.remove(at: index)
        waiters[paneId] = paneWaiters.isEmpty ? nil : paneWaiters
        waiter.reply(
            .failure(
                NativeControlFailure(
                    code: "wait_timeout",
                    message: "No pane status update was received."
                )
            )
        )
    }

    private func resolveWaiters(
        for paneId: Int,
        with result: Result<Any, NativeControlFailure>
    ) {
        let paneWaiters = waiters.removeValue(forKey: paneId) ?? []
        for waiter in paneWaiters {
            waiter.timeout.cancel()
            waiter.reply(result)
        }
    }
}
