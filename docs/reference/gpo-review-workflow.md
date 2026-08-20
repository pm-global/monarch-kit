# GPO Review Guide

How experienced administrators review Group Policy Objects. Three methods from fastest to most thorough, plus priority guidance for what to focus on.

---

## Method 1: HTML Reports (fastest)

1. Run Discovery phase or `Export-GPOAudit` directly
2. Open `01-HTML-Reports/00-INDEX.html` in a browser
3. Click through each GPO, look for:
   - User Rights Assignment (who can do what)
   - Security Options (password policies, audit settings)
   - Scripts (startup/shutdown/logon/logoff)
   - Software Installation (what's being pushed)
   - Registry settings (application configs)

## Method 2: CSV Filtering (most efficient)

1. Open `03-CSV-Analysis/gpo-summary.csv` in Excel
2. Filter for:
   - `HasUserRights = TRUE` (privilege grants)
   - `HasScripts = TRUE` (potential hardcoded credentials)
   - `HasSoftwareInstall = TRUE` (what's being installed)
3. Sort by `ModifiedTime` (recent changes)
4. Check `gpo-linkage.csv` for scope (where applied)

## Method 3: Compare to Baseline (most thorough)

1. Download Microsoft Security Baseline: https://aka.ms/securitybaselines
2. Import baseline GPOs to test environment
3. Use `Get-GPOReport` to compare settings
4. Focus on deviations from baseline

---

## What to Focus On

**High priority:**
- User Rights Assignment (SeDebugPrivilege, SeTcbPrivilege, etc.)
- Local admin rights (Restricted Groups)
- Startup/logon scripts (hardcoded passwords?)
- Overly broad linkage (policies applied to Domain root)

**Medium priority:**
- Security Options (password policies, account lockout)
- Audit policies (logging configuration)
- Software Restriction Policies / AppLocker

**Low priority:**
- Cosmetic settings (desktop wallpaper, etc.)
- User preferences (mapped drives -- but check for credentials)

---

## Related Tools

- **Microsoft Policy Analyzer** -- compares GPOs against baselines
- **Ping Castle** -- free AD security assessment (point-in-time scanner, complements monarch-kit's repeatable audit workflow)
- **BloodHound** -- attack path mapping (use carefully in production)
- **Semperis Directory Services Protector** -- commercial AD security monitoring

monarch-kit differs from point-in-time scanners like Ping Castle and BloodHound: it provides a repeatable audit workflow with phased remediation, hold periods, and compliance tracking. Use the scanners for initial assessment, use monarch-kit for the ongoing operational cycle.

---

## Further Reading

- [Microsoft Security Baselines](https://aka.ms/securitybaselines)
- [Active Directory Security Best Practices](https://docs.microsoft.com/en-us/windows-server/identity/ad-ds/plan/security-best-practices/best-practices-for-securing-active-directory)
- [Tier Model for Admin Access](https://docs.microsoft.com/en-us/security/privileged-access-workstations/privileged-access-access-model)
