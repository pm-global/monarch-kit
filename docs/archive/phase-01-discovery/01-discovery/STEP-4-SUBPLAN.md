# Step 4 Subplan: New-DomainBaseline

First API function. Sets the pattern for all subsequent functions. Four passes — each ships working code with tests. No pass is pure scaffolding.

**Dev-guide checkpoints applied:** Code budget, completion over expansion, guards at boundaries, inline mocks (no factory abstraction), test behavior not implementation.

**Current state:** Infrastructure-to-feature ratio is ∞:0 (config system, DC resolver, 33-function manifest, zero working API functions). This step shifts the ratio. Prioritize working code.

---

## Pass 1: Function + Shape Tests

Write the function and its core tests in one pass. The function works end-to-end against mocks before this pass is done.

- [x] **AD cmdlet stubs in test file** — define empty `function script:CmdletName {}` stubs inside module scope for every AD cmdlet `New-DomainBaseline` calls, then mock with `Mock -ModuleName Monarch`. Use the same per-`Context` pattern already established in `Resolve-MonarchDC` tests. No mock factory, no `$mockData` hashtable — inline mocks are simpler and the test file already proves the pattern works.

  Cmdlets to stub and mock (10):

  | Cmdlet | Populates |
  |--------|-----------|
  | `Get-ADDomain` | DomainDNSRoot, DomainNetBIOS, DomainFunctionalLevel, FSMO (partial) |
  | `Get-ADForest` | ForestName, ForestFunctionalLevel, FSMO (partial) |
  | `Get-ADObject` | SchemaVersion (`objectVersion` on `CN=Schema,CN=Configuration`) |
  | `Get-ADDomainController` | DomainControllers array |
  | `Get-ADReplicationSite` | SiteCount |
  | `Get-ADOrganizationalUnit` | OUCount |
  | `Get-ADUser` | UserCount (Total + Enabled — two calls or filter) |
  | `Get-ADComputer` | ComputerCount (Total + Enabled) |
  | `Get-ADGroup` | GroupCount |
  | `Get-ADDefaultDomainPasswordPolicy` | PasswordPolicy |

- [x] **`New-DomainBaseline` function** in `#region Audit and Compliance` (Monarch.psm1 lines 179–182). Full implementation, not a skeleton. Seven `try/catch` sections, CSV export, return contract — all in one pass.

  Code-budget target: ~100–120 lines. Core logic per section is 2–5 lines (call cmdlet, assign properties). The `try/catch` wrapper and `-Server` splatting are the only structural overhead.

  Implementation details:

  - **Server splatting:** Build `$splatAD = if ($Server) { @{ Server = $Server } } else { @{} }` once at the top, pass to every AD cmdlet. Guard at the boundary, not per-call.
  - **Warnings accumulator:** `$warnings = [System.Collections.Generic.List[string]]::new()` — initialized once, converted to `@($warnings)` in the return object.
  - **Section independence:** Each section assigns to result variables directly. If section 1 (Domain/Forest) fails, section 3 (FSMO) checks `$domainInfo`/`$forestInfo` for `$null` before accessing properties — adds its own warning and moves on. This is the only cross-section dependency.
  - **CSV export block:** Single block at the end, after all data gathering. Only runs when `-OutputPath` is provided. Only exports sections that succeeded (`if ($domainControllers)`). Creates output directory if missing.

  Seven sections (matches v0 minus DNS/DHCP/Replication which belong to other domains):

  | # | Section | Cmdlets | Properties populated |
  |---|---------|---------|---------------------|
  | 1 | Domain & Forest | `Get-ADDomain`, `Get-ADForest` | DomainDNSRoot, DomainNetBIOS, DomainFunctionalLevel, ForestName, ForestFunctionalLevel |
  | 2 | Schema Version | `Get-ADObject` | SchemaVersion |
  | 3 | FSMO Roles | *(uses section 1 results)* | FSMORoles sub-object |
  | 4 | Domain Controllers | `Get-ADDomainController -Filter *` | DomainControllers array |
  | 5 | Sites | `Get-ADReplicationSite -Filter *` | SiteCount |
  | 6 | OUs & Object Counts | `Get-ADOrganizationalUnit`, `Get-ADUser`, `Get-ADComputer`, `Get-ADGroup` | OUCount, UserCount, ComputerCount, GroupCount |
  | 7 | Password Policy | `Get-ADDefaultDomainPasswordPolicy` | PasswordPolicy |

  CSVs exported when `-OutputPath` provided:

  | File | Source | Why this one earns its place |
  |------|--------|------------------------------|
  | `domain-info.csv` | Domain/forest/schema (flat) | Single-row reference doc, trivial to diff between audit cycles |
  | `domain-controllers.csv` | DomainControllers array | Most-reviewed artifact — admins compare DC inventory across audits |
  | `fsmo-roles.csv` | FSMORoles sub-object | Separate because FSMO placement is its own review item |
  | `object-counts.csv` | User/computer/group counts | Trend tracking across audit cycles |
  | `password-policy.csv` | PasswordPolicy | Compliance artifact — auditors ask for this by name |

  All five serve the audit review workflow (the human gate between Discovery and Remediation). The return object is for programmatic consumers; CSVs are for human reviewers and compliance evidence. Different consumers, not redundant.

