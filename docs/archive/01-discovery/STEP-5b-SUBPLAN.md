# Step 6 Subplan: Security Posture

Four functions in the `SecurityPosture` domain. All Discovery phase, all follow the Step 4 pattern (return contract, `-Server` splatting, `try/catch` sections, `Warnings` array).

**Dev-guide checkpoints applied:** Code budget, completion over expansion, guards at boundaries, test behavior not implementation.

**Current state:** 5 working API functions, 72 tests passing. This step adds 4 more functions.

**V0 reference:** `Create-NetworkBaseline.ps1` lines 385–405 (password policy), `Audit-PrivilegedAccess.ps1` lines 68–80 (privileged group RID map). Carry the data shapes and AD cmdlet patterns. Drop text output.

---

## Pass 1: Get-PasswordPolicyInventory + Find-WeakAccountFlag

Two functions that share AD user/group stubs. Natural pairing — ship both with tests in one pass.

### 6a. Get-PasswordPolicyInventory

- [x] **`Get-PasswordPolicyInventory` function** in `#region Security Posture`

  Trivial function. Two AD queries, one return object.

  Code-budget target: ~25–30 lines.

  | Parameter | Type |
  |-----------|------|
  | `-Server` | string |

  Return contract:

  | Property | Type | Source |
  |----------|------|--------|
  | `Domain` | `'SecurityPosture'` | Literal |
  | `Function` | `'Get-PasswordPolicyInventory'` | Literal |
  | `Timestamp` | `[datetime]` | `Get-Date` |
  | `DefaultPolicy` | `[PSCustomObject]` | `Get-ADDefaultDomainPasswordPolicy` shaped |
  | `FineGrainedPolicies` | `@([PSCustomObject])` | `Get-ADFineGrainedPasswordPolicy -Filter '*'` |
  | `Warnings` | `@([string])` | Accumulated errors |

  DefaultPolicy sub-object: MinLength, HistoryCount, MaxAgeDays, MinAgeDays, LockoutThreshold, LockoutDurationMin, ComplexityEnabled, ReversibleEncryption.

  FineGrainedPolicies sub-object: Name, Precedence, AppliesTo, MinLength, MaxAgeDays, LockoutThreshold.

  New cmdlet to stub: `Get-ADFineGrainedPasswordPolicy`.

- [x] **Tests: Get-PasswordPolicyInventory** (~3 tests)
  - Return shape correct, Domain = 'SecurityPosture', Function = 'Get-PasswordPolicyInventory'
  - Default policy values populated from mock
  - FineGrainedPolicies is empty array when none exist (not $null)

### 6b. Find-WeakAccountFlag

- [x] **`Find-WeakAccountFlag` function** in `#region Security Posture`

  Code-budget target: ~45–50 lines. Core logic: three flag queries + privileged group cross-reference via RID pattern and MemberOf.

  | Parameter | Type |
  |-----------|------|
  | `-Server` | string |

  Return contract:

  | Property | Type | Source |
  |----------|------|--------|
  | `Domain` | `'SecurityPosture'` | Literal |
  | `Function` | `'Find-WeakAccountFlag'` | Literal |
  | `Timestamp` | `[datetime]` | `Get-Date` |
  | `Findings` | `@([PSCustomObject])` | Array of finding objects (see below) |
  | `CountByFlag` | `[hashtable]` | Count per flag type |
  | `Warnings` | `@([string])` | Accumulated errors |

  Finding sub-object shape:

  | Property | Type | Source |
  |----------|------|--------|
  | `SamAccountName` | `[string]` | From `Get-ADUser` |
  | `DisplayName` | `[string]` | From `Get-ADUser` |
  | `Flag` | `[string]` | `PasswordNeverExpires`, `ReversibleEncryption`, `DESOnly` |
  | `Enabled` | `[bool]` | Always `$true` (filter only returns enabled) |
  | `IsPrivileged` | `[bool]` | Cross-referenced with privileged groups via MemberOf |

  Implementation details:
  - Three `Get-ADUser -Filter` queries, each in own `try/catch`
  - Build `$userMemberOf` hashtable during section 1 for cross-reference
  - Section 2: `Get-ADGroup -Filter '*' -Properties SID`, filter by RID pattern per mechanism-decisions.md
  - Match findings' MemberOf against privileged group DNs (direct membership only — Step 7 does nested)
  - `CountByFlag` built by iterating findings

- [x] **Tests: Find-WeakAccountFlag** (~4 tests)
  - Account with multiple flags appears once per flag, total findings correct
  - IsPrivileged correctly set based on mocked group membership
  - CountByFlag totals match Findings array
  - Partial failure — one flag query throws, others still populate, warning present

