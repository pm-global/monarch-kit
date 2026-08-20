---
depends-on: []
superseded-by:
---

# ADRs carry depends-on and superseded-by

Every ADR in this repository carries two frontmatter fields, `depends-on` and
`superseded-by`, and no others. The upstream ADR format asks for no metadata at all.
This repository deviates because agents read the decisions before they read the code,
and an explicit dependency graph is what lets them load only the decisions that bear on
the task.

## Consequences

Keep both fields on every new ADR. Do not strip them to match the upstream format.
