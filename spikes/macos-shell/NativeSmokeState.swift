#if SATIN_SMOKE_SCENARIOS
    final class NativeSmokeState {
        var nvimFileTreeTarget = "none"
        var nvimFileTreeCloseGrid: Int?
        var nvimFileTreeCloseBoundary: Int?
        var nvimFileTreeCloseBefore = "none"
        var nvimMessageSelection = "overlay=no copied=no"
        var nvimScrollVisualFirstRows: Int?
        var nvimScrollVisualFirstStartCol: Int?
        var nvimScrollVisualFirstFrames = 0
        var artifactPopoverResultPath: String?
        var artifactPopoverOpenPath: String?
        var readmeWorkSwitcherOpened = false
    }
#endif
