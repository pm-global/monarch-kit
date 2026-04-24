# Phase 3: Interactive Wrapper

**Prerequisite:** Phases 1 and 2 complete.

**Scope:** `Start-MonarchAudit` — the admin-facing entry point.

## Key Deliverables

- Interactive menu (1-5 phase selection, Q to quit)
- Pre-phase guidance (what will happen, time estimates, pre-flight checks)
- Human confirmations before destructive operations
- Reviewed CSV path prompt during Remediation
- Checklist rendering during Review phase (from docs/checklists.md)
- Post-phase summary with output paths and next steps
- Monitoring metrics template and checkpoint guidance
- Post-deletion timing warnings
- `-Phase` parameter for non-interactive use

## V0 Reference

`Start-NetworkHandover.ps1` is essentially a template. Carry the UX patterns:
`Show-Banner`, `Wait-ForContinue`, `Show-ChecklistItem`, `Invoke-SafeScript`
(renamed to call orchestrator instead of scripts).

The wrapper calls the orchestrator. It never calls API functions directly.

## Test Focus

Parameter validation. Phase dispatch calls `Invoke-DomainAudit` with correct `-Phase`.
Menu loop handles invalid input. Confirmation prompts block destructive operations.
