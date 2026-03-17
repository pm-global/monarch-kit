# Network Handover Toolkit
## Professional Scripts for Inheriting and Cleaning Up Un/Mismanaged Networks

---

## 📋 Overview

This toolkit provides enterprise-grade PowerShell scripts for taking over and remediating inherited Active Directory environments. Designed for networks that are "functioning but unknown" - where you need to understand, document, and gradually clean up without breaking production.

**Philosophy:** Safety first, human-in-the-loop, evidence-based decisions.

---

## 🎯 Use Case

You've inherited a network that:
- ✅ Works correctly right now
- ❓ Has unknown configuration history
- ⚠️ Likely has overpermissioned accounts
- 📊 Needs systematic documentation before cleanup
- 🔒 Must stay operational during remediation

This toolkit helps you build a repeatable onboarding process to convert chaos into something manageable.

---

## 📦 What's Included

### 1. **Export-GPOAudit.ps1** - Group Policy Analysis
**Purpose:** Understand what policies exist and what they do

**What it does:**
- Exports ALL GPOs in three formats:
  - **HTML Reports** - Human-readable, browse in your browser
  - **XML Backup** - Complete restore-ready backup
  - **CSV Analysis** - Filterable data for finding risks
- Identifies unlinked (orphaned) GPOs
- Flags high-risk settings (user rights, scripts, software installation)
- Shows who can edit each GPO (permission analysis)
- Creates clickable index for easy navigation

