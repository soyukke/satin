#if SATIN_SMOKE_SCENARIOS
    import AppKit

    extension TerminalShellViewController {
        func adaptiveTabWidthResultForSmoke() -> (ready: Bool, summary: String) {
            let narrowTabFrame = tabStripView.convert(tabStripView.bounds, to: nil)
            let narrowWindowFrame = view.convert(view.bounds, to: nil)
            let narrowCapacity = tabStripView.maximumToolbarWidthForSmoke()

            resizeTabStripForSmoke(to: 1_440)
            let wideTabFrame = tabStripView.convert(tabStripView.bounds, to: nil)
            let wideArtifactFrame = artifactButton.convert(artifactButton.bounds, to: nil)
            let wideSessionFrame = sessionControlButton.convert(
                sessionControlButton.bounds,
                to: nil
            )
            let wideWindowFrame = view.convert(view.bounds, to: nil)
            let wideCapacity = tabStripView.maximumToolbarWidthForSmoke()
            let windowWidthGain = wideWindowFrame.width - narrowWindowFrame.width
            let capacityGain = wideCapacity - narrowCapacity

            resizeTabStripForSmoke(to: 1_024)
            let restoredTabFrame = tabStripView.convert(tabStripView.bounds, to: nil)
            let restoredArtifactFrame = artifactButton.convert(artifactButton.bounds, to: nil)
            let restoredSessionFrame = sessionControlButton.convert(
                sessionControlButton.bounds,
                to: nil
            )
            let restoredWindowFrame = view.convert(view.bounds, to: nil)
            let restoredCapacity = tabStripView.maximumToolbarWidthForSmoke()

            let ready =
                windowWidthGain >= 300
                && abs(capacityGain - windowWidthGain) <= 2
                && wideTabFrame.width >= narrowTabFrame.width + 100
                && wideTabFrame.minX >= wideWindowFrame.minX - 0.5
                && wideTabFrame.maxX < wideArtifactFrame.minX
                && wideSessionFrame.maxX >= wideWindowFrame.maxX - 32
                && abs(restoredCapacity - narrowCapacity) <= 1
                && abs(restoredTabFrame.width - narrowTabFrame.width) <= 1
                && restoredTabFrame.maxX < restoredArtifactFrame.minX
                && restoredSessionFrame.maxX >= restoredWindowFrame.maxX - 32
            let summary =
                "many-tab-detail=\(Int(narrowTabFrame.minX))/"
                + "\(Int(narrowTabFrame.width))/\(Int(narrowCapacity)) "
                + "adaptive-width=\(ready ? "ready" : "invalid") "
                + "wide-tab-detail=\(Int(wideTabFrame.minX))/"
                + "\(Int(wideTabFrame.width))/\(Int(wideTabFrame.maxX))/"
                + "\(Int(wideArtifactFrame.minX))/\(Int(wideCapacity))/"
                + "\(Int(wideWindowFrame.width)) "
                + "restored-tab-detail=\(Int(restoredTabFrame.width))/"
                + "\(Int(restoredArtifactFrame.minX))/\(Int(restoredCapacity))/"
                + "\(Int(restoredWindowFrame.width))"
            return (ready, summary)
        }

        private func resizeTabStripForSmoke(to width: CGFloat) {
            guard let window = view.window, let contentView = window.contentView else {
                return
            }
            window.setContentSize(NSSize(width: width, height: contentView.bounds.height))
            view.layoutSubtreeIfNeeded()
            updateTabStripToolbarWidth()
            contentView.superview?.layoutSubtreeIfNeeded()
            tabStripView.layoutSubtreeIfNeeded()
        }
    }
#endif
