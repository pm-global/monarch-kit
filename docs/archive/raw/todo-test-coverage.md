# Raw: Test Coverage Audit — 80% Target

## What

Audit current test coverage across Monarch.Tests.ps1 against an 80% behavior-coverage target.
Includes integration tests added during BadBlood fix work. Broader question: what end-to-end
paths lack integration tests?

## Scope

- SRE + testing specialist review of existing tests
- Map each public function to its test coverage
- Identify untested behaviors (not just untested lines)
- Flag integration test gaps for multi-function flows (orchestrator paths)

## Next Step

No design needed — this is an audit task. Assign to a session, review tests against functions
in Monarch.psm1, produce a findings list. Findings that require new tests become Class B changes.
