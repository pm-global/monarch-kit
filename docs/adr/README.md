# Architecture decision records

`skills/build-adr-index/Build-AdrIndex.ps1` builds this file. Do not edit it by hand.

The records appear in dependency order, so a record always follows the records it
depends on. The file numbers carry no meaning beyond the order the records were written.

## Decisions

- **[ADR-0000](0000-thesis.md)** — Thesis: reliable on degraded and partly inaccessible Active Directory
- **[ADR-0003](0003-every-threshold-records-its-reason.md)** — Every threshold and rule records its reason
- **[ADR-0001](0001-graceful-degradation.md)** — Graceful degradation over fail-fast _(depends on ADR-0000)_
- **[ADR-0004](0004-local-only.md)** — Local only _(depends on ADR-0000)_
- **[ADR-0007](0007-dormancy-threshold-ninety-days.md)** — Dormant means ninety days without a logon _(depends on ADR-0003)_

## Independent decisions

These records sit outside every dependency chain.

- **[ADR-0002](0002-one-function-per-component.md)** — One function per Active Directory component
- **[ADR-0005](0005-adr-frontmatter.md)** — ADRs carry depends-on and superseded-by
