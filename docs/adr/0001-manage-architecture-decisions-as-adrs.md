# 0001: Manage architecture decisions as ADRs

Date: 2026-07-02

Status: Accepted

## Context

The project started as an experimental terminal renderer, but the intended
product direction now includes native macOS UI, Neovide-like terminal rendering,
tabs and panes, session restore, agent notifications, and inline image support.

These choices affect the runtime architecture, repository structure, renderer,
and integration strategy. They should not live only in chat history or issue
comments.

## Decision

Track architecture decisions in `docs/adr` as Markdown ADR files.

Each ADR uses a numeric prefix, a short slug, a date, a status, and three
sections:

- Context
- Decision
- Consequences

`docs/adr/README.md` is the index. `docs/adr/template.md` is the template for
new records.

## Consequences

Architectural direction becomes reviewable in the repository and can be linked
from issues and pull requests.

When implementation differs from the target architecture, the difference should
be explicit in an ADR instead of becoming accidental technical debt.
