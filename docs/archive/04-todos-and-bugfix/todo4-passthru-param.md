# TODO-4 — `-PassThru` for `Invoke-DomainAudit` (v0.5.1-beta) ✓ completed 2026-04-15

## Context

`Invoke-DomainAudit` (Monarch.psm1:3039–3217) unconditionally returns its rich result object. In interactive use the unassigned return goes to `Out-Default`, dumping diagnostic text after the clean `audit OK:` line — including the auto-restart path inside `preflight-win.ps1 -AndMonarch` (preflight-win.ps1:144).

Fix: add `-PassThru` switch; return the object only when requested. Default = clean console.

This is v0.5.1-beta. No external users → no deprecation; break the contract cleanly. Tests are written/updated **first**; module code changes only after the test pass is committed and red.

## Scope

- `Monarch.psm1` — add `-PassThru` switch, gate `return $orchestratorResult`
- `Tests/Monarch.Tests.ps1` — update **13 test sites** (not 2 as originally claimed) + 2 new regression tests
- `README.md` — Quick Start example + version banner
- `Monarch.psd1` — bump `ModuleVersion` `0.2.0` → `0.5.1` (manifest was out of sync with README)

---

## Pass 1 — Tests first (RED)

### 1a. Two new regression tests

In `Describe 'Invoke-DomainAudit: Verbosity'` (Tests/Monarch.Tests.ps1:5945), at end of block:

```powershell
It 'No -PassThru — function emits nothing to the pipeline' {
    InModuleScope Monarch {
        $out = Invoke-DomainAudit -Phase Discovery -Verbosity Silent -OutputPath $TestDrive
        $out | Should -BeNullOrEmpty
    }
}

It '-PassThru — return object is emitted' {
    InModuleScope Monarch {
        $out = Invoke-DomainAudit -Phase Discovery -Verbosity Silent -PassThru -OutputPath $TestDrive
        $out                          | Should -Not -BeNullOrEmpty
        $out.TotalChecks              | Should -Be 25
        $out.PSObject.Properties.Name | Should -Contain 'Failures'
    }
}
```

### 1b. Update existing tests that capture the return value

Add `-PassThru` at every site that assigns the return:

| Line | Pattern |
|------|---------|
| 5564 | `$script:result = Invoke-DomainAudit -Phase Discovery -OutputPath $script:outDir` |
| 5594 | same |
| 5612 | same |
| 5641 | same |
| 5705 | same |
| 5766 | same |
| 5807 | same |
| 5841 | same |
| 5874 | same |
| 6063 | `$r = Invoke-DomainAudit -Phase Discovery -Verbosity Silent -OutputPath $TestDrive` |
| 6074 | `$r = Invoke-DomainAudit -Phase Discovery -Verbosity Info -OutputPath $TestDrive` |

Edit: insert `-PassThru` before `-OutputPath` on each.

Unassigned call sites (5662, 5935, 5990, 5997, 6004, 6011, 6019, 6027, 6034, 6042, 6049, 6056) require **no change** — they don't depend on return value.

### 1c. Run the suite — confirm RED

```powershell
Invoke-Pester ./Tests/Monarch.Tests.ps1 -Output Detailed
```

Expected: 2 new tests fail (no `-PassThru` param exists) and all 11 updated tests fail (`-PassThru` is an unknown parameter → `CmdletBinding` rejects). Record baseline count.

---

## Pass 2 — Module code (GREEN)

### 2a. Add the switch — `Monarch.psm1:3059`

In `param()` block, after `-Verbosity`:

```powershell
[switch]$PassThru
```

### 2b. Gate the return — `Monarch.psm1:3216`

```powershell
# before
return $orchestratorResult

# after
if ($PassThru) { return $orchestratorResult }
```

### 2c. Run the suite — confirm GREEN

All previously-failing tests now pass. No new failures. Total = prior + 2.

---

## Pass 3 — Docs & version bump

### 3a. `README.md:32–36` — Quick Start

Replace:

```powershell
$result = Invoke-DomainAudit -Phase Discovery
```

with:

```powershell
# interactive — clean console, follow the report path on the OK line
Invoke-DomainAudit -Phase Discovery

# automation — capture findings, failures, dispositions
$result = Invoke-DomainAudit -Phase Discovery -PassThru
```

Delete the "Assigning to `$result` is the recommended form…" sentence (line 36).

### 3b. Version bump — update everywhere

Only two files carry a version string (verified via `grep`):

| File | Line | Current | New |
|------|------|---------|-----|
| `Monarch.psd1` | 4 | `ModuleVersion     = '0.2.0'` | `ModuleVersion     = '0.5.1'` |
| `README.md`   | 5 | `**v0.5.0-beta** — Discovery phase complete (28 functions, 344 tests).` | `**v0.5.1-beta** — Discovery phase complete (28 functions, 346 tests).` |

Note: the test count bumps from 344 → 346 because Pass 1 adds two new regression tests to `Describe 'Invoke-DomainAudit: Verbosity'`.

### 3c. Sweep for stale orchestrator-return doc claims

```powershell
Select-String -Path docs\*.md,CLAUDE-DEV-PLAN.md -Pattern 'Invoke-DomainAudit'
```

If any doc promises unconditional return of the orchestrator object, fix. (Likely none outside README.)

---

## Verification

1. **Tests:** `Invoke-Pester ./Tests/Monarch.Tests.ps1 -Output Detailed` — all green, count = prior + 2.
2. **Interactive smoke (Windows host):** `Invoke-DomainAudit -Phase Discovery` — console ends at `audit OK:` line, no object dump.
3. **Automation smoke:** `$r = Invoke-DomainAudit -Phase Discovery -PassThru; $r.TotalChecks` returns `25`.
4. **Preflight restart path:** trigger module-hash mismatch, confirm restart shell ends cleanly with no dump.
5. **Manifest:** `(Import-PowerShellDataFile .\Monarch.psd1).ModuleVersion` returns `0.5.1`.
6. **README banner:** line 5 reads `**v0.5.1-beta**`.

## Critical files

- `Monarch.psm1` (lines 3059, 3216)
- `Tests/Monarch.Tests.ps1` (11 edits + 2 new tests in `Describe 'Invoke-DomainAudit: Verbosity'`)
- `README.md` (lines 5, 32–36)
- `Monarch.psd1` (line 4)

## Change budget

~25 lines across 4 files.
