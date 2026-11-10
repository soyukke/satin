# Specifications of the core's state machines

A state machine of the core is written once, as a transition function, and
everything here is read out of that function.

| File | What it is |
| --- | --- |
| `src/main.kizu` | Calls each transition function for every state and event with `std::machine` and prints the tables as JSON |
| `prompt_tracker.qnt` | The Quint machine generated from `prompt_advance` in `../src/vt/prompt.kizu`. Do not edit |
| `prompt_properties.qnt` | The properties that machine has to keep, written by hand |
| `prompt_marks.qnt` | The Quint machine generated from `prompt_mark_advance` in the same file: what each OSC 133 mark does to the counts. Do not edit |
| `prompt_marks_properties.qnt` | Its properties, and the counts kept sound over every order of marks |

```sh
just spec-table   # write the generated machines again after changing a transition function
just spec-quint   # check the properties over random runs of the machines
```

`just ci-core` fails when a generated machine is out of step with its
transition function, and `just ci-static` runs `just spec-quint`.

## Adding a machine

1. Give the code one pure function from a state and an event to the next state
   and what the step did, over enums without payloads, and make the code that
   runs the machine call it.
2. Print its table in `src/main.kizu` and add its module to `modules` in
   `../scripts/spec-table`, in the same order.
3. Write its properties in a `*_properties.qnt` and list them in
   `../scripts/spec-quint`, with a witness: a state the properties are about,
   which the runs must reach for the check to mean anything.

## What the check is

The generated machine holds every answer of the transition function, so it
cannot differ from the code. The properties are searched for a counterexample
over 2000 random runs of 40 steps from a fixed seed; that is a search, not a
proof. A table knows only states, events and outcomes: what the code keeps
beside the state, such as the bytes of a payload, is outside it.
