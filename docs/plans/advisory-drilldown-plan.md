# Advisory Drilldown Dropdowns — Plan

## Context

The v5 reference (`docs/report-v5-to-be-superseded.html`) — canonical visual spec per `design-system.md:209` — demonstrated `<details>`/`<summary>` drilldowns under specific advisories: replication links, FSMO placement, Domain Admin members. The current Discovery Report (`Monarch.psm1::New-MonarchReport`, 2443+) renders advisories with only count + description. The reader has no on-page way to verify "which 7? which 3?" and must open a CSV (when one exists) or re-run with `-PassThru`.

This plan implements the unimplemented v5 dropdown spec with one tightened rule: dropdowns serve **on-page verification**, not analysis. Analysis is CSV's job. The structured PSCustomObject is the agent's job.

---

## Engineering & Design Decisions

These are settled. Every pass below references this section by number; passes do not re-litigate.

### D1. Drilldown is a verification surface, not an analysis surface
Inline table only when row count fits a quick visual scan. Above that, link to CSV. No truncated tables, no pagination.

### D2. Inline cap = 15 rows; ≥16 rows = CSV link, no dropdown
Threshold sourced from `Monarch-Config.psd1` key `AdvisoryDropdownInlineCap` (default 15). Module init throws if value is not a positive integer — misconfigurations fail loud.

### D3. Never render an empty dropdown
Row count == 0 → no `<details>`. Row count ≥ cap+1 → no `<details>`; CSV link rendered inline within the advisory card. No catfish clicks.

### D4. Extend the existing orchestrator CSV combiner
Five new `Export-Csv` blocks appended after the existing roastable combine at `Monarch.psm1:3162-3190`. Discovery function return contracts stay frozen — CSV synthesis is a reporting concern.

### D5. HTML escape via single helper applied at every value-into-HTML site
Helper `ConvertTo-HtmlSafe` (internal, not exported) wrapping `[System.Net.WebUtility]::HtmlEncode` (PS 5.1 native). Applied at the boundary between data and HTML structure — never to assembled HTML strings (would destroy structural tags) and never input-side validation (rejects legitimate forest data).

### D6. Sort priority per advisory

| Advisory | Sort |
|----------|------|
| Replication links | Status desc (Failed → Warning → Healthy), then Source, Partner |
| FSMO placement | Reachable=false first, then Role |
| Weak account flags | IsPrivileged desc, Flag, SamAccountName |
| Legacy protocol findings | Risk desc (High → Medium → Low), DCName |
| DA members, AdminCount orphans, Kerberoastable, ASREP, ProtectedUsers gaps, Unlinked GPOs | Alpha on first column |

### D7. Sorted column header is bold-weight (700)
Existing header default is 600 (v5 CSS:284). Apply `font-weight: 700` to the sort column's `<th>` via `class='sorted'`. Smallest possible signal. No icon, no color, no underline.

### D8. Drilldown candidate scope
**In scope (dropdown when 1 ≤ count ≤ cap):**
1. Replication links failing/warning — `Get-ReplicationHealth.Links`
2. FSMO unreachable / single-DC placement — `Get-FSMORolePlacement.Roles`
3. Domain Admin count high — `Get-PrivilegedGroupMembership.Groups[DA].Members`
4. Kerberoastable accounts — `Find-KerberoastableAccount.Accounts`
5. AS-REP roastable accounts — `Find-ASREPRoastableAccount.Accounts`
6. AdminCount orphans — `Find-AdminCountOrphan.Orphans`
7. Protected Users gaps — `Test-ProtectedUsersGap.GapAccounts`
8. Unlinked GPOs — `Find-UnlinkedGPO.UnlinkedGPOs`
9. Weak account flags — `Find-WeakAccountFlag.Findings`
10. Legacy protocol findings — `Find-LegacyProtocolExposure.DCFindings`

**Out of scope:** Subnets unassigned, empty sites (single-column, render inline as comma list); Dormant accounts (always high-volume, keep existing CSV link).

### D9. CSV mapping (5 folders total)

