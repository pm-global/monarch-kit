# Contributing to monarch-kit

For repository layout and file sitemap, see `AGENTS.md`.

Contributions must meet a high bar. `AGENT_CONDUCT.md` gives the rules that judge the worker,
including when a change needs a plan and how that plan is reviewed. `CODING_STANDARDS.md`
gives the rules that judge the code. This file covers commits and merges only.

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

- A Class A change has an agreed plan, written before any code. See `AGENT_CONDUCT.md`.
- The plan's Reviewer Findings section holds specific findings with references and proposed changes.
- Every design decision was made in the plan, not during implementation.
- The Pre-Commit Checklist in `CODING_STANDARDS.md` passes.
- No new scope is added while declared existing functionality is incomplete.
- The commit carries an `Assisted-by:` trailer when a model helped.

---

## Philosophy

This project uses AI assistance to produce code that is safe, correct, and diagnosable — instead of fast and approximate. The planning layer exists to ensure that every difficult decision is made before implementation begins and recorded permanently. The review layer exists to ensure that genuine critical assessment takes precedence over agent sycophancy.
