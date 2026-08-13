import Foundation

extension RustTerminalPane {
    func selectionEvent(_ event: NativeTerminalSelectionEvent) -> Int {
        let action: UInt32
        let input: NativeMouseInput?
        let rectangular: Bool
        switch event {
        case .press(let value):
            (action, input, rectangular) = (0, value, false)
        case .drag(let value, let rectangle):
            (action, input, rectangular) = (1, value, rectangle)
        case .release(let value):
            (action, input, rectangular) = (2, value, false)
        case .autoscroll(let value, let rectangle):
            (action, input, rectangular) = (3, value, rectangle)
        case .cancel:
            (action, input, rectangular) = (4, nil, false)
        }
        return satinRuntimeSelectionEvent(
            handle,
            action,
            UInt32(clamping: input?.row ?? 0),
            UInt16(clamping: input?.col ?? 0),
            input?.surfaceX ?? 0,
            input?.surfaceY ?? 0,
            input?.cellWidth ?? 1,
            rectangular ? 1 : 0
        )
    }
}
