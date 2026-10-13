import AppKit

extension TerminalShellViewController {
    func setAttentionHandVisible(_ visible: Bool) {
        attentionHandView.isHidden = !visible
        attentionHandStripConstraint?.constant =
            visible ? -NativeAttentionHandView.stripHeight : 0
        tabControl.showsFuses = visible
        if !visible {
            cancelAttentionSelection()
        }
        refreshAttentionHand()
    }

    func refreshAttentionHand() {
        guard !attentionHandView.isHidden else {
            attentionHandPendingPlay = nil
            return
        }
        let hand = currentAttentionHand()
        var playedPaneId: Int?
        if let pending = attentionHandPendingPlay,
            !hand.cards.contains(where: { $0.paneId == pending })
        {
            playedPaneId = pending
            attentionHandPendingPlay = nil
        }
        var art = [Int: (revision: UInt64, lines: [String])]()
        for card in hand.cards {
            if let known = attentionHandArt[card.paneId], known.revision == card.revision {
                art[card.paneId] = known
            } else {
                let screen = paneStore.runtimes[card.paneId]?.controlScreenText() ?? ""
                art[card.paneId] = (
                    card.revision, nativeHandArtLines(screen, count: 4, width: 30)
                )
            }
        }
        attentionHandArt = art
        attentionHandView.update(
            hand: hand,
            art: art.mapValues(\.lines),
            run: attentionHandRun,
            playedPaneId: playedPaneId
        )
    }

    /// ⌘J: opens the hand with the first card chosen, or moves to the next
    /// card. Letting go of ⌘ plays the chosen card, as ⌘Tab switches apps.
    func advanceAttentionSelection(by step: Int = 1) {
        let cards = playableAttentionCards()
        guard !cards.isEmpty else {
            NSSound.beep()
            return
        }
        let current = cards.firstIndex { $0.paneId == attentionHandView.selectedPaneId }
        let next = current.map { ($0 + step + cards.count) % cards.count } ?? 0
        attentionHandView.openSelection(paneId: cards[next].paneId)
        installAttentionSelectionMonitor()
    }

    func commitAttentionSelection() {
        let card = attentionHandView.selectedCard
        cancelAttentionSelection()
        if let card {
            playAttentionCard(card)
        }
    }

    func cancelAttentionSelection() {
        if let monitor = attentionSelectionMonitor {
            NSEvent.removeMonitor(monitor)
            attentionSelectionMonitor = nil
        }
        attentionHandView.closeSelection()
    }

    private func playableAttentionCards() -> [NativeHandCard] {
        currentAttentionHand().cards.filter { !attentionHandInFlight.contains($0.paneId) }
    }

    private func installAttentionSelectionMonitor() {
        guard attentionSelectionMonitor == nil else {
            return
        }
        attentionSelectionMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            guard let self else {
                return event
            }
            if event.type == .flagsChanged {
                if !event.modifierFlags.contains(.command) {
                    self.commitAttentionSelection()
                }
                return event
            }
            switch event.keyCode {
            case 53:
                self.cancelAttentionSelection()
            case 36, 76:
                self.commitAttentionSelection()
            case 123:
                self.advanceAttentionSelection(by: -1)
            case 124:
                self.advanceAttentionSelection(by: 1)
            case 18...21, 23:
                let index = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4][Int(event.keyCode)] ?? 0
                let cards = self.playableAttentionCards()
                if index < cards.count {
                    self.attentionHandView.openSelection(paneId: cards[index].paneId)
                }
            default:
                return event
            }
            return nil
        }
    }

    /// The target of the menu command: with ⌘ held it chooses, otherwise it
    /// plays the first card at once.
    func jumpWithAttentionHand() {
        let event = NSApp.currentEvent
        let keyDown = event?.type == .keyDown
        if keyDown, event?.isARepeat == true {
            return
        }
        advanceAttentionSelection()
        if !(keyDown && event?.modifierFlags.contains(.command) == true) {
            commitAttentionSelection()
        }
    }

    func attentionSelectionDidChange(_ card: NativeHandCard?) {
        let segment = card.flatMap { card in
            lastSnapshot?.tabs.first { $0.id == card.tabId }?.index
        }
        tabControl.fuseView.setTarget(
            segment: segment, color: card.map { nativeHandColor($0.kind) } ?? .clear)
    }

    func attentionPreviewText(paneId: Int) -> String? {
        guard let screen = paneStore.runtimes[paneId]?.controlScreenText() else {
            return nil
        }
        return nativeHandArtLines(screen, count: 12, width: 64).joined(separator: "\n")
    }

    /// Plays a card: it flies over the panes, and the switch to its pane
    /// happens under it. Focusing the pane takes the card out of the hand.
    func playAttentionCard(_ card: NativeHandCard) {
        guard attentionHandInFlight.insert(card.paneId).inserted else {
            return
        }
        attentionHandView.play(paneId: card.paneId) { [weak self] in
            guard let self else {
                return nil
            }
            self.attentionHandInFlight.remove(card.paneId)
            self.attentionHandPendingPlay = card.paneId
            guard self.focusWorkPane(tabId: card.tabId, paneId: card.paneId) else {
                self.attentionHandPendingPlay = nil
                return nil
            }
            self.attentionHandRun.play(now: Date())
            self.dismissWorkSwitcher()
            self.refreshWorkSwitcherPresentation()
            self.focusTerminal()
            return self.paneStore.visibleFrames[card.paneId].map {
                self.terminalTextView.convert($0, to: self.attentionHandView)
            }
        }
    }

    /// Where a tab sits in the tab strip, as the hand's own x coordinate.
    func attentionTabMidX(tabId: Int) -> CGFloat? {
        guard let index = lastSnapshot?.tabs.first(where: { $0.id == tabId })?.index,
            tabControl.window != nil,
            let frame = tabControl.segmentFrameForNavigation(index)
        else {
            return nil
        }
        return attentionHandView.convert(tabControl.convert(frame, to: nil), from: nil).midX
    }

    private func currentAttentionHand() -> NativeAttentionHand {
        nativeAttentionHand(
            tabs: (lastSnapshot?.tabs ?? []).map(NativeAttentionTab.init),
            status: { [paneStatuses] in paneStatuses.status(for: $0) },
            isUnread: { [workAttentionStore] in workAttentionStore.isUnread(paneId: $0) },
            visiblePaneId: activePaneId
        )
    }
}
