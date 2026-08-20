# monarch-kit

An Active Directory audit tool for degraded, multi-domain, or partly inaccessible
environments, run by an administrator who holds rights on part of the estate.

## Language

**Audit area**:
One of the subjects a check belongs to, such as Identity Lifecycle or Backup Readiness.
Every result carries its area in a field named `Domain`, which is not the Active
Directory domain.
_Avoid_: domain, category, section, pillar.

**Dormant account**:
An enabled user account with no logon inside monarch-kit's threshold. Active Directory
has no dormancy concept, so the threshold belongs to monarch-kit.
_Avoid_: stale account, inactive account, unused account.