**Pass 1 exit criteria:** Both functions return correct objects. ~7 tests passing.

---

## Pass 2: Test-ProtectedUsersGap

- [x] **`Test-ProtectedUsersGap` function** in `#region Security Posture`

  Code-budget target: ~40–50 lines. Identifies privileged accounts not in Protected Users group.

  | Parameter | Type |
  |-----------|------|
  | `-Server` | string |

  Return contract:

  | Property | Type | Source |
  |----------|------|--------|
  | `Domain` | `'SecurityPosture'` | Literal |
  | `Function` | `'Test-ProtectedUsersGap'` | Literal |
  | `Timestamp` | `[datetime]` | `Get-Date` |
  | `ProtectedUsersMembers` | `@([string])` | Members of Protected Users group |
  | `GapAccounts` | `@([PSCustomObject])` | Privileged accounts NOT in Protected Users |
  | `DiagnosticHint` | `[string]` | SPN warning when applicable |
  | `Warnings` | `@([string])` | Accumulated errors |

  GapAccounts sub-object: SamAccountName, PrivilegedGroups, HasSPN.

  Critical: DiagnosticHint MUST warn about service accounts (HasSPN = true) — never recommend blanket addition.

- [x] **Tests: Test-ProtectedUsersGap** (~4 tests)
  - Privileged account not in Protected Users → appears in GapAccounts
  - Privileged account already in Protected Users → not in GapAccounts
  - Account with SPN in GapAccounts → HasSPN = $true
  - DiagnosticHint contains SPN warning when any GapAccount has SPN

**Pass 2 exit criteria:** Function returns correct objects with SPN safety warning. ~4 tests passing.

---

## Pass 3: Find-LegacyProtocolExposure

- [x] **`Find-LegacyProtocolExposure` function** in `#region Security Posture`

  Code-budget target: ~50–60 lines. Per-DC registry queries for legacy protocol settings.

  | Parameter | Type |
  |-----------|------|
  | `-Server` | string |

  Return contract:

  | Property | Type | Source |
  |----------|------|--------|
  | `Domain` | `'SecurityPosture'` | Literal |
  | `Function` | `'Find-LegacyProtocolExposure'` | Literal |
  | `Timestamp` | `[datetime]` | `Get-Date` |
  | `DCFindings` | `@([PSCustomObject])` | Array of per-DC findings |
  | `Warnings` | `@([string])` | Accumulated errors |

  DCFindings sub-object: DCName, Finding, Value, Risk.

  Finding types: NTLMv1Enabled, LMHashStored, LDAPSigningDisabled. Risk: High or Medium.

- [x] **Tests: Find-LegacyProtocolExposure** (~3 tests)
  - LmCompatibilityLevel < 3 → NTLMv1Enabled finding
  - Unreachable DC → appears in Warnings, doesn't block other DCs
  - Return shape correct

**Pass 3 exit criteria:** Function handles per-DC failures gracefully. ~3 tests passing.

---

## Pass 4: Full Suite Verification

- [x] **Run all tests (Steps 1–6)** — verify no regressions
  - Steps 1–5 tests still pass (72 existing)
  - All Step 6 tests pass
  - Expected total: ~86 tests (72 existing + ~14 new)
- [x] **Check diagnostics** — no warnings or errors in `.psm1`
- [x] **Verify `FunctionsToExport`** — all four functions listed in `Monarch.psd1`
- [x] **Verify function placement** — all four live in `#region Security Posture`

**Pass 4 exit criteria:** Full green suite. Nine working API functions total (1 Audit + 4 Infrastructure + 4 Security).

---

## New Cmdlets to Stub (beyond Steps 4–5)

| Cmdlet | Used by | Notes |
|--------|---------|-------|
| `Get-ADFineGrainedPasswordPolicy` | Get-PasswordPolicyInventory | `-Filter '*'` pattern. Stub needs `param($Filter, $Server)` |
| `Get-ADUser` | Find-WeakAccountFlag, Test-ProtectedUsersGap | Already stubbed in prior steps — re-mock per Describe |
| `Get-ADGroup` | Find-WeakAccountFlag | Already stubbed — re-mock per Describe |
| `Invoke-Command` | Find-LegacyProtocolExposure | Remote registry queries. Stub needs `param($ComputerName, $ScriptBlock)` |

Cmdlets already stubbed: `Get-ADDefaultDomainPasswordPolicy`, `Get-ADDomain`, `Get-ADForest`, `Get-ADDomainController`, `Get-ADGroupMember`.
