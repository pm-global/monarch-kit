# Raw: Live Domain Test Suite

## What

The current test strategy is mock-only — all AD/DNS/GPO cmdlets are mocked and tests run
without a domain. This is correct for CI and solo development but presents a limitation:
mocks can diverge from real AD behavior, and some failure modes are only detectable against
a live domain.

## Why It's Raw

Practical constraints make this non-trivial:
- A BadBlood domain works for discovery testing (intentionally seeded issues) but not all
  conditions can be replicated synthetically
- Some tests require domain states that are mutually exclusive (e.g., accounts with and
  without adminCount=1 simultaneously)
- CI integration requires a live AD environment, which adds significant infrastructure cost
- Remediation tests against a live domain carry real-state risk even with WhatIf coverage

## Known Approaches

- Separate test suite (`Monarch.LiveDomain.Tests.ps1`) that runs only when a domain is available
- Environment variable gate: skip live tests unless `$env:MONARCH_TEST_DOMAIN` is set
- BadBlood-seeded VM as the test target for discovery functions
- Remediation live tests require a purpose-built disposable domain — high effort

## Next Step

When Phase 2 remediation functions are implemented, revisit. The mock strategy for
destructive operations needs particular scrutiny — a live-domain integration test for
suspend → restore → delete would catch serialization and hold-period edge cases that mocks
cannot replicate.
