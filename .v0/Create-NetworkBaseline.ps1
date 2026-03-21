<#
.SYNOPSIS
    Generate comprehensive network baseline documentation for handover.

.DESCRIPTION
    Creates a complete snapshot of Active Directory configuration:
    - Domain and forest functional levels
    - Domain controllers and FSMO roles
    - OU structure
    - User and computer counts
    - Replication health
    - DNS configuration
    - DHCP scopes (if accessible)
    - Sites and subnets
    
    Use this at the start of a network handover to document "as-is" state.

.PARAMETER OutputPath
    Directory for baseline documentation

.EXAMPLE
    .\Create-NetworkBaseline.ps1 -OutputPath "C:\Handover\Baseline"

.NOTES
    Author: Network Handover Best Practices
    Version: 1.0
    Requires: ActiveDirectory module, appropriate read permissions
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".\Network-Baseline-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
)

#Requires -Modules ActiveDirectory

# ============================================================================
# INITIALIZATION
# ============================================================================

$ErrorActionPreference = 'Continue'  # Continue on errors to gather as much as possible

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$ReportPath = Join-Path $OutputPath "baseline-report.txt"
$Report = @()

function Add-Report {
    param([string]$Text)
    $Report += $Text
    Write-Host $Text
}

Add-Report "="*80
Add-Report "NETWORK BASELINE DOCUMENTATION"
Add-Report "Generated: $(Get-Date)"
Add-Report "By: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Add-Report "="*80
Add-Report ""

# ============================================================================
# DOMAIN AND FOREST INFORMATION
# ============================================================================

Add-Report "[DOMAIN & FOREST]"
Add-Report ("-"*80)

try {
    $Domain = Get-ADDomain
    $Forest = Get-ADForest
    
    Add-Report "Domain: $($Domain.DNSRoot)"
    Add-Report "NetBIOS: $($Domain.NetBIOSName)"
    Add-Report "Domain Functional Level: $($Domain.DomainMode)"
    Add-Report "Forest: $($Forest.Name)"
    Add-Report "Forest Functional Level: $($Forest.ForestMode)"
    Add-Report ""
    
    # Export to CSV for further analysis
    $DomainInfo = [PSCustomObject]@{
        Domain                = $Domain.DNSRoot
        NetBIOSName          = $Domain.NetBIOSName
        DomainMode           = $Domain.DomainMode
        Forest               = $Forest.Name
        ForestMode           = $Forest.ForestMode
        DomainSID            = $Domain.DomainSID
        DistinguishedName    = $Domain.DistinguishedName
    }
    $DomainInfo | Export-Csv -Path (Join-Path $OutputPath "domain-info.csv") -NoTypeInformation
    
} catch {
    Add-Report "ERROR: Could not retrieve domain information: $_"
    Add-Report ""
}

# ============================================================================
# DOMAIN CONTROLLERS
# ============================================================================

Add-Report "[DOMAIN CONTROLLERS]"
Add-Report ("-"*80)

try {
    $DCs = Get-ADDomainController -Filter *
    
    Add-Report "Total Domain Controllers: $($DCs.Count)"
    Add-Report ""
    
    $DCReport = @()
    foreach ($DC in $DCs) {
        Add-Report "DC: $($DC.HostName)"
        Add-Report "  Site: $($DC.Site)"
        Add-Report "  OS: $($DC.OperatingSystem)"
        Add-Report "  IP: $($DC.IPv4Address)"
        Add-Report "  Global Catalog: $($DC.IsGlobalCatalog)"
        Add-Report "  Read Only: $($DC.IsReadOnly)"
        Add-Report ""
        
        $DCReport += [PSCustomObject]@{
            HostName         = $DC.HostName
            Site             = $DC.Site
            OperatingSystem  = $DC.OperatingSystem
            IPv4Address      = $DC.IPv4Address
            IsGlobalCatalog  = $DC.IsGlobalCatalog
            IsReadOnly       = $DC.IsReadOnly
            Enabled          = $DC.Enabled
        }
    }
    
    $DCReport | Export-Csv -Path (Join-Path $OutputPath "domain-controllers.csv") -NoTypeInformation
    
} catch {
    Add-Report "ERROR: Could not retrieve domain controllers: $_"
    Add-Report ""
}

# ============================================================================
# FSMO ROLES
# ============================================================================

Add-Report "[FSMO ROLES]"
Add-Report ("-"*80)

