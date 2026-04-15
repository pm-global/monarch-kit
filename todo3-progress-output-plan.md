# TODO-3: Progress Output with Silent Mode — COMPLETE 2026-04-15

## Problem

The orchestrator runs 25 functions sequentially (`$calls` loop, line 3087) with no user-visible progress. On slower domains this is a blank cursor for over a minute. Admins need to know it's alive, what's running, and what failed.

Additionally, `New-MonarchReport` (7 Write-Host calls) and `Resolve-MonarchDC` (1 Write-Host call) emit narration unconditionally. These need to be controlled by the same verbosity setting.

## Current State

- Orchestrator loop (lines 3087–3096): bare `foreach` with try/catch, zero console output
- `Resolve-MonarchDC` line 136: one unconditional `Write-Host`
- `Invoke-DomainAudit` line 3031: one unconditional `Write-Host`
- `New-MonarchReport` lines 2442, 2459, 2529, 2753, 2906, 2994, 2996: seven unconditional `Write-Host` narration lines
- Individual audit functions: zero `Write-Host` calls — pipeline output is already clean
- `$calls`: 25-element hardcoded array of hashtables (lines 3055–3081), each with `Name`, `Domain`, `Params`
- Failures tracked in `$failures` list (line 3085), `.Function` and `.Error` properties
- Existing tests: `Tests/Monarch.Tests.ps1`, Pester 5, AD cmdlets mocked

## Design Decisions

### Verbosity Levels

`-Verbosity` parameter, default `Info`. Four discrete levels — clearer than combining switches.

| Level | Progress bar | Per-function narration | Failure blocks | OK line |
|-------|-------------|----------------------|----------------|---------|
| `Silent` | No | No | No | No |
| `Error` | Yes | No | Yes | No |
| `Warn` | Yes | No | Yes | Yes |
| `Info` (default) | Yes | Yes | Yes | Yes |

**Rationale:**
- `Info` default: the admin sees everything on first run. Transparency builds trust; this tool runs infrequently on important infrastructure.
- `Warn`: progress bar (alive signal) + failure blocks + completion summary. Good for routine re-runs.
- `Error`: progress bar (not a blank cursor at any non-Silent level) + failure blocks only. For scripts that check the return object.
- `Silent`: zero output. For automation and piping only.

```powershell
[ValidateSet('Silent','Error','Warn','Info')]
[string]$Verbosity = 'Info'
```

### Visual Design

**Audit header** (all non-Silent levels — fires after DC resolution, before loop):
```
                                                               ← one blank line
audit: corp.example.com  ·  DC: dc01.corp.example.com  ·  25 checks
```
Cyan. Uses `$target.Domain`, `$dc`, and `$calls.Count` — all available after resolution. The `·` is a plain center-dot (U+00B7), not a box character.

**Progress bar** (Error, Warn, Info — inside loop):
```powershell
Write-Progress -Activity 'Discovery Audit' `
               -Status "$($call.Name) ($i/$total)" `
               -PercentComplete (($i / $total) * 100)
```
`$total = $calls.Count` set once before the loop. Cleared with `Write-Progress -Activity 'Discovery Audit' -Completed` after the loop.

**Per-function narration** (Info only, before each function call):
```
  audit: Get-FSMORolePlacement...
  audit: Get-ReplicationHealth...
```
DarkGray. Two-space indent. Trailing `...`.

**Inline failure block** (Error, Warn, Info — inside catch):
```
  audit FAILED: Find-LegacyProtocolExposure
    -> WinRM connection failed to DC04
```
Both lines Red. Two-space indent on the `FAILED` line; four-space on the `->` line. Source: `$call.Name` and `$_.Exception.Message`. No fix line — individual check failures have no general-purpose remediation. Arrow style matches preflight-win.ps1 (`->` not `↳`). The progress bar continuing after a red block signals execution didn't stop — no "continuing" annotation needed.

**OK line — clean run** (Warn, Info):
```
audit OK: 25/25 checks (2m 14s)
```
Green. No indent.

