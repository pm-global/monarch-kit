# TODO-3: Progress Output with Silent Mode

## Problem

The orchestrator runs 25 functions sequentially (line 3087 loop) with no user-visible progress. On slower domains this is a long silent wait with a blank cursor. Admins need to know it's working, and when debugging they need to see what's running and what failed.

## Current State

- Orchestrator loop (lines 3087-3096): bare `foreach` with try/catch, zero console output
- Report generator: uses VOM-style `Write-Host` narration (DarkGray step lines, Green OK line)
- Preflight: same VOM pattern
- Prototype scripts (archived): used `Write-Progress` with `-Activity`, `-Status`, `-PercentComplete`
- VOM spec (`/var/mnt/storage/CODE/vom-spec.md`): defines narration, success, and failure output patterns using `Write-Host`. Does not currently reference `Write-Progress`.

## Research Needed

1. **`Write-Progress` rendering across PS versions.**
   - PS 5.1: horizontal bar at top of console window
   - PS 7.2+: inline ANSI rendering, `$PSStyle.Progress` controls style
   - PS 7.4+: minimal view by default (single line)
   - **Verify:** Does it look reasonable in both 5.1 and 7+? Behavior in ISE, non-interactive sessions, remoting, CI pipelines?
   - **Verify:** Does `Write-Progress -Completed` reliably clear the bar in both versions?

2. **`Write-Progress` + VOM coexistence.** `Write-Progress` handles the "are we there yet" question (progress bar with count). VOM handles the "what just happened" question (narration, success, failure). These are complementary:
   - `Write-Progress`: persistent progress bar showing "Discovery... 12/25 checks"
   - VOM narration (`Write-Host`): per-function step lines, failure blocks, final OK
   - The VOM spec should be updated to acknowledge `Write-Progress` as the mechanism for long-running multi-step operations, alongside the existing `Write-Host` narration pattern.

3. **VOM spec update scope.** Add a section for progress bars in multi-step operations. Keep it general (VOM is not monarch-specific). The pattern: `Write-Progress` for the overall operation progress, VOM narration for individual step detail. `Write-Progress -Completed` at the end, before the final OK line.

## Design Decisions

### Verbosity Levels

`-Verbosity` parameter with four levels. Default is `Info` -- floodgates open so the admin sees everything out of the box.

| Level | `Write-Progress` | VOM narration (per-function) | VOM failure blocks | VOM OK line |
|-------|-------------------|------------------------------|--------------------|-------------|
| `Silent` | No | No | No | No |
| `Error` | No | No | Yes | No |
| `Warn` | Yes | No | Yes | Yes |
| `Info` (default) | Yes | Yes (DarkGray step lines) | Yes | Yes (Green) |

**Rationale:**
- `Info` as default: the admin should see exactly what the module is doing, what it hit, and where it had trouble. Transparency builds trust on first use and makes debugging obvious. This is a tool that runs infrequently on important infrastructure -- the operator wants to watch.
- `Warn`: progress bar so you know it's alive, failures surfaced, but no per-function chatter. Good for routine re-runs once you trust the tool.
- `Error`: quiet unless something breaks. Useful when running specific components or in scripts that parse the return object.
- `Silent`: for automation, piping, or when the caller only wants the return object.

### Parameter Design

```powershell
[ValidateSet('Silent','Error','Warn','Info')]
[string]$Verbosity = 'Info'
```

Not a `[switch]` -- four discrete levels are clearer than combining `-Silent`, `-Verbose`, and `-Quiet` switches.

### Progress Bar Content

`Write-Progress` call (when Warn or Info):
```
-Activity "Discovery Audit"
-Status "Get-SiteTopology (12/25)"
-PercentComplete (($i / $total) * 100)
```

Cleared with `Write-Progress -Activity "Discovery Audit" -Completed` after the loop.

### VOM Narration Content (Info level)

```
audit: running Get-SiteTopology...                    (DarkGray)
audit: running Get-ReplicationHealth...               (DarkGray)
audit FAILED: Find-LegacyProtocolExposure             (Red)
  -> WinRM connection failed to DC04                  (Red)
audit: running Get-PasswordPolicyInventory...         (DarkGray)
...
audit OK: 24/25 checks completed, 1 failed (2m 14s)  (Green)
```

Failure does NOT stop execution (unlike standard VOM). The orchestrator's job is to run all checks and report -- individual function failures are isolated. This is a documented deviation from VOM's "failure stops execution" rule, justified by the orchestrator's error-isolation design.

### Interaction with Existing Output

The report generator already emits `Write-Host` narration (line 2900+). At `Silent` and `Error` levels, this should also be suppressed. Options:
- Thread `-Verbosity` to `New-MonarchReport` -- cleanest but requires param change
- Suppress by redirecting `Write-Host` output -- fragile
- **Recommendation:** Thread the param. `New-MonarchReport` already generates its own narration; it should respect the same verbosity setting. This is worth the param change.

## Scope

- Add `-Verbosity` parameter to `Invoke-DomainAudit` with `Silent/Error/Warn/Info` levels, default `Info`
- Add `Write-Progress` around the orchestrator loop (when `Warn` or `Info`)
- Add VOM narration per-function (when `Info`)
- Add VOM failure blocks (when `Error`, `Warn`, or `Info`)
- Add VOM OK line at completion (when `Warn` or `Info`)
- Thread `-Verbosity` to `New-MonarchReport` to suppress its `Write-Host` calls
- Update VOM spec with `Write-Progress` section for multi-step operations
- Tests for: silent mode produces no console output, info mode produces progress

## Out of Scope

- Progress within individual functions (per-GPO progress in Export-GPOAudit, etc.)
- GUI or web-based progress indicators
- ETA calculations
- Cascading verbosity to individual audit functions (only orchestrator + report)

## Implementation

**Model:** Sonnet. Well-defined insertion point (orchestrator loop), clear spec, existing VOM pattern to follow.

**Passes:** 1. Add `-Verbosity` param, wrap loop with `Write-Progress` + VOM narration, thread to report, update VOM spec, tests.