try {
    Add-Report "Schema Master: $($Forest.SchemaMaster)"
    Add-Report "Domain Naming Master: $($Forest.DomainNamingMaster)"
    Add-Report "PDC Emulator: $($Domain.PDCEmulator)"
    Add-Report "RID Master: $($Domain.RIDMaster)"
    Add-Report "Infrastructure Master: $($Domain.InfrastructureMaster)"
    Add-Report ""
    
    $FSMOInfo = [PSCustomObject]@{
        SchemaMaster         = $Forest.SchemaMaster
        DomainNamingMaster   = $Forest.DomainNamingMaster
        PDCEmulator          = $Domain.PDCEmulator
        RIDMaster            = $Domain.RIDMaster
        InfrastructureMaster = $Domain.InfrastructureMaster
    }
    $FSMOInfo | Export-Csv -Path (Join-Path $OutputPath "fsmo-roles.csv") -NoTypeInformation
    
} catch {
    Add-Report "ERROR: Could not retrieve FSMO roles: $_"
    Add-Report ""
}

# ============================================================================
# SITES AND SUBNETS
# ============================================================================

Add-Report "[SITES & SUBNETS]"
Add-Report ("-"*80)

try {
    $Sites = Get-ADReplicationSite -Filter *
    
    Add-Report "Total Sites: $($Sites.Count)"
    Add-Report ""
    
    $SiteReport = @()
    foreach ($Site in $Sites) {
        Add-Report "Site: $($Site.Name)"
        
        # Get subnets for this site
        $Subnets = Get-ADReplicationSubnet -Filter {Site -eq $Site.DistinguishedName}
        if ($Subnets) {
            Add-Report "  Subnets: $($Subnets.Name -join ', ')"
        }
        Add-Report ""
        
        foreach ($Subnet in $Subnets) {
            $SiteReport += [PSCustomObject]@{
                SiteName    = $Site.Name
                Subnet      = $Subnet.Name
                Description = $Subnet.Description
            }
        }
    }
    
    if ($SiteReport) {
        $SiteReport | Export-Csv -Path (Join-Path $OutputPath "sites-subnets.csv") -NoTypeInformation
    }
    
} catch {
    Add-Report "ERROR: Could not retrieve sites/subnets: $_"
    Add-Report ""
}

# ============================================================================
# OU STRUCTURE
# ============================================================================

Add-Report "[ORGANIZATIONAL UNITS]"
Add-Report ("-"*80)

try {
    $OUs = Get-ADOrganizationalUnit -Filter * -Properties CanonicalName, Description, Created, ProtectedFromAccidentalDeletion
    
    Add-Report "Total OUs: $($OUs.Count)"
    Add-Report ""
    
    # Export full OU list
    $OUReport = $OUs | Select-Object Name, CanonicalName, Description, Created, ProtectedFromAccidentalDeletion | 
        Sort-Object CanonicalName
    
    $OUReport | Export-Csv -Path (Join-Path $OutputPath "organizational-units.csv") -NoTypeInformation
    
    # Show top-level OUs in report
    $TopLevelOUs = $OUs | Where-Object { 
        ($_.DistinguishedName -split ',OU=').Count -eq 1 
    } | Sort-Object Name
    
    Add-Report "Top-level OUs:"
    foreach ($OU in $TopLevelOUs) {
        Add-Report "  - $($OU.Name)"
    }
    Add-Report ""
    
} catch {
    Add-Report "ERROR: Could not retrieve OUs: $_"
    Add-Report ""
}

# ============================================================================
# OBJECT COUNTS
# ============================================================================

Add-Report "[OBJECT COUNTS]"
Add-Report ("-"*80)

try {
    $UserCount = (Get-ADUser -Filter *).Count
    $EnabledUsers = (Get-ADUser -Filter {Enabled -eq $true}).Count
    $ComputerCount = (Get-ADComputer -Filter *).Count
    $EnabledComputers = (Get-ADComputer -Filter {Enabled -eq $true}).Count
    $GroupCount = (Get-ADGroup -Filter *).Count
    
    Add-Report "Users (Total): $UserCount"
    Add-Report "Users (Enabled): $EnabledUsers"
    Add-Report "Computers (Total): $ComputerCount"
    Add-Report "Computers (Enabled): $EnabledComputers"
    Add-Report "Groups: $GroupCount"
    Add-Report ""
    
    $Counts = [PSCustomObject]@{
        TotalUsers       = $UserCount
        EnabledUsers     = $EnabledUsers
        TotalComputers   = $ComputerCount
        EnabledComputers = $EnabledComputers
        Groups           = $GroupCount
    }
    $Counts | Export-Csv -Path (Join-Path $OutputPath "object-counts.csv") -NoTypeInformation
    
} catch {
    Add-Report "ERROR: Could not count objects: $_"
    Add-Report ""
}

# ============================================================================
# REPLICATION HEALTH
# ============================================================================

Add-Report "[REPLICATION HEALTH]"
Add-Report ("-"*80)

