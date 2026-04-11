# TODO-1 Pass 1: Draft Hint List

Draft action hints for the 9 critical findings. Paused pending investigation of
dropped DiagnosticHint fields — see end of file.

---

## 1. Backup age exceeds tombstone lifetime (USN rollback risk)
`Get-BackupReadinessStatus`

**Hint:** Restoring the current backup may trigger USN rollback — capture a fresh system state backup before attempting any recovery.

**Relief:** Names the concrete action and marks the existing backup as unsafe to restore from. Admin who only half-remembered "USN rollback" now knows what *not* to do. "May" is honest — rollback is conditional on replication-partner state.

---

## 2. {N} replication links failing
`Get-ReplicationHealth`

**Hint:** Run `repadmin /showrepl` to identify failing links; check DNS and time sync first.

**Relief:** Names the one command they need and the two root causes that explain ~90% of replication failures. No guessing where to start.

**Note:** `Get-ReplicationHealth` already produces `DiagnosticHints` like *"DC1→DC2: Schema healthy but Domain failed"*. If surfaced onto the critical object, the hint could name the specific failing pair/partition instead of a generic command.

---

## 3. Domain Admin count exceeds critical threshold ({N} members)
`Get-PrivilegedGroupMembership`

**Hint:** Remove members who don't need persistent DA; for those who do, separate daily-use from admin accounts (tier model).

**Relief:** Names the step that actually drops the count — most DAs are there by accretion, not necessity — and points at the tier model (Microsoft's Enterprise Access Model) for the residual. Prevents the knee-jerk "yank everyone out of DA and lock the org out" reaction.

---

## 4. Default domain policy stores passwords with reversible encryption
`Get-PasswordPolicyInventory`

**Hint:** Disable in Default Domain Policy; users must change passwords to purge stored plaintext.

**Relief:** Names the exact GPO and warns that toggling the flag alone doesn't clean history — admin isn't surprised when pentest still finds cleartext next week.

---

## 5. {N} privileged accounts with SPNs (Kerberoasting risk)
`Find-KerberoastableAccount`

**Hint:** Migrate to gMSA or remove the SPN; as interim, rotate to a 25+ character random password.

**Relief:** Gives the real fix (gMSA) and the interim mitigation that makes kerberoasting computationally infeasible while migration is planned. Admin isn't stuck between "do nothing" and "break the app tonight."

---

## 6. {N} accounts with pre-auth disabled ({N} privileged)
`Find-ASREPRoastableAccount`

**Hint:** Clear `DONT_REQ_PREAUTH` on each; investigate why it was set before re-enabling anything.

**Relief:** Names the exact UAC flag (searchable) and warns that the flag is usually set for a legacy integration reason. Prevents the fix-then-rollback cycle.

---

## 7. Weak account flags (reversible encryption / DES-only Kerberos)
`Find-WeakAccountFlag`

**Hint:** Clear the UAC flag per account; confirm no legacy app depends on reversible passwords or DES tickets first.

**Relief:** Tells them where to look (UAC) and what breaks if they cowboy it — the legacy app that needed the flag.

---

## 8. {N} high-risk legacy protocol findings (NTLMv1/LM hash)
`Find-LegacyProtocolExposure`

**Hint:** Set `LmCompatibilityLevel = 5` via GPO; audit event 4624 for NTLMv1 use before enforcing.

**Relief:** Names the setting, the value, and the audit event that tells them which clients will break. No one enforces NTLMv2-only blind.

---

## 9. {N} FSMO role holders unreachable
`Get-FSMORolePlacement`

**Hint:** Confirm the DC is truly gone; seize with `ntdsutil` only if unrecoverable — never seize a DC you can bring back.

**Relief:** Names the tool and the one rule admins forget under pressure. Seizing a live DC is the split-brain scenario that turns an outage into a rebuild.

---

## Tone distribution

- Imperative (safe action): 2, 4
- Imperative with warning: 1, 9
- Suggestive (risky if blind): 3, 5, 6, 7, 8
- Reference: none — all 9 are actionable enough that pointing at external docs would waste the card.

---

## Paused: dropped DiagnosticHint fields

Audit of all 9 source functions revealed that useful data is being discarded
when critical objects are constructed. Two functions (`Get-BackupReadinessStatus`,
`Get-ReplicationHealth`) already build their own `DiagnosticHint` / `DiagnosticHints`
strings with specific numbers, names, and recommended actions — and the critical
construction in `New-MonarchReport` ignores them entirely.

**High signal loss:**
- #1 Backup — exact age vs. tombstone limit, pre-built DiagnosticHint string
- #2 Replication — pre-built DiagnosticHints naming failing pair + partition
- #7 Weak account flags — per-flag privileged breakdown in `Findings`
- #8 Legacy protocol — which DC, which protocol (NTLMv1 vs LM hash) in `DCFindings`
- #9 FSMO — which role is unreachable in `Roles`

**Medium signal loss:**
- #5 Kerberoastable — `PasswordAgeDays` per account in `Accounts`

**Low signal loss (current description is adequate):**
- #3 Privileged groups, #4 Password policy, #6 AS-REP roastable

This was not a Pass 1 deliverable but it changes the shape of the work. Stop here
pending a decision on whether to (a) surface discarded data onto critical objects
before writing hint text, or (b) ship static hints now and revisit dynamic
evidence separately.