| Advisory | CSV path | Source |
|----------|----------|--------|
| Replication links | `01-Baseline/replication-links.csv` | NEW |
| FSMO placement | `01-Baseline/fsmo-roles.csv` | EXISTS |
| DA members | `03-Privileged-Access/privileged-groups.csv` (filter: GroupSID matching `*-512`) | EXISTS |
| Kerberoastable | `03-Privileged-Access/roastable-accounts.csv` (filter: `ThreatType=Kerberoast`) | EXISTS |
| AS-REP | `03-Privileged-Access/roastable-accounts.csv` (filter: `ThreatType=ASREP`) | EXISTS |
| AdminCount orphans | `03-Privileged-Access/admincount-orphans.csv` | EXISTS |
| Protected Users gaps | `05-Security-Posture/protected-users-gaps.csv` | NEW |
| Unlinked GPOs | `02-GPO-Audit/unlinked-gpos.csv` | NEW |
| Weak account flags | `05-Security-Posture/weak-account-flags.csv` | NEW |
| Legacy protocol | `05-Security-Posture/legacy-protocol-findings.csv` | NEW |

Folders: `01-Baseline/`, `02-GPO-Audit/`, `03-Privileged-Access/`, `04-Dormant-Accounts/`, `05-Security-Posture/` (NEW). Total 5.

### D10. Print rendering — CSS-only, no generator changes
PowerShell renders the report exactly once. The browser handles `@media print` at print time. Add to inlined `@media print`:
```css
details > *:not(summary) { display: block !important; }
summary::-webkit-details-marker { display: none; }
summary::marker { display: none; }
```
This forces every `<details>` body visible at print time regardless of `[open]` state. No `$Format` parameter. No generator-side flag. The `design-system.md:194` note about "CSS cannot reliably force-open" refers to the `[open]` attribute; the BODY visibility is just `display`, which IS forceable.

### D11. Adjacency: dropdown directly under its advisory
Drilldown table renders as the last child of `<div class='card w-advisory'>`, after description and DiagnosticHint.

### D12. Helper and column-spec shapes (referenced by passes)

```
ConvertTo-HtmlSafe -Value $any -> [string]
    if $null: returns ''
    else: [System.Net.WebUtility]::HtmlEncode([string]$Value)

Format-AdvisoryDrilldown
    -Rows [array]
    -Columns [array of @{ Header; Property; Sorted=$bool; CssClass }]
    -Cap [int]
    -CsvRelativePath [string|null]
    -SummaryText [string]
    -> [string]   # HTML fragment, '' when no drilldown should render

  Logic:
    if $Rows.Count -eq 0:           return ''
    if $Rows.Count -gt $Cap:        return CSV-link span
    else:                           return <details>...<table>...</table></details>
    Every cell value passes through ConvertTo-HtmlSafe.
    Header for column with Sorted=$true gets class='sorted'.

DrilldownSpec attached to advisories (by build-site code in Pass 6):
    @{
        Rows            = <array of PSCustomObject>
        Columns         = <array of column hashtables, ordered, with one Sorted=$true>
        SummaryText     = '<verb> N <thing> (<breakdown>)'
        CsvRelativePath = '<dir>/<file>.csv' or $null
    }
```

---

## Invariants

1. Empty drilldowns never render.
2. Cap exceeded → CSV link, never truncated table.
3. Every interpolated value passes through `ConvertTo-HtmlSafe` exactly once.
4. Discovery function return contracts unchanged.
5. Sort order per D6 is deterministic.
6. Advisory absence is silence (count == 0 → no card; existing).
7. CSV synthesis failures are non-fatal (Write-Warning + graceful degradation).
8. `AdvisoryDropdownInlineCap` validated at module init (positive integer).
9. Print rendering requires no PowerShell-side flag.
10. The drilldown table is a child of its advisory card.

---

## Implementation Passes

Each pass is an atomic, self-contained unit. Run in order. Each pass references decisions from the section above by number — DO NOT re-derive them.

**Pre-pass setup for every pass:**
- Read `AGENTS.md` for sitemap if needed.
- Read this plan's Engineering Decisions section.
- Do not modify any file outside the pass's listed scope.

---

### PASS 1 — Test Suite (TDD red phase)

**Goal:** Write the full Pester suite for the feature. All new tests must FAIL initially since the implementation lands in passes 2-8.

**Files touched:**
- `tests/Monarch.Tests.ps1` — add new `Describe` block(s) at end of file

**Depends on:** none

**Reuse pointers:**
- Existing test patterns in `tests/Monarch.Tests.ps1` for mock-driven testing
- `Get-MonarchConfigValue` available after module import for cap reading

**Acceptance:**
- New test cases listed below are present and currently failing.
- No existing tests regress.
- Tests assert behavior (HTML structure, sort order, presence/absence), not implementation strings.

**Test cases (one `It` each):**

