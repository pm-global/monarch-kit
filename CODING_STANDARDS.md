# Coding Standards

This file gives rules for the code you write. Reviewers cite these rules when they check your code.

This file is not about process. Your contribution guide tells you when you can start work.

This file is not about the interfaces of one repo. Your repo's agent-orientation file gives you those interfaces.

This file tells you what good code looks like at the function level. The rules apply to any language.

---

## Return Structured Data

A function's output is data for the caller. Return an object, a record, or a struct with named fields.

Do not format the result into a string and return that as the main output. A formatted string forces every caller to parse text you already had as structured data.

---

## Put Guards at the Boundary

Most functions have a small core. Write the core first.

Guards wrap the core. Guards handle validation and edge cases. Guards do not mix into the core.

A reader must find the core logic in 30 seconds. If a reader cannot, the function does too much, or defensive code buries the logic.

```
// Before — guards mixed into the core, the core hard to find
function getStatus(name, host) {
  if (!name) throw Error("name required")
  if (!host) host = "local"
  try {
    let result = null
    result = query(name, host)
    if (result != null) {
      return result.status
    } else {
      return "not found"
    }
  } catch (e) {
    if (isNotFoundError(e)) return "not found"
    log(e)
    return "unknown"
  }
}

// After — guards at the boundary, the core visible in one line
function getStatus(name, host = "local") {
  try {
    return query(name, host).status
  } catch (e) {
    return isNotFoundError(e) ? "not found" : "unknown"
  }
}
```

The pattern matters. The language does not matter.

**Optional, maintainer only.** The example is pseudocode. The repo owner can swap in real code. No agent starts this.

---

## Signs You Must Simplify

Each sign below is a reason to cut code now. Do not build a justification for the code instead.

- A helper function has only one caller.
- Error handling repeats what the language runtime already does.
- A parameter has only ever received one value.
- A comment states what the code does. Rename the code instead.
- A function has more than two levels of nesting.
- A catch block only re-throws the error or logs it.

---

## Comments Give the Reason

A comment earns its place when the code cannot show the reason on its own: a hidden constraint, a workaround for a specific bug, a tradeoff that will surprise a future reader.

Remove a comment when the code is clear without it.

---

## Idempotent Operations and Partial Failure

Before you write a function that changes state, decide whether a second call is safe. State this in the function's name or in a comment when the answer is not obvious.

A partial failure must leave the system in a state you can diagnose and recover. Design the rollback path before you write the destructive step.

---

## Two Users Before You Abstract

An abstraction — a config layer, a wrapper, a base class, a plugin system — needs two concrete callers to exist now.

One caller means duplication costs less than the wrong abstraction. Keep the duplication until a second real use case shows you the right shape.

---

## Pre-Commit Checklist

Required for every change. The rules above explain each item; this list is the check itself.

**Safety**
- [ ] No production state is modified without dry-run and confirmation support
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
- [ ] Any change to public function behavior is reflected in the documentation that describes it
- [ ] The repo's agent-orientation file states the current state of the work

---

## Rule Priority

When two rules in this file conflict on one piece of code, the higher rule wins. Do not average the two rules. Do not give partial credit to the lower rule.

```
1. Safety and data integrity
2. Correctness — the code meets its contract
3. Diagnosability — a failure is observable and explainable
4. Contract stability — the change does not break a caller
5. Code budget — the simplest form that still satisfies the rules above
6. Style and preference
```

Example: a specific error handler adds lines that "Put Guards at the Boundary" would cut. Diagnosability (3) outranks Code Budget (5). Keep the handler.

---

## Write to ASD-STE100

Comments, commit messages, and this file follow ASD-STE100 (Simplified Technical English). The rules below are a partial summary.

- Use one word for one meaning. Do not use two different words for the same idea in one document.
- Write short sentences. Give one instruction in each sentence.
- Use the active voice. Name the actor.
- Use the imperative mood for an instruction. Example: "Close the connection."
- Use "if" for a condition that may not happen. Use "when" for an event that will happen.
- Use "must" for an obligation. Use "can" for a capability. Never use "may" — the word is ambiguous between permission and possibility.
- Never use litotes ('x not y') and never use cliches ('load bearing'). Never join two ideas with "not" into one dense phrase. State the positive rule as its own sentence. State a prohibition as its own separate sentence.

---

## The Reference Is Real Code

Judge every rule above against real, running code — this repo's own best examples — not against the rule stated on its own.

When a rule and this repo's established pattern disagree, raise the disagreement. Do not resolve it silently in either direction.
