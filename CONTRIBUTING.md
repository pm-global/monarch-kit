# Contributing to monarch-kit

For repository layout and file sitemap, see `AGENTS.md`.

Contributions must meet a high bar. This document defines exactly what that bar is and how to clear it.

---

## Document Flow

### The Three-State Flow

Work moves in one direction:

```
docs/raw/  →  docs/plans/  →  docs/archive/phase-NN/
 identified     designed          implemented
```

- **`docs/raw/`** — incomplete planning and research: bugs whose cause is unknown, unvetted ideas, gaps surfaced during implementation. Schema optional, but include enough context that someone cold can understand why it was flagged.
- **`docs/plans/`** — implementation-ready artifacts only. A file here means the design is settled and work is authorized. This directory being empty means implementation is paused.
- **`docs/archive/`** — permanent record. Plans move here when implementation is complete and tests pass. Nothing is deleted.
- **`docs/phases/`** — phase scope definitions. One file per phase, stable after approval. Archives alongside its plans when the phase ships.

---

## Contribution Classes

Every change falls into one of two classes. Identify yours before doing anything else.

### Class A — Design-Touching

A change is Class A if it:

- Adds a new capability or modifies an existing one's observable behavior
- Changes a function's return contract, parameter surface, or failure semantics
- Affects safety-critical paths (destructive operations, `-WhatIf` coverage, rollback behavior)
- Resolves a known design gap or open question in `docs/`
- Modifies how modules interact with each other