Group `Describe "Advisory Drilldown — Cap and Empty Cases"`:
1. Count = 0 → no `<details>` element rendered AND no advisory card for that finding (existing invariant — re-assert).
2. Count = 1 → `<details>` rendered, table contains 1 data row.
3. Count = `(Get-MonarchConfigValue 'AdvisoryDropdownInlineCap')` (boundary, on inline path) → `<details>` rendered with all rows.
4. Count = `(Get-MonarchConfigValue 'AdvisoryDropdownInlineCap') + 1` (boundary, on CSV path) → no `<details>`; rendered HTML contains `<a class='csv-link'>` with the matching relative path and the row count in the link text.

Group `Describe "Advisory Drilldown — HTML Escape"`:
5. Mock data with `DisplayName='<script>alert(1)</script>'` → output contains `&lt;script&gt;alert(1)&lt;/script&gt;`. No raw `<script>` from data anywhere.
6. Mock data with `DisplayName='Smith & Co'` → output contains `Smith &amp; Co` exactly. Output does NOT contain `Smith &amp;amp; Co` (double-encode regression).
7. `<div>`, `<table>`, `<th>` structural tags present in output (helper does not encode the structure).

Group `Describe "Advisory Drilldown — Sort"`:
8. Replication links with mixed Failed/Warning/Healthy rows → in output HTML, the row index of the first `Failed` < first `Warning` < first `Healthy`.
9. FSMO with one `Reachable=$false` and four `$true` → unreachable role appears first.
10. The sort column header carries `class='sorted'`. Other headers do not.

Group `Describe "Advisory Drilldown — Print and Adjacency"`:
11. Rendered HTML contains the print-mode CSS rule `details > *:not(summary)` with `display:block`.
12. The `<details>` block for an advisory appears INSIDE the matching `<div class='card w-advisory'>...</div>` (not after it).

Group `Describe "Advisory Drilldown — CSV Synthesis Resilience"`:
13. Simulate `Export-Csv` throwing for one synthesis block → report still generates; corresponding advisory renders without `<details>`; warning emitted via `Write-Warning`.

Group `Describe "Config Validation — AdvisoryDropdownInlineCap"`:
14. Module reimport with `AdvisoryDropdownInlineCap = 'oops'` in config → throws with a message containing the key name and the bad value.
15. Module reimport with `AdvisoryDropdownInlineCap = 0` → throws (not a positive integer).
16. Module reimport with default config → `Get-MonarchConfigValue 'AdvisoryDropdownInlineCap'` returns 15.

**Mocking guidance:**
- Mock the discovery functions to return canned `PSCustomObject` payloads with predictable rows and counts.
- Mock `Export-Csv` for case 13 to throw `[System.IO.IOException]`.
- For HTML inspection, capture the rendered HTML string returned by `New-MonarchReport` (or read from disk) and apply structure-aware assertions (regex with bounded group capture; do NOT do string equality on whole HTML).

---

### PASS 2 — Config Default + Validation

**Goal:** Add the cap config key with a default and a fail-fast validation. Tests 14, 15, 16 from Pass 1 should pass after this pass.

**Files touched:**
- `Monarch.psm1` (`Import-MonarchConfig`, ~line 64-101)
- `Monarch-Config.psd1` (add commented entry under a new `# Reporting` subsection — see existing comment-block style)

**Depends on:** Pass 1 (tests written)

**Acceptance:**
- Default value of `AdvisoryDropdownInlineCap` is 15.
- `Get-MonarchConfigValue 'AdvisoryDropdownInlineCap'` returns the int 15 with a stock config.
- Module reimport throws if a consumer's config sets the key to a non-positive non-integer value.
- Tests 14, 15, 16 pass.

**Implementation steps:**
1. In the defaults hashtable inside `Import-MonarchConfig` (locate near existing `DormancyThresholdDays`, `DomainAdminWarningThreshold`, etc.), add `AdvisoryDropdownInlineCap = 15`.
2. After the merge of consumer config over defaults, add validation:
   ```
   $cap = $script:Config.AdvisoryDropdownInlineCap
   if ($cap -isnot [int] -or $cap -lt 1) {
       throw "AdvisoryDropdownInlineCap must be a positive integer; got: '$cap' (type: $($cap.GetType().Name))"
   }
   ```
3. In `Monarch-Config.psd1`, add a commented section near the existing Reporting accents:
   ```
   # =========================================================================
   # Reporting — Drilldown Behavior
   # =========================================================================

   # Maximum row count for inline advisory drilldown tables. Counts above
   # this threshold render a CSV link instead of an inline table. Must be
   # a positive integer.
   # AdvisoryDropdownInlineCap = 15
   ```

---

### PASS 3 — Helpers (`ConvertTo-HtmlSafe` + `Format-AdvisoryDrilldown`)

