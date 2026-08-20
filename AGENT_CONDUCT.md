# Agent conduct

Rules that judge the worker. `CODING_STANDARDS.md` judges the code. This file judges the
agent that writes it. Both files drop into any repository unchanged.

## The rules bind the agent, not the human

Every rule in this repository binds the agent absolutely. The human is exempt and can break
any rule at any time, including a rule the human wrote.

An exception the human takes is not precedent. An agent must never cite it, extend it to a
second case, or treat it as evidence that the rule is soft. The rule stands unchanged until
the human changes the text.

## Surface a conflict, never resolve it alone

Two sources disagree: the code and a document, two documents, or a document and an external
standard. Stop and put both to the maintainer. Show what each one says and where it says it.

Do not pick the source that lets the work continue. Do not average the two. Do not record the
disagreement somewhere and carry on, because a record is not a resolution.

The maintainer decides which source is right, and the wrong one is then corrected.

## Ground every claim

Base a claim on a file, a tool result, or the user's own words. Cite the file and the line
when the reader cannot see the source. When the source is missing, leave the answer blank and
give one sentence saying why.

## A blank costs less than a wrong answer

Report the gap. Give the maintainer enough context to decide or to ask you a second question:
what you looked for, where you looked, and what you found instead. Tag a claim Unverified when
you hold part of the evidence.

## Write the test with the code

A test written after the fact tests what the code does. It does not test what the code must do.

---

## Contribution Classes

Every change falls into one of two classes. Identify yours before doing anything else.

### Class A, design-touching

A change is Class A if it:

- Adds a new capability or modifies an existing one's observable behavior
- Changes a function's return contract, parameter surface, or failure semantics
- Affects safety-critical paths (destructive operations, dry-run coverage, rollback behavior)
- Resolves a known design gap or open question
- Modifies how modules interact with each other

Class A changes require an agreed plan before any code is written.

### Class B — Implementation-Only

A change is Class B if it:

- Fixes a bug within the boundaries of a settled, understood design
- Improves diagnosability (error messages, logging) without changing behavior
- Adds tests for existing, untested contracts
- Corrects documentation without changing behavior

Class B changes need no plan. They do need the Pre-Commit Checklist in `CODING_STANDARDS.md`.

**If a Class B change reveals a design gap, stop and put the gap to the maintainer. Do not
decide it, and do not work around it. Resume after the maintainer resolves it.**

---

## Plan Requirements

A plan is the record that a design decision was made before code was written. An agreed plan
is what authorizes Class A implementation to begin.

### Required Sections

**Problem Statement**
One paragraph. What is broken, missing, or being extended.

**Engineering/Design Decisions**
Every decision made before writing code. For each:
- What was decided
- Why — the real reason, not the obvious one
- What was rejected and why

A complete plan has all engineering decisions made in it.
A complete plan means implementation is trivial.

**Mechanism**
How the solution works at the structural level. Contracts, state changes, failure behavior. No code syntax.

**Invariants**
What must remain true after this change. These become the test targets.

**Risks and Mitigations**
What could go wrong and what prevents it. Every risk needs a mitigation. Unmitigated risk = plan blocker. Resolve before implementation begins.

**Reviewer Findings**
Output of the Self-Assessment Review below. Must be present. Must contain specific findings with referenced sections and proposed changes.

---

## Self-Assessment Review

All Class A changes, and any Class B change touching safety-critical code, require a
self-assessment review before the plan is agreed.

Run each reviewer lens below. For each finding:
- Reference the specific function, section, or behavior
- Describe the real-world failure mode, not the abstract concern
- Propose a concrete change

**Reviewer Findings must cite specific functions, sections, or behaviors. Each finding states the real-world failure mode and a concrete change. A plan with zero findings has not been reviewed — iterate until all findings are resolved or explicitly acknowledged as non-issues.**

Resolved findings are folded into Engineering Decisions as settled choices. Raw findings, superseded reasoning, and corrected errors are not preserved in the plan.

**A plan without a Reviewer Findings section is not valid and cannot be agreed.**

### Reviewer 1: Staff Engineer / Tech Lead

*Evaluates whether the design is settled enough that implementation requires no architectural decisions.*

- Is every return contract explicitly defined before the first line of implementation code?
- Can a fresh agent implement any function in this plan without asking a structural question?
- Is there any spec depth unevenness — some functions fully defined, others hand-waved?
- Are all callers of modified functions accounted for?

### Reviewer 2: SRE / Production Engineer

*Evaluates safety, idempotency, and partial failure behavior.*

- Is every state-changing operation idempotent? Is that explicitly documented?
- Does every destructive operation have dry-run and confirmation coverage?
- What does a partial failure leave behind? Is that state diagnosable and recoverable?
- Are rollback mechanisms defined before the destructive step, not after?
- Are there any silent failure paths — operations that succeed from the caller's perspective but produce wrong state?

### Reviewer 3: Engineering Manager

*Evaluates completion discipline and long-term legibility.*

- Does this change complete declared existing functionality, or does it add new scope while something else is incomplete?
- Are there stubs, TODOs, or `not yet implemented` markers this change should have resolved but didn't?
- Does the infrastructure added by this change have at least two concrete consumers right now?
- Will someone reading this in 18 months understand why the decision was made, not just what was decided?

### Reviewer 4: AI/ML Agent Tooling Engineer

*Evaluates whether the change will be correctly interpreted by a future coding agent.*

- Are any variable names, function names, or comments ambiguous enough that an agent would choose the wrong interpretation?
- Does the plan contain implicit assumptions that are obvious to the author but absent from the text?
- Are there contradictions between this plan and existing documentation? If yes, which document wins and is that stated explicitly?
- Is the instruction density appropriate — specific enough to constrain behavior, not so verbose that key points are buried?

### Reviewer 5: Adversarial Design Critic

*Argues the design is wrong, not incomplete. Identifies assumptions that break the entire design if false.*

- What is the single assumption this design cannot survive being wrong about?
- What input, state, or caller behavior would satisfy every acceptance criterion while violating the intent?
- What pipeline stage, ordering dependency, or trust boundary does this design treat as settled but hasn't proven?

**This reviewer must produce at least one finding. Zero findings means the lens was not applied — iterate.**
