---
depends-on: [0003]
superseded-by:
---

# Dormant means ninety days without a logon

An account is dormant after 90 days with no logon.

PCI DSS v4.0.1, Requirement 8.2.6 requires that an inactive user account is removed or
disabled within 90 days of inactivity. NIST SP 800-53 Rev. 5, AC-2(3) sets no number and
requires the organization to define one. So 90 satisfies PCI directly and supplies the value
NIST asks for.

The value is configurable through `DormancyThresholdDays`. Changing it changes what
monarch-kit reports, and nothing else.

`docs/reference/dormant-account-standard.md` holds the standards and their links. That file
records what outside bodies require. This record holds the number monarch-kit picked and why.

## Consequences

A domain that raises the value above 90 leaves PCI compliance. monarch-kit gives no warning,
because it reports what it finds and enforces no policy.

Lowering the value raises the dormant count sharply on estates with seasonal or contract
staff. That reads as a regression in the report and is not one.
