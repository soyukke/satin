// What the mark machine of the shell prompt tracker has to keep. The machine
// in prompt_marks.qnt is generated from `prompt_mark_advance`
// (src/vt/prompt.kizu); these properties are written by hand and
// scripts/spec-quint checks them.
module prompt_marks_properties {
  import prompt_marks.* from "./prompt_marks"

  // The outcomes that count a prompt ready, and those that end a command
  // whose end the shell did not mark.
  pure val counted = Set(ReadyCounted, ReadyCountedDropped)
  pure val dropped = Set(CommandDropped, ReadyCountedDropped)

  // A prompt is counted ready only at an input start.
  val readyCountedOnlyAtInputStart = moved and counted.contains(outcome) implies event == InputStart

  // An input start counts a prompt exactly when none is counted yet.
  val inputStartCountsOnce =
    moved and event == InputStart implies (counted.contains(outcome) iff previous != Ready)

  // Every command start is counted, and nothing else is.
  val startedExactlyAtCommandStart = moved implies ((outcome == CommandStarted) iff (event == CommandStart))

  // A command finishes exactly when its end comes while one is running.
  val finishedExactlyAtAnOpenEnd =
    moved implies ((outcome == CommandFinished) iff (event == CommandEnd and previous == Running))

  // A command is dropped exactly when a prompt comes back while it runs.
  val droppedExactlyAtAPromptWhileRunning =
    moved implies
      (dropped.contains(outcome) iff (previous == Running and Set(PromptStart, InputStart).contains(event)))

  // No command runs once a prompt is back, whether or not its end was marked.
  val promptLeavesNothingRunning =
    moved and Set(PromptStart, InputStart, CommandEnd).contains(event) implies state != Running

  // Only a command start sets a command running.
  val runsOnlyFromACommandStart =
    moved and state == Running implies (event == CommandStart or previous == Running)

  // Once a mark has come, the tracker never forgets that the shell prints them.
  val seenStaysSeen = moved implies state != Unseen

  // A run that never finishes a command says nothing about half of the above.
  val reachedFinished = moved and outcome == CommandFinished
  val reachedDropped = moved and dropped.contains(outcome)
}

// The counts as `finish_payload` keeps them, told from the outcomes alone,
// beside the machine. They must stay sound over every run, whatever marks a
// shell prints and in whatever order.
module prompt_counts {
  import prompt_marks.* from "./prompt_marks"

  var started: int
  var finished: int
  var ready: int
  // The prompts counted ready since the last mark that ends a prompt.
  var readyThisPrompt: int
  // Whether a counted start has no counted finish yet.
  var open: bool

  // The outcomes that count a finish, and those that count a ready prompt.
  pure val closing = Set(CommandFinished, CommandDropped, ReadyCountedDropped)
  pure val counting = Set(ReadyCounted, ReadyCountedDropped)

  action begin = all {
    init,
    started' = 0,
    finished' = 0,
    ready' = 0,
    readyThisPrompt' = 0,
    open' = false,
  }

  action advance = {
    nondet e = oneOf(events)
    val o = moves.get((state, e))._2
    all {
      take(e),
      started' = if (o == CommandStarted) started + 1 else started,
      finished' = if (closing.contains(o)) finished + 1 else finished,
      ready' = if (counting.contains(o)) ready + 1 else ready,
      readyThisPrompt' =
        if (Set(PromptStart, CommandStart, CommandEnd).contains(e)) 0
        else if (counting.contains(o)) readyThisPrompt + 1
        else readyThisPrompt,
      open' = if (o == CommandStarted) true else if (closing.contains(o)) false else open,
    }
  }

  // No command finishes that did not start.
  val neverMoreFinishedThanStarted = finished <= started

  // One prompt is counted ready at most once, however many input starts it prints.
  val readyOncePerPrompt = readyThisPrompt <= 1

  // The phase tells whether a command is running, and whether this prompt is counted.
  val phaseTellsTheCounts =
    (open iff state == Running) and ((readyThisPrompt == 1) iff state == Ready)

  // A prompt counted ready has no command left running behind it.
  val readyMeansNothingRuns = readyThisPrompt == 1 implies not(open)

  // An end closes the command it follows: a second end counts nothing.
  val endClosesTheCommand = moved and event == CommandEnd implies not(open)

  val reachedFinishedAndReady = finished > 0 and ready > 0
  val reachedReadyAfterDrop = moved and outcome == ReadyCountedDropped
}
