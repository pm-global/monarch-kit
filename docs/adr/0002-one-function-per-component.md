---
depends-on: []
superseded-by:
---

# One function per Active Directory component

Each public function enumerates exactly one Active Directory component and returns a
structured object for it. A component is never split across two functions, and one
function never covers two components.

## Consequences

The module is wide rather than deep. An audit that spans several components is composed
by the orchestrator, not by a single large function.
