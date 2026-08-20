# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root, or
- **`CONTEXT-MAP.md`** at the repo root if it exists — it points at one `CONTEXT.md` per context. Read each one relevant to the topic.
- **`docs/adr/`** — read ADRs that touch the area you're about to work in. In multi-context repos, also check `src/<context>/docs/adr/` for context-scoped decisions.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

## File structure

Single-context repo (most repos):

```
/
├── CONTEXT.md
├── docs/adr/
│   ├── 0001-event-sourced-orders.md
│   └── 0002-postgres-for-write-model.md
└── src/
```

Multi-context repo (presence of `CONTEXT-MAP.md` at the root):

```
/
├── CONTEXT-MAP.md
├── docs/adr/                          ← system-wide decisions
└── src/
    ├── ordering/
    │   ├── CONTEXT.md
    │   └── docs/adr/                  ← context-specific decisions
    └── billing/
        ├── CONTEXT.md
        └── docs/adr/
```

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal — either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (event-sourced orders) — but worth reopening because…_

## monarch-kit ADR conventions

`docs/agents/adr-format.md` holds the format, the frontmatter rules, what qualifies as a
decision, and the command that rebuilds the index. Read it before writing an ADR.

An ADR is written for both agents and people, so it stays readable as prose. Name a related ADR
in the body when the link matters.

This repo expects many more ADRs than a greenfield project, because most of its decisions were
already made and their reasons live nowhere but in one person's head. Recovering a reason is
the point.

### Where a finding goes

- A term this project defines or narrows goes in `CONTEXT.md`, as a definition, and nothing
  else goes there.
- A rule about how the code is built goes in the ADR that records the decision.
- A defect goes in a GitHub issue.

A structural rule such as "the privileged-group DN set is computed once per run and threaded
through" is an ADR line, not a glossary line, even though it reads like a fact about the
domain.

### Citations

Give the standard, the control identifier, and the revision: `NIST SP 800-53 Rev. 5, AC-2(3)`.
Use a URL for community sources that carry no control identifier. Mark a citation unverified
when you did not read it in the source. Never invent one.