- [x] **Tests: shape and metadata** (one `Describe 'New-DomainBaseline'` block with a default `Context` where all mocks succeed)
  - Return object has all 19 required properties (single `It` with loop over property names)
  - `Domain` equals `'AuditCompliance'`
  - `Function` equals `'New-DomainBaseline'`
  - `Timestamp` is populated and within 60 seconds of now
  - `Warnings` is an array (even when empty)
  - `DomainControllers` is an array with correct sub-properties (HostName, Site, OS, IPv4, IsGC, IsRODC)
  - `FSMORoles` has all five role properties
  - `UserCount` has Total and Enabled sub-properties
  - `Server` passthrough: call with `-Server 'DC01.test.local'`, assert `Assert-MockCalled Get-ADDomain -ParameterFilter { $Server -eq 'DC01.test.local' }` — validates the splatting pattern works. One `It`, multiple assertions.

**Pass 1 exit criteria:** Function returns fully-populated object. All shape tests pass. ~10 tests.

**Pass 1 result:** 11 new tests, 36 total, all green. Dropped `Should -Invoke` call-count assertions — Pester 5 mock invocation tracking doesn't work across `Describe`/`Context` scope boundaries with `-ModuleName` mocks on stubs. Value-based tests prove the mocks are called.

---

## Pass 2: Resilience Tests

The pattern that matters most. Every subsequent function copies this.

- [x] **Tests: partial failure** (new `Context` blocks where specific mocks throw)
  - Domain/Forest section fails → `DomainDNSRoot` is `$null`, `DomainControllers` still populated, `Warnings` contains the error text
  - Domain/Forest failure cascades to FSMO gracefully → `FSMORoles` is `$null`, `Warnings` mentions both sections (not an unhandled null reference)
  - DC query fails → `UserCount` still populated, `DomainControllers` is `$null`
  - Multiple sections fail → `Warnings.Count` matches failure count, surviving sections still populated
  - Total failure (all cmdlets throw) → function still returns the contract shape (Domain, Function, Timestamp present), `Warnings` is fully populated, no unhandled exception

**Pass 2 exit criteria:** 5 resilience tests passing. Partial failure pattern is proven and copyable.

**Pass 2 result:** 9 new tests across 4 Contexts (Domain/Forest fails, DC fails, multiple fail, total failure). 45 total, all green.

---

## Pass 3: CSV Export Tests

- [x] **Tests: output file behavior** (new `Context` blocks using `$TestDrive`)
  - With `-OutputPath $TestDrive`: CSV files exist on disk, `OutputFiles` lists their paths
  - Without `-OutputPath`: `OutputFiles` is empty array, no files written
  - Output directory created if it doesn't exist
  - Partial section failure → CSVs for successful sections exist, failed section's CSV absent, `OutputFiles` only lists files that were actually written

**Pass 3 exit criteria:** 4 CSV tests passing.

**Pass 3 result:** 7 new tests across 3 Contexts (with OutputPath, without OutputPath, partial failure + OutputPath). 52 total, all green.

---

## Pass 4: Full Suite Verification

- [x] **Run all tests (Steps 1–4)** — verify no regressions
  - Steps 1–3 tests still pass (module load, config, DC resolution)
  - All Step 4 tests pass
  - Expected total: ~44 tests (25 existing + ~19 new)
- [x] **Check diagnostics** — no warnings or errors in `.psm1`
- [x] **Verify `FunctionsToExport`** — `New-DomainBaseline` is already listed in `Monarch.psd1` (confirmed present)
- [x] **Verify function placement** — lives in `#region Audit and Compliance`

**Pass 4 exit criteria:** Full green suite. First working API function shipped. Infrastructure-to-feature ratio is now finite.

**Pass 4 result:** 52 tests total (25 prior + 27 new), all green. Zero diagnostics on `.psm1`. Function exported at `Monarch.psd1` line 52, placed in `#region Audit and Compliance`. Also applied defensive `-Filter '*'` quoting on 6 AD cmdlet calls. Step 4 complete.

---

## V0 Reference Notes

`Create-NetworkBaseline.ps1` is the source material. Key things to carry forward and key things to drop:

**Carry forward:**
- Section-by-section `try/catch` resilience (v0 used `$ErrorActionPreference = 'Continue'`; monarch-kit uses explicit `try/catch` per section — same resilience, structured and testable)
- Per-section CSV export (proven useful in audit workflows)
- The specific AD cmdlets and properties queried (battle-tested against real domains)

**Drop:**
- Text report generation (`Add-Report` pattern) — the return object IS the structured output
- `$ErrorActionPreference = 'Continue'` at function scope — explicit `try/catch` is clearer
- DNS zones section — belongs to DNS domain functions (Step 12)
- Replication health section — belongs to Infrastructure Health (Step 5)
- "Handover" terminology — use "audit cycle" / "audit phase"
- `Start-Process $ReportPath` — consumer decides presentation

**Add (not in v0):**
- Schema version (`objectVersion` on `CN=Schema,CN=Configuration`)
- Structured return contract with Domain/Function/Timestamp/Warnings
- `-Server` parameter for DC targeting
- `OutputFiles` tracking array

---

## Dev-Guide Compliance Notes

| Principle | How applied |
|-----------|-------------|
| Code budget | ~100–120 line target. Core logic per section is 2–5 lines. No helper functions for one caller. |
| Completion over expansion | Four passes, each ships working code. No pure-scaffolding passes. |
| Guards at boundaries | `-Server` splatting built once at function top. `$warnings` initialized once. |
| Abstraction justification | No mock factory — inline per-Context mocks match existing test patterns. |
| Infrastructure-to-feature ratio | This step produces the first working API function. Noted explicitly. |
| Test behavior not implementation | Tests check return shape and values, not which internal variables exist. |
| TDD applies | Contract is defined in CLAUDE-DEV-PLAN.md. Tests verify the contract. |
| Silence is success | Function returns objects. No Write-Host. Warnings only on failure. |