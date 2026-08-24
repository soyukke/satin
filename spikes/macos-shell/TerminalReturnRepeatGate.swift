import AppKit

final class TerminalReturnRepeatGate {
    private var awaitingPrompt = false
    private var promptGeneration: UInt64 = 0
    private var pendingEvent: NSEvent?

    var isAwaitingPrompt: Bool {
        awaitingPrompt
    }

    func handle(
        _ event: NSEvent,
        released: Bool,
        isReturn: Bool,
        managesRepeat: Bool,
        currentPromptGeneration: UInt64,
        forward: (NSEvent, Bool) -> Bool
    ) -> Bool {
        guard isReturn else {
            return forward(event, released)
        }
        if released {
            reset(promptGeneration: currentPromptGeneration)
            return forward(event, true)
        }
        if managesRepeat {
            if event.isARepeat, awaitingPrompt {
                pendingEvent = event
                return true
            }
            awaitingPrompt = true
            promptGeneration = currentPromptGeneration
        }
        let sent = forward(event, false)
        if !sent, managesRepeat {
            reset(promptGeneration: currentPromptGeneration)
        }
        return sent
    }

    func forwardPendingIfReady(
        managesRepeat: Bool,
        currentPromptGeneration: UInt64,
        fallbackPromptReady: Bool,
        forward: (NSEvent) -> Void
    ) {
        guard awaitingPrompt, managesRepeat else {
            return
        }
        let promptAdvanced = currentPromptGeneration != promptGeneration
        guard promptAdvanced || fallbackPromptReady else {
            return
        }
        awaitingPrompt = false
        guard let event = pendingEvent else {
            return
        }
        pendingEvent = nil
        forward(event)
    }

    func reset(promptGeneration: UInt64) {
        awaitingPrompt = false
        self.promptGeneration = promptGeneration
        pendingEvent = nil
    }
}
