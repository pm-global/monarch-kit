# Phase 4: Comparison Functions

**Prerequisite:** Phase 1 complete (needs baseline data from prior Discovery runs).

**Scope:** Functions that compare two datasets or compare against an external standard.

## Functions

| Function | Domain | Requirement |
|----------|--------|-------------|
| `Compare-DomainBaseline` | Audit & Compliance | Two baseline snapshots (previous + current) |
| `Compare-GPO` | Group Policy | Two GPO snapshots or DC-to-DC comparison |
| `Compare-CISBaseline` | Security Posture | External baseline definition file |
| `Test-TieredAdminCompliance` | Privileged Access | Tier model definition in config |

## Test Focus

Delta detection (field added, removed, changed). Classification of changes (expected, advisory,
requires-review). Handles missing previous baseline gracefully. CIS baseline comparison accepts
generic baseline definition format.
