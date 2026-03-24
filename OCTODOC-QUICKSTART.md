# DocOct Quick Start

## Installation

```powershell
# Extract archive
Expand-Archive DocOct.tar.gz -DestinationPath C:\Modules\

# Import module
Import-Module C:\Modules\DocOct\DocOct.psd1 -Force

# Verify
Get-Command -Module DocOct
```

## First Use (5 minutes)

### 1. Get a Healthy DC
```powershell
# Simplest use - get any DC passing minimum checks
$dc = Get-HealthyDC
Write-Host "Healthy DC: $dc"
```

### 2. See What's Happening
```powershell
# Get detailed health info
$dc = Get-HealthyDC -Detailed
$dc | Format-List

# Output:
# DCName        : DC01.domain.com
# HealthScore   : 8
# ChecksPassed  : {Ping, NTDS, LDAP, NetLogon, DNS, SYSVOL, RPC, TimeSync}
# ChecksFailed  : {Replication}
# Latency       : 234.5
# Timestamp     : 2025-02-10 14:23:15
# Reason        : Healthy
```

### 3. Require Higher Health
```powershell
# Only accept DCs with perfect health
$dc = Get-HealthyDC -Threshold 9

# Accept partially healthy DC
$dc = Get-HealthyDC -Threshold 5 -AllowDegraded
```

### 4. See All Options
```powershell
# Get all DCs ranked by health
$all = Get-HealthyDC -ReturnAll
$all | Select-Object DCName, HealthScore | Format-Table
```

## Agent Integration Examples

### Example 1: Safe DC Selection for Risky Operation
```powershell
function Invoke-RiskyDomainOperation {
    # Find healthiest DC first
    $dc = Get-HealthyDC -Threshold 8 -Detailed
    
    if (-not $dc) {
        throw "No sufficiently healthy DC found for risky operation"
    }
    
    if ($dc.HealthScore -lt 9) {
        Write-Warning "Using degraded DC: $($dc.DCName) (score: $($dc.HealthScore))"
        Write-Warning "Failed checks: $($dc.ChecksFailed -join ', ')"
        
        # Agent decides whether to proceed
        return @{
            Recommended = $false
            DC = $dc.DCName
            Reason = "DC not at perfect health"
        }
    }
    
    # Proceed with operation
    Invoke-ADOperation -Server $dc.DCName
}
```

### Example 2: Load Balancing Across Healthy DCs
```powershell
function Get-BalancedDC {
    param([int]$MinimumHealth = 7)
    
    # Get all healthy DCs
    $healthyDCs = Get-HealthyDC -ReturnAll | 
                  Where-Object { $_.HealthScore -ge $MinimumHealth }
    
    if (-not $healthyDCs) {
        return $null
    }
    
    # Pick random from healthy pool
    return ($healthyDCs | Get-Random).DCName
}
```

### Example 3: Pre-Flight Health Check
```powershell
function Start-DomainMaintenance {
    # Verify domain health before starting
    $allDCs = Get-HealthyDC -ReturnAll
    $healthy = $allDCs | Where-Object { $_.HealthScore -ge 7 }
    
    if ($healthy.Count -lt 2) {
        throw "Insufficient healthy DCs for safe maintenance (need 2+, found $($healthy.Count))"
    }
    
    Write-Host "Pre-flight check passed: $($healthy.Count) healthy DCs available"
    
    # Continue with maintenance...
}
```

## Testing

```powershell
# Run test suite
Invoke-Pester C:\Modules\DocOct\Tests\DocOct.Tests.ps1

# Manual testing
Get-DCHealthStatus -DCName "DC01.domain.com" -Threshold 3 -Verbose
```

## Current Limitations (MVP)

**Implemented Checks** (3/9):
- ✅ Ping (network reachability)
- ✅ NTDS (AD service running)
- ✅ LDAP (directory query)

**Stub Checks** (return success, not implemented):
- 🚧 NetLogon (always passes)
- 🚧 DNS (always passes)
- 🚧 SYSVOL (always passes)
- 🚧 RPC (always passes)
- 🚧 TimeSync (always passes)
- 🚧 Replication (always passes)

**Note**: Health scores may be higher than actual until stubs are implemented.

## Next Steps

1. **Test with your domain**
   ```powershell
   Get-HealthyDC -Detailed -Verbose
   ```

2. **Integrate into your agent code**
   - See examples above
   - Use `-Detailed` for decision-making
   - Handle `$null` returns gracefully

3. **Provide feedback**
   - What works?
   - What's confusing?
   - What's missing?

## Configuration

Edit `Config/DocOct-Config.psd1`:

```powershell
@{
    MaxDelay = 90                # Live mode adaptive limit
    DefaultThreshold = 3         # Minimum viable health
    MaxConcurrentDCs = 10        # Parallel testing limit
    
    Timeouts = @{
        Ping = 2
        NTDS = 3
        LDAP = 5
        # ... per-check timeouts
    }
}
```

## Troubleshooting

**"No domain controllers found"**
- Verify AD module: `Get-Module ActiveDirectory -ListAvailable`
- Check domain access: `Get-ADDomainController -Discover`

**"Module not found"**
- Check path: `Test-Path C:\Modules\DocOct\DocOct.psd1`
- Import explicitly: `Import-Module <full-path>\DocOct.psd1 -Force`

**Slow performance**
- Check network connectivity to DCs
- Reduce `MaxConcurrentDCs` if network limited
- Use `-Threshold 3` for fastest results

**All DCs showing perfect health (score 9)**
- This is expected in MVP - 6 checks are stubs
- Real implementation coming in Phase 2

## Help

```powershell
# Function help
Get-Help Get-HealthyDC -Full
Get-Help Get-DCHealthStatus -Detailed

# Module info
Get-Module DocOct | Format-List
```

---

**Version**: 0.1.0 (MVP)  
**Status**: Core complete, 6 checks pending  
**Focus**: Agent-first programmatic use
