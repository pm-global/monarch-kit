# TODO-1: Action Hints in Critical/Advisory Cards

## Problem

`.card .action-hint` CSS rule exists but no card ever emits an action-hint element. Critical and advisory cards show what was found but not what to do about it. Required before remediation work begins.

## Research Needed

- What does the v5 reference report show for action hints? Pull exact examples.
- Which findings have clear, non-obvious next steps vs which are self-explanatory?
- Should every card get a hint, or only criticals, or only cards where the next step isn't obvious?
- What's the right tone? ("Review X" vs "Run Y" vs "See Z")
- Are any hints conditional on other findings (e.g. "Run Suspend-DormantAccount" only makes sense post-Plan-2)?

## Scope

- Determine which cards get hints and what text they show
- Emit `<div class='action-hint'>...</div>` inside card markup
- Tests for hint presence/absence per card type

## Out of Scope

- CSS changes (rule already exists)
- Linking hints to remediation functions (Plan 2 dependency)
