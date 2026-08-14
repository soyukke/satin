import AppKit
import Foundation

final class NativePaneStore {
    let agentTitleTracker = NativeAgentTitleTracker()
    var runtimes: [Int: NativePane] = [:]
    var scrollRemainders: [Int: CGFloat] = [:]
    var workingDirectories: [Int: String] = [:]
    var modes: [Int: NativePaneMode] = [:]
    var titles: [Int: String] = [:]
    var visibleFrames: [Int: NSRect] = [:]
    var wakeupSources: [Int: DispatchSourceRead] = [:]
    var suspendedWakeupSources: [Int: DispatchSourceRead] = [:]
    var suspendedSessions: [Int: NativeSuspendedTerminalSession] = [:]
    var artifactSelectors: [Int: String] = [:]

    func discardMetadata(for paneId: Int) {
        agentTitleTracker.remove(paneId: paneId)
        scrollRemainders.removeValue(forKey: paneId)
        workingDirectories.removeValue(forKey: paneId)
        modes.removeValue(forKey: paneId)
        titles.removeValue(forKey: paneId)
    }
}
