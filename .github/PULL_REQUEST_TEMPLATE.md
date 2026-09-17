## Summary

Describe the user-visible outcome and why this is the smallest coherent change.

## Verification

- [ ] `just precommit`
- [ ] `just quality` on an unlocked Mac with the display awake. CI does not run
      the app-launching smokes, so paste what it reported.
- [ ] Tests cover changed behavior or the exception is explained below.
- [ ] Relevant native terminal or Neovim smoke tests ran when applicable.
- [ ] Documentation and release impact were reviewed.
- [ ] No unrelated changes, generated build outputs, credentials, or private
      terminal content are included.

## Risk

Describe renderer, terminal protocol, session, security, performance, and
rollback considerations. Write `None` only after checking each category.
