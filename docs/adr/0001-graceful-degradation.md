---
depends-on: [0000]
superseded-by:
---

# Graceful degradation over fail-fast

An operation returns its best partial result together with an explicit account of what
it could not do. It never stops without an explanation.

## Consequences

Fail-fast is given up. A function that meets a failure records it and continues, so
every function carries more branches to test. `CODING_STANDARDS.md` ranks
Diagnosability above Code budget for this reason.