**Goal:** Add the two internal helpers. Tests 5, 6, 7, 10 (escape + sorted-class behavior of `Format-AdvisoryDrilldown` in isolation) become testable directly.

**Files touched:**
- `Monarch.psm1` — add helpers near the top of the script alongside other utility functions (suggest: just after `Get-MonarchConfigValue` at ~line 102)

**Depends on:** Pass 2

**Reuse pointers:**
- `[System.Net.WebUtility]::HtmlEncode` (PS 5.1 native, no dependency)
- v5 CSS reference (`docs/report-v5-to-be-superseded.html:255-310`) for the visual reference — no CSS in this pass, just the helper that produces matching markup

**Acceptance:**
- `ConvertTo-HtmlSafe $null` returns `''`.
- `ConvertTo-HtmlSafe 'foo & <bar>'` returns `'foo &amp; &lt;bar&gt;'`.
- `ConvertTo-HtmlSafe (ConvertTo-HtmlSafe 'A & B')` returns `'A &amp;amp; B'` (idempotency is the caller's responsibility, not the helper's — this is documented behavior, not a bug).
- `Format-AdvisoryDrilldown` returns `''` for empty rows.
- `Format-AdvisoryDrilldown` returns a `<a class='csv-link'>...</a>` span when `Rows.Count > Cap` and CsvRelativePath is set.
- `Format-AdvisoryDrilldown` returns a `<details>...</details>` block when `1 <= Rows.Count <= Cap`.
- The header for the column with `Sorted=$true` carries `class='sorted'`.
- All cell values are run through `ConvertTo-HtmlSafe` before insertion.