**How pros review GPOs:**
1. Start with HTML reports (browse visually)
2. Use CSV to filter for specific concerns (passwords, privileges, scripts)
3. Focus on: User Rights Assignment, Security Options, Startup scripts, overly broad links
4. Compare against Microsoft Security Baseline (https://aka.ms/securitybaselines)

**Usage:**
```powershell
# Basic audit with HTML + XML + CSV
.\Export-GPOAudit.ps1 -OutputPath "C:\Handover\GPO-Audit"

# Include permission analysis (who can edit GPOs)
.\Export-GPOAudit.ps1 -OutputPath "C:\Handover\GPO-Audit" -IncludePermissions

# Full audit including WMI filters
.\Export-GPOAudit.ps1 -IncludePermissions -IncludeWMIFilters
```

**Output:**
```
GPO-Audit-20260205-143022/
├── 00-SUMMARY/
│   ├── EXECUTIVE-SUMMARY.txt    ← START HERE
│   ├── audit.log
│   └── domain-info.csv
├── 01-HTML-Reports/
│   ├── 00-INDEX.html            ← Open this in browser
│   ├── Default Domain Policy.html
│   └── ...
├── 02-XML-Backup/               ← Keep this safe (restore capability)
├── 03-CSV-Analysis/
│   ├── gpo-summary.csv          ← Filter for HasUserRights, HasScripts
│   └── gpo-linkage.csv          ← Find unlinked GPOs
└── 04-Permissions/
    └── REVIEW-overpermissioned-gpos.csv
```

---

### 2. **Find-DormantAccounts.ps1** - Dormant Account Discovery
**Purpose:** Identify accounts that haven't logged on in 90+ days

**What it does:**
- Queries **actual LastLogon** across ALL domain controllers (not LastLogonTimestamp)
- Applies safety exclusions automatically:
  - Service accounts (SPNs, PasswordNeverExpires, keywords)
  - Built-in accounts (Administrator, krbtgt, etc.)
  - Privileged admin accounts (separate review process)
- Flags secondary signals (stale passwords even if recent logon)
- Generates CSV for **human review** - does NOT modify anything

**Safety features:**
- Read-only (no AD modifications)
- Extensive exclusion logic
- Cross-DC aggregation for accuracy
- Exports full context for informed decisions

**Usage:**
```powershell
# Standard 90-day dormancy check (aligns with PCI/NIST/Microsoft 2026 guidance)
.\Find-DormantAccounts.ps1

# Custom threshold (e.g., 120 days for more conservative approach)
.\Find-DormantAccounts.ps1 -DormantDays 120

# Include accounts that never logged on (evaluate separately)
.\Find-DormantAccounts.ps1 -IncludeNeverLoggedOn
```

**Output:**
```csv
SamAccountName, DisplayName, LastLogon, DaysSinceLogon, PasswordAgeDays, MemberOfGroups, DormantReason
jsmith, John Smith, 2025-08-15, 174, 356, "Marketing; VPN Users", "No logon for 174 days | Password unchanged for 356 days"
```

---

### 3. **Disable-DormantAccounts.ps1** - Disable Phase
**Purpose:** Safely disable reviewed dormant accounts

**What it does:**
1. Disables account
2. **Removes ALL group memberships** (critical security step)
3. Moves to quarantine OU
4. Adds disable date/reason to account notes

**Critical safety:**
- Requires CSV from reviewed Find-DormantAccounts output
- Mandatory `-WhatIf` workflow (preview first, then execute)
- Confirmation prompts by default
- Does NOT delete (that's next phase after 30-90 day hold)

**Process (90-day disable + membership strip + 30-90 day hold):**
```powershell
# STEP 1: Review the CSV from Find-DormantAccounts.ps1
# Remove any accounts you want to keep
# Save as "reviewed-dormant.csv"

# STEP 2: Always test with WhatIf first
.\Disable-DormantAccounts.ps1 -CSVPath ".\reviewed-dormant.csv" -WhatIf

# STEP 3: Review WhatIf output, then execute
.\Disable-DormantAccounts.ps1 -CSVPath ".\reviewed-dormant.csv"

# STEP 4: Monitor for 30-90 days (default: 30 days per policy)
# If no reclamation requests, proceed to deletion
```

**Why remove group memberships immediately:**
- Prevents indirect access via nested groups
- Eliminates token risks
- Clean break from production environment

---

### 4. **Delete-DormantAccounts.ps1** - Delete Phase
**Purpose:** Permanently delete accounts after hold period

**What it does:**
- Finds accounts disabled for >= specified days (default 30)
- Creates pre-deletion archive (SIDs, groups, all properties)
- Permanently deletes accounts

**Critical warnings:**
- This is **PERMANENT** deletion
- Always archives SID/history first (compliance requirement)
- Requires confirmation + WhatIf workflow

**Hold period guidance:**
- Microsoft 2026: "several weeks"
- Industry standard: 30-60 days
- Conservative: 90 days
- Script default: 30 days (configurable)

**Usage:**
```powershell
# STEP 1: Always preview first
.\Delete-DormantAccounts.ps1 -WhatIf

# STEP 2: Execute with default 30-day hold
.\Delete-DormantAccounts.ps1

# STEP 3: Or use custom hold period (e.g., 60 days)
.\Delete-DormantAccounts.ps1 -MinimumDisabledDays 60
```

**Archive retention:**
- Keep archive per compliance requirements (typically 7 years)
- Contains SIDs (critical for forensics)
- Contains full group memberships and properties

---

### 5. **Audit-PrivilegedAccess.ps1** - Find Overpermissioned Accounts
**Purpose:** Identify accounts with excessive privileges

**What it does:**
- Enumerates all privileged group memberships
- Analyzes risk factors:
  - User accounts in admin groups (should be separate admin accounts)
  - Service accounts with admin rights (security risk)
  - Stale admin accounts (no recent logon)
  - Accounts with SPN + admin rights (Kerberoasting risk)
- Finds "AdminCount orphans" (were privileged, no longer are)
- Generates risk scores and high-priority review lists

**Focus areas:**
- Domain Admins count (should be < 5, typically 3-4)
- Enterprise Admins (should be minimal)
- Service accounts in privileged groups
- Nested group memberships granting privilege

**Usage:**
```powershell
# Basic privileged access audit
.\Audit-PrivilegedAccess.ps1

# Include nested group analysis (recursive membership)
.\Audit-PrivilegedAccess.ps1 -IncludeNestedGroups
```

**Output:**
```
Privileged-Access-Audit-20260205/
├── EXECUTIVE-SUMMARY.txt              ← START HERE
├── privileged-users-analysis.csv      ← All privileged accounts with risk scores
├── REVIEW-high-risk-privileged-accounts.csv  ← Immediate attention needed
├── privileged-groups-summary.csv      ← Group membership counts
└── admincount-orphans.csv             ← Cleanup candidates
```

**What to look for:**
- User accounts in Domain Admins (should be user-adm accounts)
- > 10 Domain Admins (indicates over-permissioning)
- Service accounts in admin groups
- Accounts with RiskScore >= 2

---

### 6. **Create-NetworkBaseline.ps1** - Document Current State
**Purpose:** Create comprehensive "as-is" documentation

**What it does:**
- Domain and forest functional levels
- All domain controllers + FSMO roles
- Sites and subnets
- OU structure
- Object counts (users, computers, groups)
- Replication health across all DCs
- DNS zones (if accessible)
- Password policies

**Usage:**
```powershell
.\Create-NetworkBaseline.ps1 -OutputPath "C:\Handover\Baseline"
```

**Why this matters:**
- Establishes starting point for change tracking
- Documents configuration for disaster recovery
- Required for audit trails ("what changed?")
- Helps identify misconfigurations

---

## 🔄 Complete Handover Workflow

### Phase 1: Discovery (Week 1-2)
```powershell
# 1. Create baseline documentation
.\Create-NetworkBaseline.ps1 -OutputPath "C:\Handover\Baseline"

# 2. Export and review ALL GPOs
.\Export-GPOAudit.ps1 -OutputPath "C:\Handover\GPO" -IncludePermissions -IncludeWMIFilters

# 3. Audit privileged access
.\Audit-PrivilegedAccess.ps1 -OutputPath "C:\Handover\Privileged" -IncludeNestedGroups

# 4. Identify dormant accounts (for review)
.\Find-DormantAccounts.ps1 -OutputPath "C:\Handover\dormant-review.csv"
```

**Review priorities:**
1. Open GPO HTML index - understand what policies do
2. Review REVIEW-overpermissioned-gpos.csv
3. Review REVIEW-high-risk-privileged-accounts.csv
4. Check dormant-review.csv for accounts to disable

### Phase 2: Risk Remediation (Week 3-4)
```powershell
# 1. Remove overpermissioned accounts from admin groups (manual)
# Use privileged-users-analysis.csv to guide removals

# 2. Disable dormant accounts (reviewed subset)
.\Disable-DormantAccounts.ps1 -CSVPath ".\reviewed-dormant.csv" -WhatIf
.\Disable-DormantAccounts.ps1 -CSVPath ".\reviewed-dormant.csv"

# 3. Document exceptions
# Add notes to accounts kept for business reasons
```

### Phase 3: Monitoring (Week 5-8)
- Monitor for reclamation requests on disabled accounts
- Watch for authentication failures (indicates missed dependency)
- Track metrics for reporting

### Phase 4: Cleanup (Week 9+)
```powershell
# After 30-90 day hold period
.\Delete-DormantAccounts.ps1 -WhatIf
.\Delete-DormantAccounts.ps1 -MinimumDisabledDays 30
```

---

## 📊 Dormant Account Policy Summary

**Aligns with:** PCI DSS v4.0.1, NIST 800-53, Microsoft 2026 guidance, industry best practices

### Definition of Dormant
- Enabled account with no interactive logon ≥ **90 days**
- Uses accurate cross-DC LastLogon (not LastLogonTimestamp)
- Secondary signal: password unchanged > 365 days

### Process
1. **Disable Phase (after 90 days dormant)**
   - Generate quarterly review CSV
   - Manual review + stakeholder notification
   - Disable account
   - **Remove ALL group memberships** (prevents indirect access)
   - Move to quarantine OU

2. **Delete Phase (after 30-90 day hold)**
   - Hold disabled accounts for 30-90 days (configurable)
   - Archive SID/history for compliance
   - Permanently delete if no reclamation

### Mandatory Exceptions (never auto-process)
- PasswordNeverExpires accounts
- Accounts with SPNs (service principals)
- Keyword-tagged (SERVICE, -SVC, APP, BREAKGLASS)
- Built-in accounts
- Privileged admin accounts (separate manual review)
- Recently created accounts (< 60 days) that never logged on

### Governance
- **Owned by:** Domain Admins
- **Cadence:** Quarterly discovery + disable minimum (monthly for high-risk)
- **Review:** Annual policy review
- **Execution:** Strictly human-in-the-loop (no unattended automation)

---

## 🛡️ Safety Features

All scripts include:
- ✅ **Read-before-write** - Query first, modify never (except disable/delete scripts)
- ✅ **WhatIf support** - Always preview changes
- ✅ **Extensive logging** - Audit trail for all actions
- ✅ **Error handling** - Continue on errors, report all issues
- ✅ **Confirmation prompts** - Human approval required
- ✅ **Exclusion logic** - Automatic protection of critical accounts
- ✅ **Result exports** - CSV output for every operation

**Never trust, always verify:**
- Run with `-WhatIf` first
- Review output carefully
- Test on subset before bulk operations
- Keep backups of everything
- Document exceptions

---

## 🔧 Requirements

- **PowerShell:** 5.1 or later
- **Modules:**
  - ActiveDirectory (all scripts)
  - GroupPolicy (GPO audit)
  - DnsServer (optional, for baseline DNS zones)
- **Permissions:**
  - Domain Admin or equivalent read rights (discovery scripts)
  - Appropriate write permissions (disable/delete scripts)
- **Environment:** Windows Server 2019+ or Windows 10/11 with RSAT

---

## 🎓 How Pros Review GPOs

Since you asked specifically about this:

### Method 1: HTML Reports (Fastest)
1. Run `Export-GPOAudit.ps1`
2. Open `01-HTML-Reports/00-INDEX.html` in browser
3. Click through each GPO, look for:
   - User Rights Assignment (who can do what)
   - Security Options (password policies, audit settings)
   - Scripts (startup/shutdown/logon/logoff)
   - Software Installation (what's being pushed)
   - Registry settings (application configs)

### Method 2: CSV Filtering (Most Efficient)
1. Open `03-CSV-Analysis/gpo-summary.csv` in Excel
2. Filter for:
   - `HasUserRights = TRUE` (privilege grants)
   - `HasScripts = TRUE` (potential hardcoded creds)
   - `HasSoftwareInstall = TRUE` (what's being installed)
3. Sort by `ModifiedTime` (recent changes)
4. Check `gpo-linkage.csv` for scope (where applied)

### Method 3: Compare to Baseline (Most Thorough)
1. Download Microsoft Security Baseline: https://aka.ms/securitybaselines
2. Import baseline GPOs to test environment
3. Use `Get-GPOReport` to compare settings
4. Focus on deviations from baseline

### What to Focus On
**High Priority:**
- User Rights Assignment (SeDebugPrivilege, SeTcbPrivilege, etc.)
- Local admin rights (Restricted Groups)
- Startup/logon scripts (hardcoded passwords?)
- Overly broad linkage (policies applied to Domain root)

**Medium Priority:**
- Security Options (password policies, account lockout)
- Audit policies (logging configuration)
- Software Restriction Policies / AppLocker

**Low Priority:**
- Cosmetic settings (desktop wallpaper, etc.)
- User preferences (mapped drives - but check for creds!)

### Tools Beyond These Scripts
- **Policy Analyzer** - Microsoft tool for comparing GPOs
- **Semperis Directory Services Protector** - Commercial AD security
- **Ping Castle** - Free AD security assessment tool
- **BloodHound** - Attack path mapping (use carefully in production)

**NIST Templates:** You're right they're overkill for most environments. Start with Microsoft Security Baseline instead - it's more practical.

---

## 📝 Best Practices

### Documentation
- Keep all audit outputs (they're your evidence)
- Document all exceptions with business justification
- Maintain change log (what, when, who, why)
- Use extensionAttribute fields for metadata

### Timing
- Run audits quarterly minimum
- Disable dormant accounts quarterly
- Delete after hold period (30-90 days)
- Review privileged access monthly

### Communication
- Notify account owners before disabling
- Set expectations on hold periods
- Document reclamation process
- Report metrics to stakeholders

### Iteration
- Start conservative (120-180 day threshold if nervous)
- Tighten over time (move to 90 days)
- Learn from incidents (adjust exceptions)
- Refine based on your environment

---

## 🐛 Troubleshooting

### "Cannot find domain controllers"
- Run on domain-joined machine
- Ensure DNS resolution works
- Check firewall rules (AD ports)

### "Access denied" errors
- Need Domain Admin or equivalent rights
- Some scripts require specific delegated permissions
- Check UAC (run as administrator)

### "LastLogon always null"
- Account truly never logged on, OR
- All DCs were unreachable during query
- Check DC availability with `Get-ADDomainController -Discover`

### GPO export fails for specific GPO
- Corrupted GPO (check Event Viewer)
- Permission issue (even DA can have problems with DENY ACLs)
- Skip and investigate separately

---

## 📚 Further Reading

- [Microsoft Security Baselines](https://aka.ms/securitybaselines)
- [Active Directory Security Best Practices](https://docs.microsoft.com/en-us/windows-server/identity/ad-ds/plan/security-best-practices/best-practices-for-securing-active-directory)
- [PCI DSS v4.0.1 Requirement 8](https://www.pcisecuritystandards.org/)
- [NIST SP 800-53 Rev 5](https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final)
- [Tier Model for Admin Access](https://docs.microsoft.com/en-us/security/privileged-access-workstations/privileged-access-access-model)

---

## 📄 License

These scripts are provided as-is for professional use. Test thoroughly in your environment before production use. No warranty expressed or implied.

---

## 🤝 Contributing

Found a bug? Have an improvement? This toolkit is meant to be adapted to your environment. Fork it, modify it, make it yours.

---

## ✅ Quick Start Checklist

- [ ] Run `Create-NetworkBaseline.ps1` - document current state
- [ ] Run `Export-GPOAudit.ps1` - understand policies
- [ ] Open HTML index, review GPOs
- [ ] Run `Audit-PrivilegedAccess.ps1` - find overpermissioned accounts
- [ ] Review high-risk privileged accounts CSV
- [ ] Run `Find-DormantAccounts.ps1` - identify dormant accounts
- [ ] Review dormant CSV, create reviewed subset
- [ ] Disable dormant accounts with `Disable-DormantAccounts.ps1 -WhatIf`
- [ ] Wait 30-90 days monitoring period
- [ ] Delete with `Delete-DormantAccounts.ps1` after hold period
- [ ] Document everything
- [ ] Schedule quarterly audits

---

**Remember:** These scripts are tools, not magic bullets. The real work is in the analysis, decision-making, and communication. Take your time, be thorough, and don't break production. 🎯
