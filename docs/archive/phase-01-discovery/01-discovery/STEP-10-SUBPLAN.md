# Step 10 Subplan: Backup & Recovery

Two functions in the `BackupReadiness` domain. `Get-BackupReadinessStatus` is the canonical example of graduated confidence — three detection tiers, each adding more detail. `Test-TombstoneGap` is a lightweight standalone comparator. No v0 reference — built from scratch per domain-specs and mechanism-decisions.

**Dev-guide checkpoints applied:** Code budget, completion over expansion, guards at boundaries, test behavior not implementation, one function one job, max 2 nesting levels.

**Current state:** 18 working API functions, 126 tests passing. This step adds 2 more functions.

**V0 reference:** None. No backup-related scripts in `.v0/`.

**Key mechanism decision:** Three-tier graduated confidence model per `docs/mechanism-decisions.md` lines 136–193. Tier 1 always runs (tombstone + recycle bin). Tier 2 is best-effort (WSB + vendor service enumeration). Tier 3 is opt-in via `BackupIntegration` config. If backup age is null, gap detection silently skips — never throw on missing data.

---

## Pass 1: Get-BackupReadinessStatus (Tier 1 + Tier 2)

### 10a. Get-BackupReadinessStatus (Tier 1 + 2)

- [x] **`Get-BackupReadinessStatus` function (Tier 1 + 2)** in `#region Backup and Recovery`
- [x] **Tests: Get-BackupReadinessStatus (Tier 1 + 2)** (~4 tests)
  - Tier 1 only (no backup tool) → DetectionTier=1, Status='Unknown'
  - Tier 2 with Veeam service → DetectionTier=2, BackupToolDetected='Veeam'
  - Tombstone defaults to 180 when attribute null
  - RecycleBin false when EnabledScopes empty

**Pass 1 exit criteria:** Function returns correct objects at Tiers 1 and 2. ~4 tests passing.

---

## Pass 2: Tier 3 + Test-TombstoneGap + Remaining Tests

### 10b. Tier 3 vendor integration

- [x] **Add Tier 3 to Get-BackupReadinessStatus** (~15–20 additional lines)

### 10c. Test-TombstoneGap

- [x] **`Test-TombstoneGap` function** in `#region Backup and Recovery`

### 10d. Remaining tests

- [x] **Tests: Tier 3 + critical gap** (~2 tests)
  - Tier 3 with backup age within tombstone → CriticalGap=$false, Status='Healthy'
  - Tier 3 with backup age exceeding tombstone → CriticalGap=$true, Status='Degraded'
- [x] **Tests: Test-TombstoneGap** (~3 tests)
  - BackupAgeDays=100, tombstone=180 → CriticalGap=$false
  - BackupAgeDays=200, tombstone=180 → CriticalGap=$true
  - BackupAgeDays omitted → CriticalGap=$null

**Pass 2 exit criteria:** Full Tier 3 dispatch, Test-TombstoneGap working. ~5 additional tests passing.

---

## Pass 3: Full Suite Verification

- [x] **Run all tests (Steps 1–10)** — verify no regressions
  - Steps 1–9 tests still pass (126 existing)
  - All Step 10 tests pass (9 new)
  - Total: 135 tests, 0 failures
- [x] **Check diagnostics** — no warnings or errors in `.psm1`
- [x] **Verify `FunctionsToExport`** — both functions listed in `Monarch.psd1`
- [x] **Verify function placement** — both live in `#region Backup and Recovery` (lines 1655, 1779)

**Pass 3 exit criteria:** Full green suite. 20 working API functions total.

---

## New Cmdlets to Stub

| Cmdlet | Used by | Stub signature |
|--------|---------|---------------|
| `Get-ADRootDSE` | Both functions | `param([string]$Server)` |
| `Get-ADOptionalFeature` | Get-BackupReadinessStatus | `param([string]$Filter, [string]$Server)` |
| `Get-Service` | Get-BackupReadinessStatus | `param([string[]]$Name, [string]$ComputerName, [string]$ErrorAction)` |
| `Get-ADObject` | Both functions | Already stubbed, use `-Identity` for DN lookup |

---

## Dev-Guide Compliance Notes

| Principle | How applied |
|-----------|-------------|
| Code budget | Get-BackupReadinessStatus ~55–65 lines (justified — 3 tiers). Test-TombstoneGap ~20 lines. |
| Completion over expansion | Two implementation passes. Pass 1 ships Tier 1+2 with 4 tests. Pass 2 adds Tier 3 + Test-TombstoneGap + 5 tests. |
| Guards at boundaries | Per-tier try/catch. Per-vendor try/catch in service enumeration. |
| Test behavior not implementation | Tests check DetectionTier, Status, CriticalGap. No assertions on internal variables. |
| One function one job | Get-BackupReadinessStatus does full readiness assessment. Test-TombstoneGap is standalone gap comparison. |
| Max 2 nesting levels | Vendor enumeration: foreach vendor { try/catch } = 1 level. |
| Config access | KnownBackupServices and BackupIntegration via Get-MonarchConfigValue. |
| Graduated confidence | Three tiers, each adding detail. Partial info reduces blast radius. |