**OK line — with failures** (Warn, Info):
```
audit OK: 24/25 checks (2m 14s)
  -> failed: Find-LegacyProtocolExposure
  -> failed: Get-ReplicationHealth
```
First line Green. Each `-> failed:` line Red, two-space indent. One line per entry in `$failures`. The admin sees which checks failed at a glance without opening the report or accessing any variable.

**Timer:** `[System.Diagnostics.Stopwatch]::StartNew()` before the loop. Format: `Xm Ys` if 60+ seconds, `Xs` only if under 60 seconds. Source: `$sw.Elapsed.TotalSeconds`.

**Full Info run — one failure (reference mockup):**
```

audit: corp.example.com  ·  DC: dc01.corp.example.com  ·  25 checks

  audit: resolving domain controller...
  audit: Get-FSMORolePlacement...
  audit: Get-ReplicationHealth...
  audit: Get-SiteTopology...
  ...
  audit FAILED: Find-LegacyProtocolExposure
    -> WinRM connection failed to DC04
  audit: Get-BackupReadinessStatus...
  ...

audit OK: 24/25 checks (2m 14s)
  -> failed: Find-LegacyProtocolExposure
```

### Suppressing Existing Narration

**`Resolve-MonarchDC`:** Suppress its `Write-Host` with `6>$null` at the call site (Information stream redirect — valid PS 5.1+; return value is on stream 1 and unaffected). The orchestrator emits its own narration for that step at Info level:
```powershell
if ($Verbosity -eq 'Info') { Write-Host "  audit: resolving domain controller..." -ForegroundColor DarkGray }
$dc = Resolve-MonarchDC ... 6>$null
```

**`Invoke-DomainAudit` line 3031:** Gate with `if ($Verbosity -notin @('Silent', 'Error'))`.

**`New-MonarchReport`:** Add `-Verbosity` param (same `[ValidateSet]`, default `'Info'`). Wrap all seven Write-Host calls with `if ($Verbosity -eq 'Info')`. Update the call at line 3113 to pass `-Verbosity $Verbosity`.

**Individual audit functions:** No changes — they have zero `Write-Host` calls.

## Scope

- Add `-Verbosity` param to `Invoke-DomainAudit`, default `Info`
- Cyan header line after DC resolution, before loop (all non-Silent)
- `Write-Progress` in loop (Error, Warn, Info)
- Per-function narration in loop (Info only)
- Inline failure blocks in loop (Error, Warn, Info)
- OK line + per-failure list after loop (Warn, Info)
- Stopwatch for duration
- Suppress `Resolve-MonarchDC` output via `6>$null`; add orchestrator narration at Info
- Gate `Invoke-DomainAudit` line 3031 by verbosity
- Thread `-Verbosity` to `New-MonarchReport`; gate its seven `Write-Host` calls

## Out of Scope

- Progress within individual functions
- GUI or web-based indicators
- ETA calculations
- Cascading verbosity into individual audit functions beyond orchestrator + report generator
- VOM spec update — spec is not project-specific; the deviations (no stop-on-failure, `->` arrow style) are documented in code comments

## Implementation

**Model:** Sonnet. **Change budget:** ≤ 120 lines added/changed across `Monarch.psm1` and `Tests/Monarch.Tests.ps1`.

---

### Pass 0 — Tests (write first; all must FAIL before Pass 1)

Add a new `Describe 'Invoke-DomainAudit: Verbosity'` block to `Tests/Monarch.Tests.ps1`.

**Setup (BeforeAll inside the Describe):**

