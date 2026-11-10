// What the byte machine of the shell prompt tracker has to keep. The machine
// in prompt_tracker.qnt is generated from `prompt_advance`
// (src/vt/prompt.kizu); these properties are written by hand and
// scripts/spec-quint checks them.
module prompt_properties {
  import prompt_tracker.* from "./prompt_tracker"

  pure val collecting = Set(Payload, PayloadEscape)

  // A payload ends only at its terminator: BEL, or ESC then a backslash.
  val finishedOnlyAtTerminator =
    moved and outcome == Finished implies
      ((previous == Payload and event == Bell) or (previous == PayloadEscape and event == Backslash))

  // After a payload ends the machine is outside any sequence.
  val finishedReturnsToGround = moved and outcome == Finished implies state == Ground

  // A payload is left only by ending it, so what was collected is always read.
  val leavesOnlyByFinishing =
    moved and collecting.contains(previous) and not(collecting.contains(state)) implies
      outcome == Finished

  // A payload opens only with ESC then a bracket, and opens empty.
  val opensOnlyAfterEscape =
    moved and collecting.contains(state) and not(collecting.contains(previous)) implies
      (previous == Escape and event == Bracket and outcome == Opened)

  // Bytes join a payload only while one is open.
  val keptOnlyWhileCollecting =
    moved and Set(Kept, Held, KeptHeld, KeptBoth).contains(outcome) implies
      collecting.contains(previous)

  // An ESC is held exactly while the machine waits for the byte after it.
  val heldExactlyInPayloadEscape =
    moved implies ((state == PayloadEscape) iff Set(Held, KeptHeld).contains(outcome))

  // A run that never ends a payload says nothing about the properties above.
  val reachedFinished = moved and outcome == Finished
}

// The payload as `feed` keeps it, told from the outcomes alone: whether one
// is open, and whether an ESC is held back from it. The states must agree
// with it at every step of every run.
module prompt_payload {
  import prompt_tracker.* from "./prompt_tracker"

  var open: bool
  var held: bool

  pure def opens(o: Outcome, was: bool): bool =
    if (o == Opened) true else if (o == Finished) false else was

  pure def holds(o: Outcome): bool = Set(Held, KeptHeld).contains(o)

  action begin = all {
    init,
    open' = false,
    held' = false,
  }

  action advance = {
    nondet e = oneOf(events)
    val answer = moves.get((state, e))
    all {
      take(e),
      open' = opens(answer._2, open),
      held' = holds(answer._2),
    }
  }

  val stateTellsThePayload =
    (open iff Set(Payload, PayloadEscape).contains(state)) and (held iff state == PayloadEscape)

  // Nothing is added to, held back from or read out of a payload that is not open.
  val effectsNeedAnOpenPayload =
    moved and Set(Kept, Held, KeptHeld, KeptBoth, Finished).contains(outcome) implies
      Set(Payload, PayloadEscape).contains(previous)

  val reachedFinished = moved and outcome == Finished
}
