Contents:
  - Section 1 — twelve D-fix entries ready to fold into drilldown plan's D-section. Each: repo facts, locked decision,
  rationale.
  - Section 2 — Pass 1 test updates (test 8 rewrite + four new tests for CssClass / Format / sort-by-rank).
  - Section 3 — roastable Option C extracted as separate-plan material; build pattern, severity rule, CSV unchanged, sequencing
  note.
  - Critical files + verification.

  Keystone is D-fix-5 (Format/CssClass contract) — D-fix-2/4/6 depend on it.

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Ready to code?

 Here is Claude's plan:
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Advisory Drilldown Plan — Outstanding Engineering Decisions + Roastable Refactor (Findings)

 ▎ Status: Findings document. Intended destination: docs/raw/advisory-drilldown-plan-gaps.md (user will relocate). Two scopes
 ▎ inside:
 ▎ 1. Engineering decisions still missing from docs/plans/advisory-drilldown-plan.md — fold back into Engineering Decisions
 ▎ section.
 ▎ 2. Optional separate plan: roastable advisory consolidation (Option C). Extract to its own future plan; do not bundle into
 ▎ drilldown plan.

 ---
 Context

 docs/plans/advisory-drilldown-plan.md was committed with the Reviewer Findings section removed (stale info). On re-read,
 twelve concrete engineering decisions remain implicit. Implementer would have to make them ad-hoc, violating CONTRIBUTING.md's
  "all engineering decisions made in this file" rule. This document records each decision with grounded suggestion + rationale,
  ready for fold-back into the plan's D-section. Roastable consolidation is broken out separately because it's a fundamental
 advisory model change beyond the drilldown scope.

 Repo facts cited use Monarch.psm1:<line> notation. All citations verified against working tree at master.

 ---
 Section 1 — Engineering decisions to fold into existing plan

 D-fix-1. Find-LegacyProtocolExposure column shape

 Repo fact (Monarch.psm1:1648-1675): DCFindings[] rows have FOUR properties: DCName, Finding, Value, Risk. Plan's current Pass
 4/Pass 6 list three (drops Value).

 Decision: include Value.

 - Pass 4 CSV columns: DCName, Finding, Value, Risk.
 - Pass 6 column spec: DC/DCName/false; Finding/Finding/false; Value/Value/false; Risk/Risk/true (4 columns).
 - Value column gets CssClass = 'wrap-ok' — registry strings are long.

 Rationale: Value carries the actual registry reading ("LmCompatibilityLevel=2"). Without it, drilldown reader sees
 "NTLMv1Enabled, High" and must log into DC to confirm. Drilldown is verification surface — make it self-contained.

 ---
 D-fix-2. Date format strings + null handling

 Repo fact (Monarch.psm1:2485, 3014): existing convention 'MMMM d, yyyy HH:mm' is used only for header timestamps. Tabular
 dates have no precedent.

 Decision:
 - Time-relevant dates (LastSuccess, LastAttempt, LastLogon): .ToString('yyyy-MM-dd HH:mm').
 - Calendar-only dates (CreatedTime, ModifiedTime): .ToString('yyyy-MM-dd').
 - Null/MinValue handling:
   - LastLogon, LastSuccess, LastAttempt → 'Never' (security signal — never logged on, replication never succeeded).
   - CreatedTime, ModifiedTime → '--' (factual absence; ASCII per project rule, no em dash).

 Rationale: ISO-style sorts correctly when browser/eye scans columns. Existing header format 'MMMM d, yyyy HH:mm' doesn't sort
 alpha-correctly (April < January). Header context is single value, doesn't need sort. Table cells do.

 Project rule: ASCII only — no em dashes anywhere. Use -- (two hyphens).

 ---
 D-fix-3. Format-AdvisoryDrilldown call form

 Decision: explicit parameter binding, NOT splat.

 $drillHtml = ''
 if ($a.PSObject.Properties['DrilldownSpec'] -and $a.DrilldownSpec) {
     $spec = $a.DrilldownSpec
     $drillHtml = Format-AdvisoryDrilldown `
         -Rows            $spec.Rows `
         -Columns         $spec.Columns `
         -Cap             $cap `
         -CsvRelativePath $spec.CsvRelativePath `
         -SummaryText     $spec.SummaryText
 }

 Rationale:
 - $a.DrilldownSpec is hashtable on PSCustomObject. @var splat needs bare name. Forces two lines ($spec = ...; @spec). No win.
 - Splat hides parameter names in render loop — read often, write once.
 - -Cap added at call site. Splat couples spec shape to param list (would need -Cap not in spec to avoid duplicate-binding
 errors). Binding decouples cleanly.
 - Pass 7 step 1 currently shows Format-AdvisoryDrilldown @($a.DrilldownSpec) -Cap $cap (array sub-expression — different from
 splat). Step 3 then adds "verify splat syntax". Both wrong. Replace with form above. Drop step 3 entirely.

 ---
 D-fix-4. Status/Risk rank maps — sort uses ordinal, render uses string

 Repo facts:
 - Status values: 'Healthy', 'Warning', 'Failed' (Monarch.psm1:543-557).
 - Risk values: 'High', 'Medium', 'Low' (:1652, :1663, :1674 — Low not currently emitted, future-proof).

 Decision: module-scope rank constants drive Sort-Object -Expression. Display always reads property string.

 # Add near Get-MonarchConfigValue:
 $script:StatusRank = @{ 'Failed' = 0; 'Warning' = 1; 'Healthy' = 2 }
 $script:RiskRank   = @{ 'High'   = 0; 'Medium'  = 1; 'Low'     = 2 }

 Sort expressions per advisory (replaces vague "use a hashtable expression like..." in Pass 6 step 1):

 ┌────────────────────────────────────────────────────┬────────────────────────────────────────────────────────────────────┐
 │                      Advisory                      │                       Sort-Object expression                       │
 ├────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────┤
 │ Replication links                                  │ @{ Expression = { $script:StatusRank[$_.Status] } }, SourceDC,     │
 │                                                    │ PartnerDC                                                          │
 ├────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────┤
 │ FSMO placement                                     │ @{ Expression = { -not $_.Reachable }; Descending = $true }, Role  │
 ├────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────┤
 │ Weak account flags                                 │ @{ Expression = 'IsPrivileged'; Descending = $true }, Flag,        │
 │                                                    │ SamAccountName                                                     │
 ├────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────┤
 │ Legacy protocol                                    │ @{ Expression = { $script:RiskRank[$_.Risk] } }, DCName            │
 ├────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────┤
 │ DA / Kerberoastable / AS-REP / AdminCount /        │ SamAccountName                                                     │
 │ ProtectedUsers                                     │                                                                    │
 ├────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────┤
 │ Unlinked GPOs                                      │ DisplayName                                                        │
 └────────────────────────────────────────────────────┴────────────────────────────────────────────────────────────────────┘

 Rationale: Naive Sort-Object Status -Descending gives Warning, Healthy, Failed (alphabetical desc). Wrong. Risk: Medium, Low,
 High desc. Wrong. Rank-map dictionary lookup is the standard PowerShell idiom for ordered-categorical sort.

 Display rule (lock into D6): "Rank maps drive Sort-Object Expression only. Cell values render via column Property (or Format
 scriptblock) — always the original string. HTML report shows Failed, never 0."

 Audit fix in same pass: D6 currently says replication secondary sort is "Source, Partner". Properties are SourceDC, PartnerDC
 (:560-561). Rewrite using property names.

 ---
 D-fix-5. Column property contract: Format + CssClass scriptblocks/strings

 Design system reference (docs/design-system.md:147, 151):
 - .wrap-ok — opt-in cell wrapping for long content (DisplayName, etc.). Already in design system.
 - .status-healthy / .status-warning / .status-failed — already specified design primitives. v5 CSS at
 docs/report-v5-to-be-superseded.html:308-310 defines them. Pass 5 brings them in via verbatim v5 copy. Not new.

 "Lambda" terminology — switch to "scriptblock" in plan text. PowerShell name. Cross-language meaning is "inline anonymous
 function — code passed as data" (same idea as x => ... in C#/JS). Used here to carry per-cell rendering behavior alongside
 structural column metadata.

 Decision: two optional column properties, separate concerns:

 ┌──────────┬─────────────────────────────────┬─────────────────────────────────┬───────────────────────┐
 │ Property │              Type               │             Purpose             │        Default        │
 ├──────────┼─────────────────────────────────┼─────────────────────────────────┼───────────────────────┤
 │ Format   │ scriptblock or absent           │ returns display string for cell │ $_.<Property>         │
 ├──────────┼─────────────────────────────────┼─────────────────────────────────┼───────────────────────┤
 │ CssClass │ scriptblock OR string OR absent │ returns class string for <td>   │ no class attr emitted │
 └──────────┴─────────────────────────────────┴─────────────────────────────────┴───────────────────────┘

 Format always scriptblock when present. Receives row via $_.

 CssClass accepts both:
 - String form for static per-column class (e.g. CssClass = 'wrap-ok' on DisplayName columns).
 - Scriptblock form for per-row variation (e.g. CssClass = { "status-$($_.Status.ToLower())" }).

 Helper rendering logic:
 foreach ($col in $Columns) {
     $val = if ($col.Format) { & $col.Format } else { $row.($col.Property) }
     $cls = if ($col.CssClass -is [scriptblock]) { & $col.CssClass }
            else { [string]$col.CssClass }
     $clsAttr = if ($cls) { " class='$cls'" } else { '' }
     $cells += "<td$clsAttr>$(ConvertTo-HtmlSafe $val)</td>"
 }

 Why two separate properties (not one merged):
 - 5+ columns need Format only (dates, bools, joined arrays). Wrapping every Format-only column in hashtable to express
 Class=$null is noise.
 - 2+ columns need CssClass only (DisplayName, Value — both static 'wrap-ok').
 - 1 column (Status) needs both. Worth one extra property to keep the other 7+ clean.
 - Single Responsibility per property: troubleshoot Status color → look at CssClass; troubleshoot Last Logon format → look at
 Format. Merged single lambda would surface both bugs in same property, requiring more reading.

 Why CssClass is necessary even if Status color got dropped: wrap-ok (already in design system) needs a delivery mechanism.
 Without CssClass, helper would special-case "is this DisplayName? apply wrap-ok" — couples helper to advisory shape.

 What red signals:
 - Strict info content: zero. Word "Failed" carries the meaning. Color is redundant.
 - What's lost without color: scan speed for skim-readers. Reader of 10-row Replication table sees red dots first. Without
 color, every row reads at same weight.
 - Accessibility: color-only forbidden under WCAG. Color + word ("Failed") is fine — additive.
 - Design-system mandate: docs/design-system.md:151 explicitly specifies these classes. Plan should honor.

 Locked column hashtable shape (replaces D12):
 @{
     Header   = 'Status'                                       # required: display header text
     Property = 'Status'                                       # required: source property on row
     Sorted   = $false                                         # required: bool, exactly one column has $true
     Format   = { ... }                                        # optional: scriptblock returning display string
     CssClass = 'wrap-ok' | { "status-$($_.Status.ToLower())" } # optional: string OR scriptblock returning class
 }

 ---
 D-fix-6. Drilldown row filter per advisory

 Decision per advisory:

 ┌─────────────────┬───────────────────────────────────┬───────────────────────┬─────────────────────────────────────────┐
 │    Advisory     │           Source on $r            │        Filter         │                Rationale                │
 ├─────────────────┼───────────────────────────────────┼───────────────────────┼─────────────────────────────────────────┤
 │                 │                                   │ Where-Object {        │ Healthy is noise on verification        │
 │ Replication     │ $r.Links                          │ $_.Status -ne         │ surface; advisory only fires when       │
 │                 │                                   │ 'Healthy' }           │ Failed/Warning exist                    │
 ├─────────────────┼───────────────────────────────────┼───────────────────────┼─────────────────────────────────────────┤
 │ FSMO placement  │ $r.Roles                          │ none — show all 5     │ Both triggers (unreachable, single-DC)  │
 │                 │                                   │                       │ need full role table for verification   │
 ├─────────────────┼───────────────────────────────────┼───────────────────────┼─────────────────────────────────────────┤
 │                 │ ($r.Groups | Where GroupSID -like │                       │                                         │
 │ DA members      │  '*-512' | Select -First          │ none                  │ Whole point is "which members?"         │
 │                 │ 1).Members                        │                       │                                         │
 ├─────────────────┼───────────────────────────────────┼───────────────────────┼─────────────────────────────────────────┤
 │ Kerberoastable  │ $r.Accounts                       │ none                  │ Source already filtered                 │
 ├─────────────────┼───────────────────────────────────┼───────────────────────┼─────────────────────────────────────────┤
 │ AS-REP          │ $r.Accounts                       │ none                  │ Source already filtered                 │
 ├─────────────────┼───────────────────────────────────┼───────────────────────┼─────────────────────────────────────────┤
 │ AdminCount      │ $r.Orphans                        │ none                  │ Source already filtered                 │
 │ orphans         │                                   │                       │                                         │
 ├─────────────────┼───────────────────────────────────┼───────────────────────┼─────────────────────────────────────────┤
 │ ProtectedUsers  │ $r.GapAccounts                    │ none                  │ Source already filtered                 │
 │ gaps            │                                   │                       │                                         │
 ├─────────────────┼───────────────────────────────────┼───────────────────────┼─────────────────────────────────────────┤
 │ Unlinked GPOs   │ $r.UnlinkedGPOs                   │ none                  │ Source already filtered                 │
 ├─────────────────┼───────────────────────────────────┼───────────────────────┼─────────────────────────────────────────┤
 │ Weak account    │ $r.Findings                       │ none                  │ Source already filtered                 │
 │ flags           │                                   │                       │                                         │
 ├─────────────────┼───────────────────────────────────┼───────────────────────┼─────────────────────────────────────────┤
 │ Legacy protocol │ $r.DCFindings                     │ none                  │ Source already filtered to              │
 │                 │                                   │                       │ non-compliant                           │
 └─────────────────┴───────────────────────────────────┴───────────────────────┴─────────────────────────────────────────┘

 Pass 1 test 8 update. Plan currently:

 ▎ Replication links with mixed Failed/Warning/Healthy rows → in output HTML, the row index of the first Failed < first Warning
 ▎  < first Healthy.

 Replace with:

 ▎ Replication links with mixed Failed/Warning/Healthy mock input → output HTML contains Failed and Warning rows but NO Healthy
 ▎  rows. Among rendered rows, first Failed appears before first Warning.

 Single test asserts both filter (Healthy absent) and sort (Failed before Warning).

 ---
 D-fix-7. Manifest export policy — already explicit

 Repo fact (Monarch.psd1:14-63): FunctionsToExport is explicit allow-list. Comment line 14: # Explicit function exports -- no
 wildcards.

 Decision: helpers stay private by absence. Bake into Pass 3 step 1, drop "verify" note:

 ▎ Add ConvertTo-HtmlSafe and Format-AdvisoryDrilldown per D12. Do not add either to Monarch.psd1 FunctionsToExport. Do not
 ▎ call Export-ModuleMember for them. Manifest uses explicit allow-list (Monarch.psd1:14) — absence from list = private.

 ---
 D-fix-8. Sort secondary keys use property names, not display names

 D6 phrase "Source, Partner" → SourceDC, PartnerDC (already covered in D-fix-4 Replication row). Audit pass complete: only
 Replication has the mismatch; other advisory secondary keys (DCName, Role, SamAccountName, Flag, DisplayName) are property
 names already.

 ---
 D-fix-9. SummaryText template per advisory

 Bake one literal per advisory (replaces vague "follows the v5 example" in Pass 6 step 3):

 ┌────────────────────┬────────────────────────────────────────────────────────────────────────────────────────────────────┐
 │      Advisory      │                                        SummaryText template                                        │
 ├────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Replication        │ "View $($rows.Count) replication links ($($r.FailedLinkCount) failed, $($r.WarningLinkCount)       │
 │                    │ warning)"                                                                                          │
 ├────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ FSMO placement     │ "View $($r.Roles.Count) FSMO roles ($($r.UnreachableCount) unreachable)"                           │
 ├────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ DA members         │ "View $($rows.Count) Domain Admin members"                                                         │
 ├────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Kerberoastable     │ "View $($r.Count) kerberoastable accounts ($($r.PrivilegedCount) privileged)"                      │
 ├────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ AS-REP             │ "View $($r.Count) AS-REP accounts ($privCount privileged)" (privCount computed inline as in :2607) │
 ├────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ AdminCount orphans │ "View $($r.Count) AdminCount orphans"                                                              │
 ├────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ ProtectedUsers     │ "View $($r.GapAccounts.Count) accounts not in Protected Users"                                     │
 │ gaps               │                                                                                                    │
 ├────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Unlinked GPOs      │ "View $($rows.Count) unlinked GPOs"                                                                │
 ├────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Weak account flags │ "View $($r.Findings.Count) weak-flag accounts"                                                     │
 ├────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Legacy protocol    │ "View $($rows.Count) legacy protocol findings ($highRisk high, $medRisk medium)"                   │
 └────────────────────┴────────────────────────────────────────────────────────────────────────────────────────────────────┘

 $rows.Count differs from $r.<count> only when filter applied (Replication only). Whole template gets ConvertTo-HtmlSafe once
 at render — no-op for integers + literals, consistent.

 ---
 D-fix-10. CSV-link text format — locked, ASCII

 Bake into Pass 3 step 2 (overflow path of Format-AdvisoryDrilldown):
 "<a class='csv-link' href='$CsvRelativePath'>View all $($Rows.Count) -- open $(Split-Path $CsvRelativePath -Leaf)</a>"

 Notes:
 - "View all N" matches <summary> "View N ..." pattern from D-fix-9 — same verb, same shape.
 - Two ASCII hyphens -- separate count and filename. No em dash (project rule).
 - href is relative path verbatim (paths are constructed by us per D9; no user data).

 Test 4 assertion target: link text must contain row count integer AND Split-Path -Leaf of CsvRelativePath. Both anchored.

 ---
 D-fix-11. CSV synthesis failure decoupled from link rendering

 Decision (Option 1): CSV link presence is decoupled from CSV file existence at render time.

 - Pass 4 try/catch already emits Write-Warning on synthesis failure. That is the audit trail.
 - Render helper does not Test-Path — boundary violation (mixes filesystem state into render).
 - Failure → broken link in report. Cost low: relative path, reader sees filename, can navigate output folder.
 - Information-loss alternative (suppress link entirely) is worse: removes the only path to data for the most-likely-needed
 CSVs (the overflow ones).

 Bake into Invariants section as #11: "CSV link presence is decoupled from CSV file existence at render time. Synthesis failure
  produces a broken link; the corresponding Write-Warning is the audit trail."

 ---
 D-fix-12. DiagnosticHint property-name pattern is intentional, not a bug

 Repo facts:
 - Get-ReplicationHealth emits DiagnosticHints (plural array) at :606. Multiple hints possible — one per DC pair with
 partial-partition failure (:576-591).
 - Find-LegacyProtocolExposure, Test-TombstoneGap, Test-ProtectedUsersGap emit DiagnosticHint (singular scalar).
 - Advisory build sites at :2555, :2559, :2597, :2683 flatten plural→singular: extract via Select-Object -ExpandProperty
 DiagnosticHints (or singular) and assign to DiagnosticHint on advisory PSCustomObject.

 This is correct design, not inconsistency:
 - Property name carries cardinality. Plural array = DiagnosticHints. Scalar = DiagnosticHint. PowerShell idiomatic.
 - Discovery contracts honor cardinality. Advisory boundary normalizes to a single property name with array-or-scalar value.

 Alternatives considered:

 ┌───────────────────────────────────────┬─────────────────────────────────────────────────────────────────────────────────┐
 │              Alternative              │                                    Why worse                                    │
 ├───────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────┤
 │ Always plural array even for scalar   │ Lies about cardinality. Forces every consumer to index/iterate even when        │
 │                                       │ grammar says "one hint".                                                        │
 ├───────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────┤
 │ Always singular, array stuffed in     │ Same lie, opposite direction. Type ambiguity in name.                           │
 │ scalar slot                           │                                                                                 │
 ├───────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────┤
 │ Typed envelope @{ Severity;           │ Over-engineered. Current need: render hint text. No metadata.                   │
 │ Messages[] }                          │                                                                                 │
 ├───────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────┤
 │ Always emit array, document "one      │ Documentation drift. Plural name fixes both.                                    │
 │ element max"                          │                                                                                 │
 └───────────────────────────────────────┴─────────────────────────────────────────────────────────────────────────────────┘

 No change needed in plan. Pass 7 render snippet handles both via @(...) wrapping:
 $hintParts = @($a | Select-Object -ExpandProperty DiagnosticHint -ErrorAction SilentlyContinue) |
     Where-Object { $_ } |
     ForEach-Object { "<div class='diagnostic-hint'>$(ConvertTo-HtmlSafe $_)</div>" }
 $hintHtml = $hintParts -join ''

 (Note: -join '' not Join-String — Join-String is PS 7+; project is PS 5.1+.)

 Bake into Pass 7 acceptance: "DiagnosticHint may be string OR array; renderer treats both via @() wrapping."

 ---
 Section 2 — Pass 1 test updates needed

 ┌───────────────────┬─────────────────────────────────────────────────────────────────────────────────────────────────────┐
 │       Test        │                                               Change                                                │
 ├───────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Test 8            │                                                                                                     │
 │ (replication      │ See D-fix-6 — assert Healthy absent + Failed-before-Warning                                         │
 │ sort)             │                                                                                                     │
 ├───────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Tests 5, 6, 7     │ No change (already structure-aware)                                                                 │
 │ (escape)          │                                                                                                     │
 ├───────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Test 11 (print    │ No change                                                                                           │
 │ CSS)              │                                                                                                     │
 ├───────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Add new test      │ Status column rendered with class='status-failed' etc. Asserts CssClass scriptblock plumbed         │
 │                   │ correctly. One It per status value.                                                                 │
 ├───────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Add new test      │ DisplayName column (any advisory using it) renders <td class='wrap-ok'>. Asserts CssClass-as-string │
 │                   │  path works.                                                                                        │
 ├───────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Add new test      │ Date column null/MinValue input → renders 'Never' (LastLogon path) or '--' (CreatedTime path).      │
 │                   │ Asserts Format scriptblock null branch.                                                             │
 ├───────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │                   │ Sort uses ordinal: replication input [Healthy, Healthy, Failed] → output (after Healthy filter) is  │
 │ Add new test      │ [Failed] only; replication input [Warning, Failed] → output is [Failed, Warning] (rank-map order,   │
 │                   │ not alpha).                                                                                         │
 └───────────────────┴─────────────────────────────────────────────────────────────────────────────────────────────────────┘

 ---
 Section 3 — Roastable advisory consolidation (Option C) — separate plan, not this one

 User direction: out of scope for drilldown plan. Extract to its own plan; implement first; revisit after drilldown.

 Why it's compelling:

 Domain admin workflow reality: roastable cleanup pass identifies all roastable accounts (both threat types), opens one change
 ticket, rotates passwords, evaluates Protected Users membership, then handles the threat-specific attribute fix per row.
 Single workstream. Splitting into two advisory cards forces mental re-merge.

 Resolutions overlap heavily:

 ┌──────────────────────────────────────────┬──────────────────────────┬──────────────────────────────────┬───────────────┐
 │                   Step                   │        Kerberoast        │              AS-REP              │     Same?     │
 ├──────────────────────────────────────────┼──────────────────────────┼──────────────────────────────────┼───────────────┤
 │ Rotate password (long random, 25+ char)  │ yes — defeats RC4        │ yes — defeats AS-REP cracking    │ same          │
 │                                          │ cracking                 │                                  │               │
 ├──────────────────────────────────────────┼──────────────────────────┼──────────────────────────────────┼───────────────┤
 │ Move to Protected Users                  │ yes (disables RC4)       │ yes (forces AES, requires        │ same          │
 │                                          │                          │ pre-auth)                        │               │
 ├──────────────────────────────────────────┼──────────────────────────┼──────────────────────────────────┼───────────────┤
 │ Remove SPN                               │ yes (if not required)    │ n/a                              │ differs       │
 ├──────────────────────────────────────────┼──────────────────────────┼──────────────────────────────────┼───────────────┤
 │ Re-enable pre-auth (DONT_REQ_PREAUTH     │ n/a                      │ yes                              │ differs       │
 │ unset)                                   │                          │                                  │               │
 ├──────────────────────────────────────────┼──────────────────────────┼──────────────────────────────────┼───────────────┤
 │ Replace with gMSA                        │ yes (service accounts)   │ rarely applicable                │ mostly        │
 │                                          │                          │                                  │ differs       │
 ├──────────────────────────────────────────┼──────────────────────────┼──────────────────────────────────┼───────────────┤
 │ Verify TGT/AS-REQ uses AES not RC4       │ yes                      │ yes                              │ same          │
 └──────────────────────────────────────────┴──────────────────────────┴──────────────────────────────────┴───────────────┘

 Foundational fix (rotate + Protected Users) is identical. Threat-specific attribute fix differs by ONE attribute touched.

 Tools (programmatic consumers): read combined roastable-accounts.csv with ThreatType discriminator. Already at the data layer.
  Tools never read HTML report.

 So: tools indifferent to grouping; humans benefit from unified card.

 Option C concrete shape (for the future separate plan)

 Files touched: Monarch.psm1 advisory build switch (:2582-2585 Kerberoastable case + :2606-2613 AS-REP case + post-loop merge
 step), advisory test cases.

 Build pattern: defer-and-merge. Capture $kerb and $asrep results during the switch loop; emit single combined advisory after
 loop.

 # Inside switch loop:
 'Find-KerberoastableAccount' { $kerb  = $r }
 'Find-ASREPRoastableAccount' { $asrep = $r }

 # After switch loop:
 $kerbAccts  = if ($kerb)  { @($kerb.Accounts)  } else { @() }
 $asrepAccts = if ($asrep) { @($asrep.Accounts) } else { @() }
 $combined = @(
     $kerbAccts  | ForEach-Object { $_ | Add-Member -NotePropertyName ThreatType -NotePropertyValue 'Kerberoast' -PassThru }
     $asrepAccts | ForEach-Object { $_ | Add-Member -NotePropertyName ThreatType -NotePropertyValue 'ASREP'      -PassThru }
 )
 if ($combined.Count -gt 0) {
     $privCount = @($combined | Where-Object IsPrivileged).Count
     $bucket = if ($privCount -gt 0) { $criticals } else { $advisories }
     $kCount = $kerbAccts.Count; $aCount = $asrepAccts.Count
     $bucket.Add([PSCustomObject]@{
         Domain         = 'PrivilegedAccess'
         DisplayDomain  = 'Privileged Access'
         Description    = "$($combined.Count) roastable accounts ($kCount Kerberoast, $aCount AS-REP, $privCount privileged)"
         # DrilldownSpec attached by drilldown plan once both plans land
     })
 }

 Severity rule: any privileged → critical (matches existing per-type logic at :2583 and :2610). Otherwise advisory.

 CSV: existing combined roastable-accounts.csv (with ThreatType column) unchanged.

 Drilldown columns (when drilldown plan revisits):
 Account/SamAccountName/sorted; Display Name/DisplayName/wrap-ok; Type/ThreatType; Privileged/IsPrivileged (Yes/No); Pwd Age
 (d)/PasswordAgeDays; Enabled/Enabled (Yes/No). Sort: alpha SamAccountName.

 Plan sequencing:
 1. Roastable consolidation plan: lands first, refactors :2582-2613, no drilldown changes.
 2. Drilldown plan: revised with D-fix-1 through D-fix-12 above; includes single roastable advisory drilldown rather than two.

 ---
 Critical files

 - docs/plans/advisory-drilldown-plan.md — fold Section 1 into Engineering Decisions section; update Pass 1 / 3 / 4 / 6 / 7 per
  D-fix-* notes; replace Reviewer Findings section.
 - docs/raw/<roastable-consolidation>.md — new draft for separate roastable Option C plan.
 - Monarch.psm1 — implementation target. No edits in this planning pass.
 - Monarch.psd1 — confirmed explicit export list; no edit needed.
 - Monarch-Config.psd1 — AdvisoryDropdownInlineCap add per existing plan Pass 2.
 - tests/Monarch.Tests.ps1 — Pass 1 cases per existing plan + Section 2 additions above.

 ---
 Verification

 When user folds Section 1 back into the drilldown plan, fresh re-read should confirm:
 - No phrase containing "verify", "confirm", "check repo for", "default ... if unsure" remains in any Pass.
 - Every column in every advisory's column spec is fully specified: Header, Property, Sorted, Format (if needed), CssClass (if
 needed).
 - D-section is the single source of truth; passes reference it by number.
 - Reviewer Findings section is populated with at least the five reviewer lenses' findings, each resolved or explicitly
 acknowledged.
 - A fresh implementer agent given only the plan can produce code without reading source for design questions (only for line
 numbers / context).

 When roastable plan lands first:
 - Invoke-Pester ./tests/Monarch.Tests.ps1 passes existing roastable test cases (may need update for merged advisory).
 - Sample report against BadBlood lab shows ONE roastable card, not two.
 - CSV roastable-accounts.csv unchanged in shape.

 ---
 Notes for plan-fold author

 - Section 1 entries are written to drop into existing D-section as D-fix-N. Renumber if existing decisions get extended; or
 insert as D13-D24 and append.
 - Several D-fix entries delete plan text ("verify..." notes). Reviewer Findings should record each removal with reason.
 - D-fix-5 is the keystone — without locked Format/CssClass contract, D-fix-2 (date format), D-fix-4 (status display), D-fix-6
 (filtered render) all stay loose.
 - Keep CssClass-as-string-OR-scriptblock dual form; helper handles both via -is [scriptblock] check. Don't normalize to
 scriptblock-only — 'wrap-ok' is cleaner as literal.
