# Security Policy

## Supported versions

Security fixes are applied to the latest release and the current `main`
branch. Older development artifacts are not supported.

## Reporting a vulnerability

Use GitHub's
[private vulnerability reporting form](https://github.com/soyukke/satin/security/advisories/new)
to send a private report. Do not include credentials, exploit details, or
sensitive terminal output in a public issue.

Include the affected version and macOS version, the impact, reproduction steps,
and any proposed mitigation. Relevant vulnerabilities include bypasses of the
local control boundary, update or signature verification, command or path
injection, unsafe terminal escape handling with host impact, and release
integrity failures. Ordinary crashes without a security boundary impact belong
in the public bug tracker.

You should receive an acknowledgement within seven days and an initial triage
within 14 days. The target for a fix and coordinated disclosure is 90 days from
the report, but the reporter and maintainer may agree on a different timeline
based on severity, exploit availability, and release constraints. Public
disclosure should wait until a fixed release is available or that agreed date
is reached.

If the private reporting form is unavailable, open a public issue that contains
no sensitive details and asks the maintainer to establish a private contact
channel. The maintainer will protect reporter identity and vulnerability details
to the extent permitted by GitHub and applicable law.
