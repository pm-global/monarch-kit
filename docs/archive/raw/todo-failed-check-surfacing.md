# TODO — Failed-check surfacing as a critical advisory

## Gap

The Discovery Report has no on-page surface for discovery functions that failed to produce intelligible results. The orchestrator records failures in its `Failures` array, but a `-Silent` automation run or a non-watching admin reading only the rendered HTML has no signal that a check did not return data.

The roastable consolidation plan introduces a per-source `?` placeholder in one advisory's description. That covers the roastable case but is local — it does not surface failures of other discovery functions, and it does not handle the case where both roastable sources failed (in which case no advisory is emitted, and the failure becomes invisible on the report).

## Why it matters

A false negative reaching an automation run is the worst outcome. Roastable accounts that exist but were not detected because of a transient AD query failure look identical to a clean domain in a `-Silent` report. The admin acts on the appearance of safety.

## Shape of a fix (not a plan, just a sketch)

A single critical advisory rendered when any discovery function in the run produced a failure (`$null` lookup against the expected functions, or a function-level `Warnings` indicating the check did not complete). Description enumerates the failed function names. Bucket: `$criticals` — failure to know is a risk, not a soft advisory.

This subsumes the per-advisory `?` placeholder pattern. The placeholder is a local signal; the critical advisory is the global one.

## Status

Not in scope for the roastable consolidation plan. Filed here as identified-but-undesigned. Promote to `docs/plans/` when prioritized.
