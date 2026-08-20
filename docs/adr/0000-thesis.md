---
depends-on: []
superseded-by:
---

# Thesis: reliable on degraded and partly inaccessible Active Directory

monarch-kit audits Active Directory environments that are degraded, spread across
multiple domains, or reachable only in part, for an administrator who holds rights on
some of the environment and not the rest. It returns a useful report whatever it fails
to reach.

monarch-kit runs against a local environment and needs no internet access. Hybrid and
cloud identity sources are out of scope. See ADR-0004.

One run audits one domain.
