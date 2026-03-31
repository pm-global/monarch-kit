# BB Fix Bug 4: Get-DNSForwarderConfiguration — `.UseRootHints` version-dependent

Context: `CLAUDE.md`, `/var/mnt/storage/CODE/dev-guide.md`

## Problem

`Monarch.psm1:2390` — `UseRootHints = [bool]$fwd.UseRootHints` where `$fwd` comes from `Get-DnsServerForwarder -ComputerName $dc.HostName` (line 2386).

The `UseRootHints` property exists on some Windows Server versions but not others. When absent, accessing `$fwd.UseRootHints` returns `$null`, and casting `$null` to `[bool]` produces `$false` — but on the BadBlood domain, this line causes the entire per-DC try/catch (lines 2385-2392) to throw, losing all forwarder data for that DC. With a single DC, `DCForwarders` comes back empty.

The property is documented in some Microsoft references, so it's real — just not universally available.

## Decision

Safe property access with `$null` fallback. Keep the property in the return object (it's useful when available) but don't throw when it's absent. This follows the project's graceful degradation pattern — gather as much as possible, don't let one missing property kill the whole result.

## Pass 1 — Code fix

**File:** `Monarch.psm1`, line 2390

**Before:**
```powershell
UseRootHints = [bool]$fwd.UseRootHints
```

**After:**
```powershell
UseRootHints = if ($fwd.PSObject.Properties['UseRootHints']) { [bool]$fwd.UseRootHints } else { $null }
```

## Pass 2 — Test update

**File:** `Tests/Monarch.Tests.ps1`, `Get-DNSForwarderConfiguration` Describe block

- Keep existing mock and tests (they have `UseRootHints` on the mock object — these continue to work)
- Add one new test: mock `Get-DnsServerForwarder` returning an object WITHOUT `UseRootHints` property (just `IPAddress`). Assert:
  - Function does not throw
  - `DCForwarders[0].UseRootHints` is `$null`
  - `DCForwarders[0].Forwarders` is populated
  - `Warnings` does not contain a forwarder-related entry

Run:
```powershell
Invoke-Pester -Path Tests/Monarch.Tests.ps1 -Filter 'Get-DNSForwarderConfiguration'
```

## Verification

- All Get-DNSForwarderConfiguration Pester tests pass (existing + new absent-property test)
- On BB domain: `DCForwarders` array populated, `Forwarders` has IP addresses, `UseRootHints` is `$null` (acceptable), no warning from this function