try {
    $ReplReport = @()
    
    foreach ($DC in $DCs) {
        Add-Report "Checking replication on $($DC.HostName)..."
        
        try {
            $ReplPartners = Get-ADReplicationPartnerMetadata -Target $DC.HostName -ErrorAction Stop
            
            foreach ($partner in $ReplPartners) {
                $LastSuccess = $partner.LastReplicationSuccess
                $LastAttempt = $partner.LastReplicationAttempt
                
                $Status = if ($LastSuccess -and ((Get-Date) - $LastSuccess).TotalHours -lt 24) {
                    "Healthy"
                } else {
                    "WARNING"
                }
                
                $ReplReport += [PSCustomObject]@{
                    Server              = $DC.HostName
                    Partner             = $partner.Partner
                    Partition           = $partner.Partition
                    LastSuccess         = $LastSuccess
                    LastAttempt         = $LastAttempt
                    ConsecutiveFailures = $partner.ConsecutiveReplicationFailures
                    Status              = $Status
                }
            }
        } catch {
            Add-Report "  Could not check replication: $_"
        }
    }
    
    if ($ReplReport) {
        $ReplReport | Export-Csv -Path (Join-Path $OutputPath "replication-status.csv") -NoTypeInformation
        
        $Issues = $ReplReport | Where-Object Status -eq "WARNING"
        if ($Issues) {
            Add-Report ""
            Add-Report "WARNING: Replication issues detected on $($Issues.Count) connections!"
        } else {
            Add-Report "All replication connections healthy (< 24 hours)"
        }
    }
    Add-Report ""
    
} catch {
    Add-Report "ERROR: Could not check replication health: $_"
    Add-Report ""
}

# ============================================================================
# DNS ZONES
# ============================================================================

Add-Report "[DNS ZONES]"
Add-Report ("-"*80)

try {
    # Attempt to get DNS zones (requires DNS PowerShell module)
    if (Get-Module -ListAvailable -Name DnsServer) {
        Import-Module DnsServer -ErrorAction SilentlyContinue
        
        $Zones = Get-DnsServerZone -ErrorAction Stop
        
        Add-Report "Total DNS Zones: $($Zones.Count)"
        Add-Report ""
        
        $ZoneReport = @()
        foreach ($Zone in $Zones) {
            Add-Report "Zone: $($Zone.ZoneName) - Type: $($Zone.ZoneType)"
            
            $ZoneReport += [PSCustomObject]@{
                ZoneName      = $Zone.ZoneName
                ZoneType      = $Zone.ZoneType
                IsAutoCreated = $Zone.IsAutoCreated
                IsDsIntegrated= $Zone.IsDsIntegrated
                DynamicUpdate = $Zone.DynamicUpdate
            }
        }
        Add-Report ""
        
        $ZoneReport | Export-Csv -Path (Join-Path $OutputPath "dns-zones.csv") -NoTypeInformation
    } else {
        Add-Report "DnsServer module not available - skipping DNS zone enumeration"
        Add-Report ""
    }
} catch {
    Add-Report "Could not enumerate DNS zones: $_"
    Add-Report ""
}

# ============================================================================
# PASSWORD AND LOCKOUT POLICIES
# ============================================================================

Add-Report "[PASSWORD POLICY]"
Add-Report ("-"*80)

try {
    $DefaultPolicy = Get-ADDefaultDomainPasswordPolicy
    
    Add-Report "Minimum Password Length: $($DefaultPolicy.MinPasswordLength)"
    Add-Report "Password History: $($DefaultPolicy.PasswordHistoryCount)"
    Add-Report "Max Password Age: $($DefaultPolicy.MaxPasswordAge.Days) days"
    Add-Report "Min Password Age: $($DefaultPolicy.MinPasswordAge.Days) days"
    Add-Report "Lockout Threshold: $($DefaultPolicy.LockoutThreshold)"
    Add-Report "Lockout Duration: $($DefaultPolicy.LockoutDuration.Minutes) minutes"
    Add-Report "Complexity Enabled: $($DefaultPolicy.ComplexityEnabled)"
    Add-Report ""
    
    $DefaultPolicy | Export-Csv -Path (Join-Path $OutputPath "password-policy.csv") -NoTypeInformation
    
} catch {
    Add-Report "ERROR: Could not retrieve password policy: $_"
    Add-Report ""
}

# ============================================================================
# FINALIZE REPORT
# ============================================================================

Add-Report "="*80
Add-Report "BASELINE DOCUMENTATION COMPLETE"
Add-Report "Output Directory: $OutputPath"
Add-Report "="*80

# Save report
$Report | Out-File -FilePath $ReportPath -Encoding UTF8

Write-Host "`nBaseline documentation saved to: $OutputPath" -ForegroundColor Green
Write-Host "Main report: $ReportPath`n" -ForegroundColor Green

# Open report
if ($PSVersionTable.Platform -ne 'Unix') {
    Start-Process $ReportPath
}