**Implementation steps:**
1. Add `ConvertTo-HtmlSafe` per D12 shape. Single function, no extra logic. Internal (not in the manifest's exported function list — confirm `Monarch.psd1` does not auto-export by wildcard; if it does, narrow the export list).
2. Add `Format-AdvisoryDrilldown` per D12 shape:
   - Empty: return `''`.
   - Overflow: return `"<a class='csv-link' href='$([System.Web.HttpUtility]::UrlPathEncode... NO — use simple path)'>Full list ($($Rows.Count) rows): $(Split-Path $CsvRelativePath -Leaf)</a>"`. Use a simple href = `$CsvRelativePath` (paths are file-system safe, no special escape needed for the values we control).
   - Inline: build `<details>` with `<summary>$SummaryText</summary>` followed by `<table>` with `<thead>` (apply `class='sorted'` on the matching `<th>`) and `<tbody>` rows. Each `<td>` value passes through `ConvertTo-HtmlSafe`.
3. Do NOT export the helpers via `Export-ModuleMember` or the manifest. They are internal.

---

### PASS 4 — CSV Combiner Extension + New Output Directory

**Goal:** Extend the existing orchestrator CSV combiner with 5 new writes per D9. Add `05-Security-Posture/` to the `Invoke-DomainAudit` directory hashtable.

**Files touched:**
- `Monarch.psm1` (`Invoke-DomainAudit` `$dirs` hashtable at ~line 3079; CSV combiner at ~line 3162-3190)

**Depends on:** Pass 3 not strictly required; can run in parallel with Pass 3.

**Reuse pointers:**
- Existing roastable combine pattern at `Monarch.psm1:3162-3190` — copy-shape for each new block
- Existing `New-Item -ItemType Directory` pattern at `:3085`

**Acceptance:**
- After running `Invoke-DomainAudit -Phase Discovery -OutputPath ./test-out` against any populated lab, these files exist with correct rows:
  - `./test-out/01-Baseline/replication-links.csv` (columns: SourceDC, PartnerDC, Partition, LastSuccess, LastAttempt, ConsecutiveFailures, Status)
  - `./test-out/02-GPO-Audit/unlinked-gpos.csv` (columns: DisplayName, Id, CreatedTime, ModifiedTime, Owner)
  - `./test-out/05-Security-Posture/protected-users-gaps.csv` (columns: SamAccountName, PrivilegedGroups, HasSPN; PrivilegedGroups joined with `; `)
  - `./test-out/05-Security-Posture/weak-account-flags.csv` (columns: SamAccountName, DisplayName, Flag, IsPrivileged, Enabled)
  - `./test-out/05-Security-Posture/legacy-protocol-findings.csv` (columns: DCName, Finding, Risk — match the actual `DCFindings[]` shape; verify by reading `Find-LegacyProtocolExposure` return)
- A synthesis failure on any one block is wrapped in try/catch with `Write-Warning`; report generation still completes.
- `$dirs.Security` is created if missing.

**Implementation steps:**
1. In `$dirs` (line ~3079-3084), add `Security = Join-Path $OutputPath '05-Security-Posture'`. The existing `foreach ($d in $dirs.Values)` loop already creates each.
2. After the existing roastable write at `:3186`, append 5 try/catch blocks. Pattern for each:
   ```
   try {
       $r = $results | Where-Object { $_.Function -eq '<FunctionName>' } | Select-Object -First 1
       if ($r) {
           $rows = @($r.<ArrayProp>) | ForEach-Object { [PSCustomObject]@{ <flat columns> } }
           if ($rows.Count -gt 0) {
               $rows | Export-Csv -Path (Join-Path $dirs.<Bucket> '<filename>.csv') -NoTypeInformation
           }
       }
   } catch {
       Write-Warning "<advisory> CSV synthesis failed: $_"
   }
   ```
3. Each block's specifics:
   - **Replication links:** Function `Get-ReplicationHealth`, prop `Links`, bucket `Baseline`, file `replication-links.csv`. Flatten directly (already PSCustomObject-shaped).
   - **Protected Users gaps:** Function `Test-ProtectedUsersGap`, prop `GapAccounts`. Flatten with `PrivilegedGroups = ($_.PrivilegedGroups -join '; ')`. Bucket `Security`, file `protected-users-gaps.csv`.
   - **Weak account flags:** Function `Find-WeakAccountFlag`, prop `Findings`. Flatten direct. Bucket `Security`, file `weak-account-flags.csv`.
   - **Legacy protocol findings:** Function `Find-LegacyProtocolExposure`, prop `DCFindings`. **Verify the actual property name and shape by reading the function around line 1614 before implementing.** Bucket `Security`, file `legacy-protocol-findings.csv`.
   - **Unlinked GPOs:** Function `Find-UnlinkedGPO`, prop `UnlinkedGPOs`. Flatten direct. Bucket `GPO`, file `unlinked-gpos.csv`.

---

### PASS 5 — CSS Additions

**Goal:** Extend the inlined CSS string in `New-MonarchReport` with v5's drilldown rules + new `.sorted`/`.csv-link` rules + print-mode rules.

**Files touched:**
- `Monarch.psm1` (`$css` string concatenation at ~line 2692-2745)

**Depends on:** none structurally; can run independently. Test 11 from Pass 1 passes after this.

**Reuse pointers:**
- v5 reference CSS at `docs/report-v5-to-be-superseded.html:255-310` — copy verbatim into the inlined string

**Acceptance:**
- The output HTML's inlined `<style>` block contains: `details {`, `summary {`, `details table {`, `details th {`, `details td {`, `details td.wrap-ok {`, `.status-healthy {`, `.status-warning {`, `.status-failed {`, `details th.sorted {`, `.csv-link {`, and inside `@media print { ... details > *:not(summary) { display: block !important; } summary::-webkit-details-marker { display: none; } summary::marker { display: none; } ... }`.
- Test 11 passes.
- No existing CSS rules removed or altered.

**Implementation steps:**
1. Locate the `$css` string at `Monarch.psm1:2692-2745`.
2. Append (concatenation, not replacement) the v5 rules from `docs/report-v5-to-be-superseded.html:255-310`. Preserve the v5 CSS exactly — do not refactor variable names.
3. Append the new rules:
   ```
   details th.sorted{font-weight:700}
   .csv-link{color:var(--accent-primary);font-size:var(--t5);text-decoration:none}
   .csv-link:hover{text-decoration:underline}
   ```
4. Within the existing `@media print { ... }` block, append:
   ```
   details > *:not(summary){display:block !important}
   summary::-webkit-details-marker{display:none}
   summary::marker{display:none}
   ```
5. Maintain the existing one-line/concatenated style of the `$css` variable (no prettification — bytes matter for embedded report).

---

### PASS 6 — Advisory Build-Site Enrichment (Attach DrilldownSpec)

**Goal:** Where each in-scope advisory is BUILT (the `$advisories.Add(...)` and `$criticals.Add(...)` calls between `Monarch.psm1:2559-2680`), attach a `DrilldownSpec` hashtable. Out-of-scope advisories pass `$null` (unchanged).

**Files touched:**
- `Monarch.psm1` (advisory build sites, ~lines 2559-2680)

**Depends on:** Pass 4 (knows the CSV file paths to point at)

**Reuse pointers:**
- Each advisory's source data is available via `$r` in the build loop (the per-function result PSCustomObject).
- Discovery function return shapes — reference points:
  - Replication: `Get-ReplicationHealth` returns `Links[]` with `SourceDC`, `PartnerDC`, `Partition`, `LastSuccess`, `Status` etc. (`Monarch.psm1:558-608`)
  - FSMO: `Get-FSMORolePlacement` returns `Roles[]` with `Role`, `Holder`, `Reachable`, `Site` (`:340-346`)
  - DA members: `Get-PrivilegedGroupMembership` returns `Groups[]` each with `Members[]` of `SamAccountName`, `DisplayName`, `ObjectType`, `IsDirect`, `IsEnabled`, `LastLogon` (`:818-825`); filter `Groups | Where GroupSID -like '*-512'`.
  - Kerberoastable: `Find-KerberoastableAccount.Accounts[]` with `SamAccountName`, `DisplayName`, `SPNs`, `IsPrivileged`, `PasswordAgeDays`, `Enabled` (`:985-992`)
  - AS-REP: `Find-ASREPRoastableAccount.Accounts[]` with `SamAccountName`, `DisplayName`, `IsPrivileged`, `Enabled` (`:1046-1051`)
  - AdminCount orphans: `Find-AdminCountOrphan.Orphans[]` with `SamAccountName`, `DisplayName`, `Enabled`, `MemberOf` (`:915-920`)
  - ProtectedUsers gaps: `Test-ProtectedUsersGap.GapAccounts[]` with `SamAccountName`, `PrivilegedGroups`, `HasSPN` (`:1577-1581`)
  - Unlinked GPOs: `Find-UnlinkedGPO.UnlinkedGPOs[]` with `DisplayName`, `Id`, `CreatedTime`, `ModifiedTime`, `Owner` (`:1094-1100`)
  - Weak flags: `Find-WeakAccountFlag.Findings[]` with `SamAccountName`, `DisplayName`, `Flag`, `IsPrivileged`, `Enabled` (`:1451-1457`)
  - Legacy protocol: `Find-LegacyProtocolExposure.DCFindings[]` — **read the function at ~1614 to confirm shape** before implementing.

**Acceptance:**
- For each in-scope advisory category in D8, the advisory hashtable now includes a `DrilldownSpec = @{ Rows; Columns; SummaryText; CsvRelativePath }` property.
- `Rows` is sorted per D6.
- One column in `Columns` has `Sorted=$true`, matching D6.
- `CsvRelativePath` matches D9.
- `SummaryText` follows the v5 example: `View N <thing> (<breakdown>)`.
- Out-of-scope advisories have NO `DrilldownSpec` property (or `$null`).

**Implementation steps:**
1. For each in-scope advisory in the build loop, add `DrilldownSpec` to the `[PSCustomObject]@{}` literal already being added to `$advisories` or `$criticals`. Sort `Rows` inline using `Sort-Object` with the D6 priority (multi-key sorts: use a hashtable expression like `@{ Expression = { ... }; Descending = $true }`).
2. Define `Columns` as an array of hashtables, ordered for display. Mark exactly one with `Sorted=$true` per D6.
3. Compute `SummaryText` from the row count and any breakdown counts already in `$r` (e.g., `$r.HealthyLinkCount`, `$r.WarningLinkCount`, `$r.FailedLinkCount` for replication).
4. Set `CsvRelativePath` from D9. Use forward-slash separator (cross-OS-friendly in browsers).

**Per-advisory column spec (concrete, drop-in):**

| Advisory | Columns (Header, Property, Sorted) | Sort priority |
|----------|------------------------------------|---------------|
| Replication links | Source/SourceDC/false; Partner/PartnerDC/false; Partition/Partition/false; Status/Status/true; LastSuccess/LastSuccess/false | Status desc (Failed→Warning→Healthy), then SourceDC, PartnerDC |
| FSMO placement | Role/Role/false; Holder/Holder/false; Site/Site/false; Reachable/Reachable/true | Reachable=$false first, then Role |
| DA members | Account/SamAccountName/true; Display Name/DisplayName/false; Type/ObjectType/false; Direct/IsDirect/false; Last Logon/LastLogon/false | Alpha SamAccountName |
| Kerberoastable | Account/SamAccountName/true; Display Name/DisplayName/false; Privileged/IsPrivileged/false; Pwd Age (d)/PasswordAgeDays/false; Enabled/Enabled/false | Alpha SamAccountName |
| AS-REP | Account/SamAccountName/true; Display Name/DisplayName/false; Privileged/IsPrivileged/false; Enabled/Enabled/false | Alpha SamAccountName |
| AdminCount orphans | Account/SamAccountName/true; Display Name/DisplayName/false; Enabled/Enabled/false | Alpha SamAccountName |
| ProtectedUsers gaps | Account/SamAccountName/true; Privileged Groups/PrivilegedGroups/false; Has SPN/HasSPN/false | Alpha SamAccountName |
| Unlinked GPOs | Display Name/DisplayName/true; Created/CreatedTime/false; Modified/ModifiedTime/false; Owner/Owner/false | Alpha DisplayName |
| Weak flags | Account/SamAccountName/false; Display Name/DisplayName/false; Flag/Flag/false; Privileged/IsPrivileged/true | IsPrivileged desc, Flag, SamAccountName |
| Legacy protocol | DC/DCName/false; Finding/Finding/false; Risk/Risk/true | Risk desc (High→Medium→Low), DCName |

For boolean and joined fields, format inline:
- `IsDirect` / `IsPrivileged` / `Enabled` / `HasSPN` / `Reachable`: render `'Yes'` / `'No'`
- `PrivilegedGroups` (array): render `($v -join '; ')`
- `LastLogon` / `CreatedTime` / `ModifiedTime`: render via existing date-display convention (check repo for existing pattern; default `.ToString('yyyy-MM-dd')` if unsure)
- `Status` ∈ {Healthy, Warning, Failed}: wrap value in `<span class='status-healthy/warning/failed'>` via the column's optional `CssClass` lambda

---

### PASS 7 — Advisory Render Loop + In-Loop Escape Application

**Goal:** Modify the advisory render loop to call `Format-AdvisoryDrilldown` and apply `ConvertTo-HtmlSafe` to the values it interpolates. Tests 1, 2, 3, 4, 8, 9, 12, 13 should pass after this.

**Files touched:**
- `Monarch.psm1` (`New-MonarchReport`, advisory render loop at ~lines 2895-2899)

**Depends on:** Passes 3, 5, 6

**Acceptance:**
- The advisory loop produces card markup of the shape:
  ```
  <div class='card w-advisory'>
    <div class='adv-label'>Advisory</div>
    <div class='description'>$descSafe</div>
    [optional: <div class='diagnostic-hint'>$hintSafe</div> ...]
    [optional: <details>...</details> OR <a class='csv-link'>...</a>]
  </div>
  ```
- All values inside the advisory loop pass through `ConvertTo-HtmlSafe`.
- An advisory without a `DrilldownSpec` renders identically to today (no drilldown markup).
- Tests 1, 2, 3, 4, 8, 9, 12, 13 pass.

**Implementation steps:**
1. Replace the existing advisory loop body (`:2895-2899`) with:
   ```
   foreach ($a in $domainAdvisories) {
       $descSafe = ConvertTo-HtmlSafe $a.Description
       $hintHtml = (@($a | Select-Object -ExpandProperty DiagnosticHint -ErrorAction SilentlyContinue) `
                   | Where-Object { $_ } `
                   | ForEach-Object { "<div class='diagnostic-hint'>$(ConvertTo-HtmlSafe $_)</div>" }) -join ''
       $drillHtml = ''
       if ($a.PSObject.Properties['DrilldownSpec'] -and $a.DrilldownSpec) {
           $drillHtml = Format-AdvisoryDrilldown @($a.DrilldownSpec) -Cap $cap
       }
       $html += "<div class='card w-advisory'><div class='adv-label'>Advisory</div><div class='description'>$descSafe</div>$hintHtml$drillHtml</div>"
   }
   ```
2. `$cap` is read once at the top of `New-MonarchReport` via `Get-MonarchConfigValue 'AdvisoryDropdownInlineCap'`.
3. Update the splat call: `Format-AdvisoryDrilldown @($a.DrilldownSpec) -Cap $cap` — verify splat syntax matches PowerShell expectations for hashtable splatting (use `@spec` form: `Format-AdvisoryDrilldown @spec -Cap $cap` where `$spec = $a.DrilldownSpec`).

---

### PASS 8 — HTML Escape Coverage Sweep

**Goal:** Apply `ConvertTo-HtmlSafe` to every remaining value-into-HTML site in `New-MonarchReport`. Test 5, 6, 7 should already pass post-Pass 7 for the advisory loop; this pass extends coverage to all other sites.

**Files touched:**
- `Monarch.psm1` (`New-MonarchReport`, all interpolation sites — domain headings, metric values, file-tree entries, critical findings, function errors, footer, title, metadata)

**Depends on:** Pass 3, Pass 7

**Acceptance:**
- Every `"...$value..."` site in `New-MonarchReport` where `$value` came from any `$results` PSCustomObject, file path, or external string passes through `ConvertTo-HtmlSafe`.
- Static string concatenations (literal HTML structure, fixed labels) are NOT wrapped — they don't carry untrusted data.
- Test 7 (structural tags survive) passes.
- Existing report's visual output is unchanged for safe data (no double-encoding regression).

**Implementation steps:**
1. Walk `New-MonarchReport` start-to-finish. For each `$html += "...$x..."` or equivalent, ask: "does `$x` originate from external data?" If yes, wrap: `$(ConvertTo-HtmlSafe $x)`.
2. Specific sites known to need wrapping (non-exhaustive — auditor must walk the full function):
   - Title: `$($r.Domain)` and the report-title interpolations
   - Metadata: DC name, timestamp string
   - Critical findings card: `Description`, domain tag, diagnostic hints
   - Domain headings: `$dn` (display domain name)
   - Domain metrics: every `$()` interpolation
   - `clean-domains` line
   - `failures-section` / `not-assessed` cards: `$na.Function`, `$na.Error`
   - File tree: filenames and folder names (already from disk — wrap defensively)
   - Footer: version string, generation timestamp
3. Do NOT wrap CSS class names, URL paths inside the file tree's `href` (those are file-system paths under our control), or static structural text.

**Auditor's checklist after sweep:**
- [ ] `grep -n '"\$' Monarch.psm1 | grep -i 'class\|<' ` shows no unwrapped value-in-attribute or value-in-text positions inside `New-MonarchReport`.
- [ ] No `Format-Html` call in the static parts (would double-encode the structural HTML).

---

### PASS 9 — Verification + Cleanup

**Goal:** Run the test suite and an end-to-end report against a populated lab. Resolve any failures.

**Files touched:** none (verification only). Any fix triggered here is a bug in a prior pass — go back and fix it there.

**Depends on:** all prior passes

**Acceptance:**
- `Invoke-Pester ./tests/Monarch.Tests.ps1 -Output Detailed` — all tests pass (existing + 16 new from Pass 1).
- `Invoke-DomainAudit -Phase Discovery -OutputPath ./test-out` against a populated lab produces:
  - All 5 NEW CSV files per D9 with sane row counts.
  - HTML report with drilldowns for advisories that have ≤15 rows; CSV-link spans for advisories with ≥16 rows.
  - No advisory card with an empty drilldown anywhere.
  - Sorted column header is visibly bolder.
  - Browser print preview shows all `<details>` bodies expanded; no disclosure triangles on paper.
- `grep '<script>' ./test-out/00-Discovery-Report.html` returns only legitimate occurrences (none from data injection).

**Verification steps:**
1. `Invoke-Pester ./tests/Monarch.Tests.ps1 -Output Detailed`. Fix failures in their originating passes.
2. Run audit against BadBlood or production-like lab.
3. Inspect output tree — confirm 5 folders only.
4. Open HTML report — confirm visual checks above.
5. Browser → File → Print preview — confirm all dropdown bodies visible.
6. Misconfigure: edit `Monarch-Config.psd1`, set `AdvisoryDropdownInlineCap = 'oops'`, reimport. Confirm clear error. Restore.
7. Misconfigure to a small cap (`= 2`): rerun audit; confirm DA / Replication advisories with 3+ rows now render the CSV-link path.

---

## Operational Constraints

- **Replication "Failed" status:** Render the value as returned by `Get-ReplicationHealth.Links[].Status`. No interpretation, no scoring, no annotation. Drilldown is a verification surface, not a diagnostic surface.
- **Protected Users gaps with HasSPN:** Keep the existing `DiagnosticHint` rendered ABOVE the drilldown. Adding a service account to Protected Users disables Kerberos delegation and breaks NTLM — the warning must not be buried under the table.

---

## Critical files (consolidated)

- `Monarch.psm1` — touched in passes 2, 3, 4, 5, 6, 7, 8
- `Monarch-Config.psd1` — touched in pass 2
- `tests/Monarch.Tests.ps1` — touched in pass 1

## Existing utilities reused

- `Get-MonarchConfigValue` (`Monarch.psm1:102`)
- Existing post-loop CSV combiner (`Monarch.psm1:3162-3190`)
- File-tree disk scanner (`Monarch.psm1:2929+`) — auto-picks-up new CSVs
- v5 `<details>` / `<summary>` CSS spec (`docs/report-v5-to-be-superseded.html:255-310`)
- `[System.Net.WebUtility]::HtmlEncode` (PS 5.1 native)
