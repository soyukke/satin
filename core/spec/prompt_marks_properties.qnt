// What the mark machine of the shell prompt tracker has to keep. The machine
// in prompt_marks.qnt is generated from `prompt_mark_advance`
// (src/vt/prompt.kizu); these properties are written by hand and
// scripts/spec-quint checks them.
module prompt_marks_properties {
  import prompt_marks.* from "./prompt_marks"

  pure val running = Set(Running, ReadyRunning)

  // A prompt is counted ready only at an input start.
  val readyCountedOnlyAtInputStart = moved and outcome == ReadyCounted implies event == InputStart

  // An input start counts a prompt exactly when none is counted yet.
  val inputStartCountsOnce =
    moved and event == InputStart implies
      ((outcome == ReadyCounted) iff not(Set(Ready, ReadyRunning).contains(previous)))

  // Every command start is counted, and nothing else is.
  val startedExactlyAtCommandStart = moved implies ((outcome == CommandStarted) iff (event == CommandStart))

  // A command finishes exactly when its end comes while one is running.
  val finishedExactlyAtAnOpenEnd =
    moved implies ((outcome == CommandFinished) iff (event == CommandEnd and running.contains(previous)))

  // Once a mark has come, the tracker never forgets that the shell prints them.
  val seenStaysSeen = moved implies state != Unseen

  // A run that never finishes a command says nothing about half of the above.
  val reachedFinished = moved and outcome == CommandFinished
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
      finished' = if (o == CommandFinished) finished + 1 else finished,
      ready' = if (o == ReadyCounted) ready + 1 else ready,
      readyThisPrompt' =
        if (Set(PromptStart, CommandStart, CommandEnd).contains(e)) 0
        else if (o == ReadyCounted) readyThisPrompt + 1
        else readyThisPrompt,
      open' = if (o == CommandStarted) true else if (o == CommandFinished) false else open,
    }
  }

  // No command finishes that did not start.
  val neverMoreFinishedThanStarted = finished <= started

  // One prompt is counted ready at most once, however many input starts it prints.
  val readyOncePerPrompt = readyThisPrompt <= 1

  // The phase tells whether a command is running, and whether this prompt is counted.
  val phaseTellsTheCounts =
    (open iff Set(Running, ReadyRunning).contains(state))
      and ((readyThisPrompt == 1) iff Set(Ready, ReadyRunning).contains(state))

  // An end closes the command it follows: a second end counts nothing.
  val endClosesTheCommand = moved and event == CommandEnd implies not(open)

  val reachedFinishedAndReady = finished > 0 and ready > 0
}
