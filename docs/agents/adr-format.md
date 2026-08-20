# ADR format

Extends `ADR-FORMAT.md` from the `domain-modeling` skill.

ADRs live in `docs/adr/` and use sequential numbering: `0000-slug.md`, `0001-slug.md`, and so
on. The number records the order the decision was written and carries no other meaning.

## Template

```md
---
depends-on: [0000]
superseded-by:
---

# {Short title of the decision}

{1-3 sentences: the context, what was decided, and why.}

## Consequences

{What this costs, and what it stops a future reader from "fixing".}
```

Keep the body short. An ADR can be a single paragraph. The value is in recording that a
decision was made and why, never in filling out sections.

## Frontmatter

Every ADR carries `depends-on` and `superseded-by`, and no others. ADR-0005 records why this
repository deviates from the upstream format, which asks for no required metadata.

List an ADR in `depends-on` only when a change to it forces you to revisit this one. Otherwise
leave the list empty.

When a decision changes, write a new ADR and put its number in the old record's
`superseded-by`. The old record keeps its original text.

## The index

`docs/adr/README.md` orders the records by dependency. Build it, never edit it:

```
pwsh -NoProfile -File skills/build-adr-index/Build-AdrIndex.ps1
```

Run it after adding, superseding, or renaming any record.

## Write in present tense

Record what holds today. A record that describes an intention reads as a backlog item, and an
agent will try to satisfy it. When the intention becomes real, write a new record.

## When to record a decision

Upstream asks for three tests. Two apply here:

1. **Surprising without context.** A future reader looks at the code and wonders why it was
   done this way.
2. **The result of a real trade-off.** There were genuine alternatives and one was picked for
   specific reasons.

The third, hard to reverse, does not apply. A threshold qualifies on its citation, not on the
cost of changing it. Changing the number is one config edit; the provenance behind the number
exists nowhere else.

### What qualifies

- **The thesis.** What the tool is reliable at, and what it survives. One record, numbered 0000.
- **A principle.** A rule that repeats wherever it applies. Expect 5 to 10 in total.
- **A mechanism.** How one check is done, and which alternative was rejected. The bulk.
- **A threshold.** A number, the standard behind it, and whether it is configurable.
- **Architectural shape.** "We're using a monorepo." "The write model is event-sourced, the read
  model is projected into Postgres."
- **Integration patterns between contexts.** "Ordering and Billing communicate via domain
  events, not synchronous HTTP."
- **Technology choices that carry lock-in.** Database, message bus, auth provider, deployment
  target. Not every library, just the ones that would take a quarter to swap out.
- **Boundary and scope decisions.** "Customer data is owned by the Customer context; other
  contexts reference it by ID only." The explicit no-s are as valuable as the yes-s.
- **Deliberate deviations from the obvious path.** "We're using manual SQL instead of an ORM
  because X." Anything where a reasonable reader would assume the opposite. These stop the next
  engineer from "fixing" something that was deliberate.
- **Constraints not visible in the code.** "We can't use AWS because of compliance
  requirements." "Response times must be under 200ms because of the partner API contract."
- **Rejected alternatives when the rejection is non-obvious.** If you considered GraphQL and
  picked REST for subtle reasons, record it, otherwise someone will suggest GraphQL again in six
  months.