Mock all 25 functions named in `$calls` (lines 3055–3081). Each returns a minimal valid result:
```powershell
$mockResult = [PSCustomObject]@{ Domain = 'test.local'; Function = 'MockFn'; Timestamp = Get-Date; Warnings = @() }
Mock Get-FSMORolePlacement        { $mockResult }
Mock Get-ReplicationHealth        { $mockResult }
Mock Get-SiteTopology             { $mockResult }
Mock Get-ForestDomainLevel        { $mockResult }
Mock Export-GPOAudit              { $mockResult }
Mock Find-UnlinkedGPO             { $mockResult }
Mock Find-GPOPermissionAnomaly    { $mockResult }
Mock Get-PrivilegedGroupMembership{ $mockResult }
Mock Find-AdminCountOrphan        { $mockResult }
Mock Find-KerberoastableAccount   { $mockResult }
Mock Find-ASREPRoastableAccount   { $mockResult }
Mock Find-DormantAccount          { $mockResult }
Mock Get-PasswordPolicyInventory  { $mockResult }
Mock Find-WeakAccountFlag         { $mockResult }
Mock Test-ProtectedUsersGap       { $mockResult }
Mock Find-LegacyProtocolExposure  { $mockResult }
Mock Get-BackupReadinessStatus    { $mockResult }
Mock Test-TombstoneGap            { $mockResult }
Mock Get-AuditPolicyConfiguration { $mockResult }
Mock Get-EventLogConfiguration    { $mockResult }
Mock Test-SRVRecordCompleteness   { $mockResult }
Mock Get-DNSScavengingConfiguration { $mockResult }
Mock Test-ZoneReplicationScope    { $mockResult }
Mock Get-DNSForwarderConfiguration{ $mockResult }
Mock New-DomainBaseline           { $mockResult }
Mock Resolve-MonarchDC            { 'dc01.test.local' }
Mock New-MonarchReport            { 'C:\fake\report.html' }
Mock Write-Host                   { }
Mock Write-Progress               { }
```

All tests run inside `InModuleScope Monarch { ... }`.

**Tests:**

1. `Silent — Write-Host is never called`
   Run `Invoke-DomainAudit -Verbosity Silent`. Assert `Should -Invoke Write-Host -Times 0 -Exactly`.

2. `Silent — Write-Progress is never called`
   Assert `Should -Invoke Write-Progress -Times 0 -Exactly`.

3. `Error — Write-Progress is called`
   Run with `-Verbosity Error`. Assert `Should -Invoke Write-Progress -Times ($calls.Count + 1) -Exactly` (once per function + Completed call). Or assert `-Times ($calls.Count + 1) -AtLeast` if exact count is fragile.

4. `Error — no Green Write-Host (no OK line)`
   Assert no `Write-Host` call had `-ForegroundColor Green`.

5. `Error — failure block written for a failing check`
   Override one mock to throw: `Mock Find-LegacyProtocolExposure { throw 'WinRM failed' }`. Run with `-Verbosity Error`. Assert `Should -Invoke Write-Host -ParameterFilter { $Object -like 'audit FAILED*' }`.

6. `Error — failure block contains exception message`
   Same setup. Assert a `Write-Host` call had `$Object -like '*WinRM failed*'` and `-ForegroundColor Red`.

7. `Warn — OK line written on clean run`
   Run with `-Verbosity Warn`. Assert `Should -Invoke Write-Host -ParameterFilter { $Object -like 'audit OK*' -and $ForegroundColor -eq 'Green' }`.

8. `Warn — OK line lists failed function name when one check fails`
   Mock one function to throw. Run with `-Verbosity Warn`. Assert a Red `Write-Host` call contains `'Find-LegacyProtocolExposure'`.

9. `Info — per-function narration written`
   Run with `-Verbosity Info`. Assert `Should -Invoke Write-Host -ParameterFilter { $Object -like '  audit:*' -and $ForegroundColor -eq 'DarkGray' }`.

10. `Info — Cyan header line written`
    Assert `Should -Invoke Write-Host -ParameterFilter { $ForegroundColor -eq 'Cyan' }`.

11. `Return object intact at all verbosity levels`
    For each level, assert the return value has `TotalChecks -eq 25`, `Failures` is an array, `Dispositions` is an array, `Results` is an array, `ReportPath -eq 'C:\fake\report.html'`.

