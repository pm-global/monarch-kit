# Review Phase Checklists

Expert-curated checklist content for the Review phase of Invoke-DomainAudit. These are institutional knowledge representing what a competent reviewer actually looks for. **Do not regenerate, rewrite, or replace with generic items.**

---

## GPO Review

- [ ] Opened GPO HTML index and reviewed major policies
- [ ] Checked for unlinked (orphaned) GPOs
- [ ] Reviewed policies with User Rights Assignment
- [ ] Checked startup/logon scripts for hardcoded credentials
- [ ] Verified GPO linkage scope is appropriate
- [ ] Compared high-risk settings against security baseline

## Privileged Access Review

- [ ] Verified Domain Admin count is reasonable (< 10)
- [ ] Identified user accounts in admin groups (should be separate admin accounts)
- [ ] Found service accounts with admin rights
- [ ] Reviewed stale admin accounts (no recent logon)
- [ ] Checked for accounts with SPN + admin rights
- [ ] Created remediation plan for overpermissioned accounts

## Dormant Account Review

- [ ] Reviewed full dormant accounts CSV
- [ ] Validated automatic exclusions are appropriate
- [ ] Identified accounts for disabling (business review)
- [ ] Notified account owners/managers where possible
- [ ] Created reviewed subset CSV for disable phase
- [ ] Documented exceptions with business justification

## Documentation

- [ ] Created remediation plan document
- [ ] Defined rollback procedures
- [ ] Scheduled change windows
- [ ] Identified stakeholders for notification
- [ ] Established monitoring plan
