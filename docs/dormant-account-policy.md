# Dormant Account Policy

Compliance-aligned dormant account lifecycle policy. Aligns with PCI DSS v4.0.1, NIST 800-53, and Microsoft 2026 guidance.

---

## Definition of Dormant

- Enabled account with no interactive logon for 90+ days
- Uses cross-DC LastLogon aggregation for accuracy (lastLogonTimestamp for first pass, cross-DC lastLogon for accounts near threshold)
- Secondary signal: password unchanged for 365+ days

## Lifecycle

**1. Discovery (quarterly minimum, monthly for high-risk environments)**
- Generate dormant account report
- Automatic exclusions applied (service accounts, MSAs/gMSAs, built-in accounts, privileged accounts, recently created accounts)
- Output is for human review — no automatic action

**2. Review (human gate)**
- Manual review of dormant account list
- Stakeholder notification for account owners
- Document exceptions with business justification
- Create reviewed subset for disable phase

**3. Disable (after review approval)**
- Archive group memberships and source OU to extensionAttribute14
- Disable account
- Remove all group memberships (prevents indirect access via nested groups)
- Move to quarantine OU
- Write disable date to extensionAttribute15

**4. Hold period (30–90 days)**
- Monitor for reclamation requests
- Track authentication failures and service interruptions
- Document any re-enabled accounts with justification
- Minimum 30 days, configurable up to 365

**5. Delete (after hold period + final approval)**
- Archive SID and full properties (7-year retention guidance)
- Permanent deletion
- Document final metrics

## Mandatory Exclusions (never auto-process)

- Accounts with PasswordNeverExpires flag
- Accounts with SPNs (service principals)
- Managed Service Accounts (MSA) and Group Managed Service Accounts (gMSA)
- Keyword-tagged accounts (SERVICE, -SVC, APP, BREAKGLASS, SQL, IIS, BACKUP, MONITOR)
- Built-in accounts (Administrator, krbtgt, etc.)
- Privileged admin accounts (separate manual review process)
- Recently created accounts (< 60 days) that never logged on

## Governance

- **Owned by:** Domain Admins
- **Discovery cadence:** Quarterly minimum, monthly for high-risk environments
- **Review:** Annual policy review
- **Execution:** Strictly human-in-the-loop (no unattended automation)
- **Compliance reporting:** Retain deletion archives per compliance requirements (typically 7 years)

## Compliance References

- [PCI DSS v4.0.1 Requirement 8](https://www.pcisecuritystandards.org/) — inactive account management
- [NIST SP 800-53 Rev 5](https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final) — account management controls
- [Microsoft 2026 Guidance](https://docs.microsoft.com/en-us/windows-server/identity/ad-ds/plan/security-best-practices/best-practices-for-securing-active-directory) — dormant account remediation

## Best Practices

**Documentation:** Keep all audit outputs as evidence. Document all exceptions with business justification. Maintain a change log (what, when, who, why).

**Communication:** Notify account owners before disabling. Set expectations on hold periods. Document the reclamation process. Report metrics to stakeholders.

**Iteration:** Start conservative (120–180 day threshold if uncertain). Tighten over time (move to 90 days). Adjust exceptions based on incidents. Refine based on environment.