Verify all tests fail (parameter doesn't exist yet) before proceeding to Pass 1.

---

### Pass 1 — Implement verbosity in Invoke-DomainAudit

All changes in `Monarch.psm1`, orchestrator section only.

**Style note:** Precompute four named booleans once before the loop — do not inline verbosity string comparisons inside the loop body. This makes the verbosity table directly readable in the code:
```powershell
$showHeader    = $Verbosity -ne 'Silent'
$showProgress  = $Verbosity -ne 'Silent'
$showNarration = $Verbosity -eq 'Info'
$showFailures  = $Verbosity -ne 'Silent'
$showOK        = $Verbosity -in @('Warn', 'Info')
```
Then use `if ($showNarration)`, `if ($showProgress)`, etc. throughout.

**Fragility note:** Write-Progress must be written as a single line — no backtick line continuation. Trailing whitespace after a backtick silently breaks the call. If it doesn't fit, use a splat.

1. Add `-Verbosity` param to `Invoke-DomainAudit` with `[ValidateSet]`, default `'Info'`.

2. Gate line 3031 `Write-Host`: wrap with `if ($Verbosity -notin @('Silent', 'Error'))`.

3. Before `$calls` is defined: emit orchestrator's DC resolution narration and suppress `Resolve-MonarchDC`'s own output:
   ```powershell
   if ($Verbosity -eq 'Info') { Write-Host "  audit: resolving domain controller..." -ForegroundColor DarkGray }
   # ... existing Resolve-MonarchDC call gets 6>$null appended
   ```

4. After `$calls` is defined, before loop: emit header + start timer:
   ```powershell
   if ($Verbosity -ne 'Silent') {
       Write-Host ''
       Write-Host "audit: $($target.Domain)  `u{00B7}  DC: $dc  `u{00B7}  $($calls.Count) checks" -ForegroundColor Cyan
   }
   $sw = [System.Diagnostics.Stopwatch]::StartNew()
   $total = $calls.Count
   $i = 0
   ```

5. Inside the loop, before `try`:
   ```powershell
   $i++
   if ($Verbosity -eq 'Info') {
       Write-Host "  audit: $($call.Name)..." -ForegroundColor DarkGray
   }
   if ($Verbosity -ne 'Silent') {
       Write-Progress -Activity 'Discovery Audit' -Status "$($call.Name) ($i/$total)" -PercentComplete (($i / $total) * 100)
   }
   ```

6. Inside `catch`, after adding to `$failures`:
   ```powershell
   if ($Verbosity -ne 'Silent') {
       Write-Host "  audit FAILED: $($call.Name)" -ForegroundColor Red
       Write-Host "    -> $($_.Exception.Message)" -ForegroundColor Red
   }
   ```

7. After loop:
   ```powershell
   if ($Verbosity -ne 'Silent') {
       Write-Progress -Activity 'Discovery Audit' -Completed
   }
   $s = [int]$sw.Elapsed.TotalSeconds
   $dur = if ($s -ge 60) { "$([int]($s / 60))m $($s % 60)s" } else { "${s}s" }

   if ($Verbosity -in @('Warn', 'Info')) {
       $passed = $calls.Count - $failures.Count
       Write-Host "audit OK: $passed/$($calls.Count) checks ($dur)" -ForegroundColor Green
       foreach ($f in $failures) {
           Write-Host "  -> failed: $($f.Function)" -ForegroundColor Red
       }
   }
   ```

---

### Pass 2 — Thread to New-MonarchReport + verify

1. Add `-Verbosity` param to `New-MonarchReport`: `[ValidateSet('Silent','Error','Warn','Info')][string]$Verbosity = 'Info'`.

2. Wrap each of the seven `Write-Host` calls in `New-MonarchReport` with `if ($Verbosity -eq 'Info')`.

3. Update line 3113 to pass the param:
   ```powershell
   $orchestratorResult.ReportPath = New-MonarchReport -Results $orchestratorResult -OutputPath $OutputPath -Verbosity $Verbosity
   ```

4. Run the full test suite. All Pass 0 tests must now pass. No regressions in existing tests.
