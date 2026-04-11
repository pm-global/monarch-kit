# TODO-1 Pass 1a: Recover Dropped DiagnosticHints

Research tracker. Not a plan yet — the goal here is to fully understand what's
being dropped, where, and why, before deciding on a redesign.

## The issue

Discovery functions in `Monarch.psm1` return rich structured results, including
in several cases a pre-built `DiagnosticHint` (or `DiagnosticHints`) string that
names specific DCs, counts, thresholds, and recommended next actions. These
strings were written by the function author to be surfaced to the operator.

The critical-findings extraction in `New-MonarchReport` (lines 2553–2700ish)
collapses each result into a `[PSCustomObject]@{ Domain; DisplayDomain; Description }`
with a hand-authored generic `Description` string — and **none** of the structured
evidence or pre-built DiagnosticHint fields are carried forward. They are dropped.

This was discovered while drafting action hints for TODO-1 (see
`todo1-pass1-hints.md`). Two findings in particular (#1 Backup, #2 Replication)
already have better hint strings inside the source function than anything a
static action-hint table would produce.

## Per-function inventory of dropped signal

Source lines are approximate; verify before editing.

### High signal loss

**`Get-BackupReadinessStatus`** (function ~L1697, critical construction L2562)
- Pre-built `DiagnosticHint`: *"Last backup is older than tombstone lifetime (347 days vs 180 day limit) -- recovery from this backup may cause USN rollback. Verify replication state before attempting any restore operation."*
- Also dropped: `LastBackupAge`, `TombstoneLifetimeDays`, `BackupAgeSource`, `DetectionTier`, `BackupToolDetected`
- Critical keeps: generic *"Backup age exceeds tombstone lifetime (USN rollback risk)"*

**`Get-ReplicationHealth`** (function ~L487, critical construction L2566)
- Pre-built `DiagnosticHints` list: per-pair strings like *"DC1->DC2: Schema healthy but Domain failed"* (generated when one partition on a DC pair fails while another succeeds)
- Also dropped: full `Links` collection (SourceDC, PartnerDC, Partition, LastSuccess, ConsecutiveFailures, Status per link)
- Critical keeps: just `FailedLinkCount`

**`Find-WeakAccountFlag`** (function ~L1426, critical construction L2622)
- No pre-built hint, but `Findings` collection has `IsPrivileged` per account
- Critical keeps: per-flag count only — no privileged breakdown
- Why it matters: a privileged account with reversible encryption is a materially bigger problem than a service account with the same flag

**`Find-LegacyProtocolExposure`** (function ~L1614, critical construction L2633)
- `DCFindings` has `DCName`, `Finding` (`NTLMv1Enabled` / `LMHashStored` / `LDAPSigningDisabled`), `Value`, `Risk` per row
- Critical keeps: count of high-risk findings only
- Why it matters: NTLMv1 and LM-hash-storage have different fixes; DC identity is needed to act

**`Get-FSMORolePlacement`** (function ~L250, critical construction L2683)
- `Roles` collection has `Role` / `Holder` / `Reachable` / `Site` per role
- Critical keeps: `UnreachableCount` only
- Why it matters: losing PDC Emulator is a different severity than losing Infrastructure Master; the role name determines recovery urgency

### Medium signal loss

**`Find-KerberoastableAccount`** (function ~L946, critical construction L2590)
- `Accounts` has `PasswordAgeDays` per account
- Critical keeps: `PrivilegedCount` only
- Why it matters: password age determines crack feasibility — a 2800-day password on a privileged SPN account is the specific thing to name

### Low signal loss (current description is adequate)

- **`Get-PrivilegedGroupMembership`** — count already inline
- **`Get-PasswordPolicyInventory`** (reversible encryption critical) — binary flag, nothing per-policy to surface
- **`Find-ASREPRoastableAccount`** — counts already inline, naming accounts would bloat the card

## Other functions with DiagnosticHint fields

Found while scanning — these don't feed criticals today but confirm the pattern
was intentional across the codebase:

- **`Test-ProtectedUsersGap`** builds a `DiagnosticHint` warning about SPN-bearing
  gap accounts breaking Kerberos delegation if added to Protected Users blindly.
  Currently feeds an advisory, not a critical. The advisory construction
  (L2594–2604) also discards the hint.
- **`Test-TombstoneGap`** builds a `DiagnosticHint` similar to `Get-BackupReadinessStatus`.

There may be more. Full audit needed before redesign.

## Open questions

1. **Was there ever a rendering path for DiagnosticHint?** Grep the module for
   any place that reads `.DiagnosticHint` / `.DiagnosticHints` off a result
   object. If none exists, this has been dead code from day one — which is
   itself a finding worth confirming with the original design intent.

2. **Should the critical object carry the raw result or selected fields?**
   Two shapes to consider:
   - (a) Add explicit fields to the critical: `ActionHint`, `Evidence` (string), maybe `EvidenceDetails` (structured).
   - (b) Attach a `SourceResult` reference and let rendering pull what it needs. Simpler for the extraction code, but couples rendering to every function's return shape.

3. **Static ActionHint + dynamic Evidence, or one combined field?** The TODO-1
   plan originally assumed one `ActionHint` field. If we're also surfacing
   function-authored evidence, these may want to be separate so a test can
   assert the static action text without being brittle to the dynamic evidence.

4. **Does every critical need evidence, or only the high-signal ones?** Low
   signal loss findings (#3, #4, #6) already have the count inline in the
   Description. Forcing an Evidence field on those would be filler.

5. **How does this interact with advisories (TODO-7)?** Advisories have the
   same shape and the same drop problem (Test-ProtectedUsersGap above proves it).
   Whatever we decide for criticals should probably apply to advisories too,
   or we'll be solving the same problem twice.

6. **CSS / rendering changes required?** The plan says `.card .action-hint`
   CSS rule already exists. If we're adding an `Evidence` line in addition to
   `ActionHint`, that may need its own CSS rule and its own place in the card
   layout.

## Next steps (research, not implementation)

- [ ] Grep `Monarch.psm1` for `DiagnosticHint` references — find every function
      that emits one and every (if any) consumer.
- [ ] Check git history on the DiagnosticHint fields — were they added
      speculatively, or was there a consumer that got removed?
- [ ] Review `docs/domain-specs.md` and `docs/design-system.md` for any
      documented intent around DiagnosticHint or card evidence rendering.
- [ ] Decide on critical object shape (question 2 above).
- [ ] Decide on static-vs-dynamic hint split (question 3).
- [ ] Once shape is settled, revisit `todo1-pass1-hints.md` and mark which
      hints become static-only vs. composed-with-evidence.

## Scope note

This is an expansion of TODO-1. The original plan assumed adding a single
`ActionHint` string property. Recovering DiagnosticHints means touching the
critical-findings extraction loop and possibly the rendering — larger than the
original Pass 2 scope. Worth redesigning the TODO-1 plan once questions above
are answered, rather than bolting evidence on as an afterthought.