Class A changes require a plan document in `docs/plans/` before any code is written. See [Plan Document Requirements](#plan-document-requirements).

### Class B — Implementation-Only

A change is Class B if it:

- Fixes a bug within the boundaries of a settled, understood design
- Improves diagnosability (error messages, logging) without changing behavior
- Adds tests for existing, untested contracts
- Corrects documentation without changing behavior

Class B changes: checklist only, no plan document required. They do require the [Pre-Commit Checklist](#pre-commit-checklist).

**If a Class B change reveals a design gap — stop. If the gap is not yet understood, file it in `docs/raw/`. If it is understood, produce a plan in `docs/plans/`. Stop. File gap in `docs/raw/`. Resume only after gap resolved.**

---

## Plan Document Requirements

A plan document is the record that a design decision was made before code was written. Its presence in `docs/plans/` is what authorizes Class A implementation to begin. Its presence in `docs/archive/` after completion is what makes the decision permanent and auditable.

### Naming

```
docs/plans/<short-description>-plan.md
```

On completion, move to:
```
docs/archive/phase-NN-name/<short-description>-plan.md
```

### Required Sections

**Problem Statement**
One paragraph. What is broken, missing, or being extended.

**Engineering/Design Decisions**
Every decision made before writing code. For each:
- What was decided
- Why — the real reason, not the obvious one
- What was rejected and why

A complete plan has all engineering decisions made in this file.
A complete plan means implementation is trivial.

**Mechanism**
How the solution works at the structural level. Contracts, state changes, failure behavior. Describe structure: contracts, state changes, failure behavior. No code syntax.

**Invariants**
What must remain true after this change. These become the test targets.

**Risks and Mitigations**
What could go wrong and what prevents it. Every risk needs a mitigation. Unmitigated risk = plan blocker. Resolve before implementation begins.

**Reviewer Findings**
Output of the [Self-Assessment Review](#self-assessment-review). Must be present. Must contain specific findings with referenced sections and proposed changes.

---

## Self-Assessment Review

All Class A changes, and any Class B change touching safety-critical code, require a self-assessment review before the plan is finalized and moved to `docs/plans/`.

Run each reviewer lens below. For each finding:
- Reference the specific function, section, or behavior
- Describe the real-world failure mode, not the abstract concern
- Propose a concrete change

**Reviewer Findings must cite specific functions, sections, or behaviors. Each finding states the real-world failure mode and a concrete change. A plan with zero findings has not been reviewed — iterate until all findings are resolved or explicitly acknowledged as non-issues.**

---

### Reviewer 1: Staff Engineer / Tech Lead

*Evaluates whether the design is settled enough that implementation requires no architectural decisions.*

- Is every return contract explicitly defined before the first line of implementation code?
- Can a fresh agent implement any function in this plan without asking a structural question?
- Is there any spec depth unevenness — some functions fully defined, others hand-waved?
- Are all callers of modified functions accounted for?

---

### Reviewer 2: SRE / Production Engineer

*Evaluates safety, idempotency, and partial failure behavior.*

- Is every state-changing operation idempotent? Is that explicitly documented?
- Does every destructive operation have `-WhatIf` and `ShouldProcess` coverage?
- What does a partial failure leave behind? Is that state diagnosable and recoverable?
- Are rollback mechanisms defined before the destructive step, not after?
- Are there any silent failure paths — operations that succeed from the caller's perspective but produce wrong state?

---

### Reviewer 3: Engineering Manager

*Evaluates completion discipline and long-term legibility.*

- Does this change complete declared existing functionality, or does it add new scope while something else is incomplete?
- Are there stubs, TODOs, or `not yet implemented` markers this change should have resolved but didn't?
- Does the infrastructure added by this change have at least two concrete consumers right now?
- Will someone reading this in 18 months understand why the decision was made, not just what was decided?

---

### Reviewer 4: AI/ML Agent Tooling Engineer

*Evaluates whether the change will be correctly interpreted by a future coding agent.*

- Are any variable names, function names, or comments ambiguous enough that an agent would choose the wrong interpretation?
- Does the plan contain implicit assumptions that are obvious to the author but absent from the text?
- Are there contradictions between this plan and existing `docs/` files? If yes, which document wins and is that stated explicitly?
- Is the instruction density appropriate — specific enough to constrain behavior, not so verbose that key points are buried?

---

## Pre-Commit Checklist

Required for all changes (Class A and Class B).

**Safety**
- [ ] No production state is modified without `-WhatIf` / `ShouldProcess` support
- [ ] Destructive operations are gated on explicit confirmation
- [ ] Partial failures leave the system in a diagnosable state
- [ ] Idempotency is documented for every state-changing function

**Correctness**
- [ ] All modified functions return objects, not formatted strings
- [ ] Return contracts are unchanged, or the change is intentional and documented in the plan
- [ ] All callers of modified functions are accounted for

**Tests**
- [ ] New functionality has tests at the same granularity as existing tests
- [ ] Tests assert behavior, not implementation
- [ ] No test passes by asserting the obvious

**Code Budget**
- [ ] Every line added has a specific failure it prevents or a contract it enforces
- [ ] Guards are at boundaries, not scattered through logic
- [ ] No helper function exists with only one caller (unless it is a boundary wrapper)

**Documentation**
- [ ] Non-obvious decisions have a comment explaining *why*, not *what*
- [ ] Any change to public function behavior is reflected in the relevant `docs/` file
- [ ] `AGENTS.md` Current State reflects the active phase

---

## Attribution

### AI-Assisted Changes

All changes that involved an AI model in any meaningful capacity — generation, debugging, design, or review — must include an `Assisted-by:` trailer in the commit message.

```
Assisted-by: Claude Sonnet 4.6
```

If multiple models were used:

```
Assisted-by: Claude Opus 4.6 (design), Claude Sonnet 4.6 (implementation)
```

Disclose: logic, structure, decisions. Omit: single-variable completions, closing brackets.

### Commit Signing

Encouraged but not required for contributors. SSH signing is recommended.

### Commit Message Format

```
<type>: <short description>

<body — what changed and why, not how>

Assisted-by: <model(s)>
```

Types: `fix`, `feat`, `test`, `docs`, `refactor`, `chore`

---

## Merge Requirements

All must be true before merge:

- Class A change: plan document present in `docs/plans/` before any code written
- Plan document: Reviewer Findings contains specific findings with section references and proposed changes
- All design decisions made in the plan, not during implementation
- Every state-changing operation has `-WhatIf` coverage
- All functions return objects, not formatted strings
- Tests assert behavior, not implementation details
- Commit includes `Signed-off-by:` trailer
- No new scope added while declared existing functionality is incomplete

---

## Philosophy

This project uses AI assistance to produce code that is safe, correct, and diagnosable — instead of fast and approximate. The planning layer exists to ensure that every difficult decision is made before implementation begins and recorded permanently. The review layer exists to ensure that genuine critical assessment takes precedence over agent sycophancy.

The directory structure is the process. `docs/raw/` → `docs/plans/` → `docs/archive/` is the complete lifecycle of every decision made in this codebase. A future maintainer, human or agent, should be able to reconstruct the history and reasoning of this project from the archive alone.
