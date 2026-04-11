# TODO-1: Surface DiagnosticHints in Report Cards

## Goal

Four discovery functions already emit `DiagnosticHint` / `DiagnosticHints`
strings that describe the finding with numbers and mechanics. The report
layer currently drops them. Plumb them through so they appear on the cards.

Nothing more. No new functions, no new fields, no companion concepts.

## In scope

| Function | Field on result | Feeds | Current state |
|---|---|---|---|
| `Get-BackupReadinessStatus` | `DiagnosticHint` (string) | critical | dropped at extraction |
| `Get-ReplicationHealth` | `DiagnosticHints` (list) | critical | dropped at extraction |
| `Test-ProtectedUsersGap` | `DiagnosticHint` (string) | advisory | dropped at extraction |
| `Test-TombstoneGap` | `DiagnosticHint` (string) | *nothing today* | orchestrator wiring broken + no extraction branch |

## What's broken

1. **Extraction drops the hint on 3 of 4 paths.** The switch in
   `New-MonarchReport` (L2560–2689) constructs new critical/advisory
   `[PSCustomObject]@{ Domain; DisplayDomain; Description }` objects and
   never copies `DiagnosticHint` from the source result.

2. **`Test-TombstoneGap` has no extraction case at all.** The function
   runs as part of orchestration (`Monarch.psm1:3099`) and produces a
   populated result, but the extraction switch has no `'Test-TombstoneGap'`
   branch. Its entire result is discarded.

3. **`Test-TombstoneGap` is called with no `BackupAgeDays`.** The
   orchestrator at L3099 passes only `Server`, so in every real run the
   function falls through to its "Backup age not provided" stub hint and
   the real USN-rollback hint never fires. The age it needs is produced
   by `Get-BackupReadinessStatus` (Tier 3 only) as `LastBackupAge` and
   is available in `$results` by the time TombstoneGap is about to run.

4. **Report-layer test mocks explicitly null the field.** At least five
   sites in `Tests/Monarch.Tests.ps1` set `DiagnosticHint = $null` when
   constructing fake results, which will make any flow-through assertion
   fail until they carry real strings.

## Work items

### 1. Wire `BackupAgeDays` in the orchestrator loop

`Monarch.psm1` foreach loop at L3112. Before invoking `Test-TombstoneGap`,
look up the already-completed `Get-BackupReadinessStatus` result from
`$results`. If its `LastBackupAge` (TimeSpan) is non-null, inject
`BackupAgeDays = [int]$prior.LastBackupAge.TotalDays` into the call's
params. If null (Tiers 1–2, the common case), leave the call alone — the
"Backup age not provided" stub is accurate when no age was detected.

Expected change: ~5 lines inside the existing loop. No new function, no
new infrastructure.

### 2. Add the four extraction-layer forwards

`New-MonarchReport` switch at L2560–2689. One small change per branch:

- **`Get-BackupReadinessStatus`** (L2562) — add `DiagnosticHint = $r.DiagnosticHint` to the critical object.
- **`Get-ReplicationHealth`** (L2566) — add `DiagnosticHint = $r.DiagnosticHints` to the critical object. Forward as a list (see rendering).
- **`Test-ProtectedUsersGap`** (L2604) — add `DiagnosticHint = $r.DiagnosticHint` to the advisory object.
- **`Test-TombstoneGap`** — *new case*. When `$r.CriticalGap -eq $true`, emit a critical with `Description = 'Backup age exceeds tombstone lifetime (USN rollback risk)'` (verbatim match to the `Get-BackupReadinessStatus` critical so TODO-5's dedupe collapse is mechanical) and `DiagnosticHint = $r.DiagnosticHint`. When `CriticalGap` is `$null` (no age supplied), emit nothing — the stub is not a finding.

### 3. Rendering

The card rendering code currently has an orphan hint class
(`.card .action-hint` at L2719, possibly also an `advisory-hint` variant
elsewhere). Work:

- Rename whatever orphan hint class(es) exist to `.card .diagnostic-hint`.
- Confirm **both** critical and advisory card paths emit the hint div
  when the critical/advisory object has a non-null `DiagnosticHint`. If
  one of the paths doesn't emit yet, add the emit — same class, same
  shape.
- For a scalar `DiagnosticHint`: one `<div class="diagnostic-hint">` with
  the text.
- For a list (only `Get-ReplicationHealth` today): one `<div
  class="diagnostic-hint">` per entry, so each per-DC-pair diagnosis
  renders on its own line.
- CSS: the one existing rule at L2719 gets the selector rename and
  nothing else. No new rules, no new layout.

### 4. Test updates

**Keep as-is — all unit tests on the 4 emitters:**
- `Get-ReplicationHealth` DiagnosticHints list assertions (L1270–1299)
- `Test-ProtectedUsersGap` DiagnosticHint content (L1669–1672)
- `Get-BackupReadinessStatus` Tier-3 USN rollback hint (L3205–3207)
- `Test-TombstoneGap` standalone calculator tests (L3212–3247)

These test the function layer and the function layer is fine. Do not
touch them.

**Update report-layer mocks:**
- `Tests/Monarch.Tests.ps1:4782–4783` — `Test-TombstoneGap` mock: add
  `DiagnosticHint` with a real USN-rollback string, `CriticalGap = $true`,
  `BackupAgeDays = 200`, so the new extraction branch fires.
- `Tests/Monarch.Tests.ps1:5259, 5306, 5332, 5368` — four
  `Test-ProtectedUsersGap` mocks currently set `DiagnosticHint = $null`;
  replace with real strings in the function's actual output format
  (mentioning "service account" and "delegation", matching the existing
  unit-test assertions).

**Add flow-through assertions** — one per path, four total:
For each of the 4 functions, mock the source to return a result with a
known `DiagnosticHint`, call `New-MonarchReport`, assert the rendered
HTML contains the hint text and the `.diagnostic-hint` class. For
`Get-ReplicationHealth`, assert each list entry appears on its own line.

## Out of scope (deferred, not abandoned)

- **Duplicate critical card** when `Test-TombstoneGap` and
  `Get-BackupReadinessStatus` both fire a critical for the same Tier-3
  gap. Both will produce cards under this plan. The dedupe is filed in
  TODO-5 alongside other hint cleanups.
- **Advisory-path rendering for functions that don't emit
  `DiagnosticHint` today.** Not this plan.
- **Orphan-field tooling** (TODO-5).
- Anything named ActionHint, Tools, or Search. Dead.

## Definition of done

- All four emitters' hints reach their card in the rendered HTML.
- `Test-TombstoneGap` in a real orchestrator run receives `BackupAgeDays`
  when Tier 3 produced an age, and produces the stub hint when it didn't.
- CSS class is `diagnostic-hint`, no lingering `action-hint` or
  `advisory-hint` selectors.
- Existing unit tests still pass unchanged.
- New flow-through assertions pass for all four paths.
