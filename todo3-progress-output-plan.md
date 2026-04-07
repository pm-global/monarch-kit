# TODO-3: Progress Output with Silent Mode

## Problem

The orchestrator runs 25 functions sequentially with no user-visible progress. On slower domains this is a long silent wait. Need progress feedback that's suppressible.

## Research Needed

- What does `Write-Progress` look like in PowerShell 5.1 vs 7+? Any rendering differences to account for?
- Should progress be per-function, per-domain, or both?
- What's the right default verbosity? Minimal status bar vs per-function line output?
- How does `-Silent` interact with `-Verbose`? (Silent suppresses default; Verbose adds detail; both together = no default, yes detail?)
- Does preflight (already implemented) establish a pattern to follow?

## Scope

- Add `-Silent` switch to `Invoke-DomainAudit`
- Add progress output to the orchestrator's function execution loop
- Define what `-Verbose` adds beyond default progress
- Tests for silent mode suppression

## Out of Scope

- Progress within individual functions
- GUI or web-based progress indicators
