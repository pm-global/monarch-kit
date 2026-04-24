<#
.SYNOPSIS
    Export all Group Policy Objects in multiple human-readable formats for handover audit.

.DESCRIPTION
    Professional-grade GPO export tool for network handover/onboarding scenarios.
    Exports GPOs in HTML (readable), XML (complete), and CSV (filterable) formats.
    Generates diff-ready baseline for future change tracking.
    
    Designed for environments where you inherit unknown/mismanaged GPOs and need to
    understand scope, settings, and risk surface before cleanup.

.PARAMETER OutputPath
    Base directory for all exports. Defaults to .\GPO-Audit-[timestamp]

.PARAMETER IncludePermissions
    Include detailed GPO permission analysis (who can modify each GPO)

.PARAMETER IncludeWMIFilters
    Export WMI filter details separately

.EXAMPLE
    .\Export-GPOAudit.ps1 -OutputPath "C:\Audit" -IncludePermissions

.NOTES
    Author: Network Handover Best Practices
    Version: 1.0
    Requires: GroupPolicy module, Domain Admin or equivalent read rights
    
    HOW PROS REVIEW GPOs:
    1. Start with HTML reports (easy browsing in browser)
    2. Use CSV summaries to identify high-risk settings (passwords, privileges, scripts)
    3. Keep XML backup for full restore capability
    4. Compare against known-good baseline or Microsoft Security Baseline
    5. Focus on: User Rights Assignment, Security Options, Startup/Logon scripts, 
       Software Installation, overly broad links
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".\GPO-Audit-$(Get-Date -Format 'yyyyMMdd-HHmmss')",
    
    [Parameter(Mandatory=$false)]
    [switch]$IncludePermissions,
    
    [Parameter(Mandatory=$false)]
    [switch]$IncludeWMIFilters
)

#Requires -Modules GroupPolicy

# ============================================================================
# INITIALIZATION
# ============================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'Continue'

# Create output directory structure
$Paths = @{
    Root        = $OutputPath
    HTML        = Join-Path $OutputPath "01-HTML-Reports"
    XML         = Join-Path $OutputPath "02-XML-Backup"
    CSV         = Join-Path $OutputPath "03-CSV-Analysis"
    Permissions = Join-Path $OutputPath "04-Permissions"
    WMI         = Join-Path $OutputPath "05-WMI-Filters"
    Summary     = Join-Path $OutputPath "00-SUMMARY"
}

foreach ($path in $Paths.Values) {
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

# Initialize logging
$LogFile = Join-Path $Paths.Summary "audit.log"
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $logMessage
    Write-Host $logMessage -ForegroundColor $(
        switch($Level) {
            "ERROR" { "Red" }
            "WARN"  { "Yellow" }
            "SUCCESS" { "Green" }
            default { "White" }
        }
    )
}

Write-Log "=== GPO Audit Export Started ===" "SUCCESS"
Write-Log "Output Directory: $OutputPath"

# ============================================================================
# DOMAIN INFORMATION
# ============================================================================

Write-Log "Gathering domain information..."

try {
    $Domain = Get-ADDomain
    $DomainInfo = [PSCustomObject]@{
        Domain          = $Domain.DNSRoot
        NetBIOSName     = $Domain.NetBIOSName
        DomainMode      = $Domain.DomainMode
        ForestMode      = (Get-ADForest).ForestMode
        PDCEmulator     = $Domain.PDCEmulator
        AuditDate       = Get-Date
        AuditUser       = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        DCCount         = (Get-ADDomainController -Filter *).Count
    }
    
    $DomainInfo | Export-Csv -Path (Join-Path $Paths.Summary "domain-info.csv") -NoTypeInformation
    Write-Log "Domain: $($Domain.DNSRoot) | Mode: $($Domain.DomainMode)"
} catch {
    Write-Log "Failed to gather domain info: $_" "ERROR"
    throw
}

# ============================================================================
# GPO DISCOVERY AND EXPORT
# ============================================================================

Write-Log "Discovering all GPOs..."

try {
    $AllGPOs = Get-GPO -All | Sort-Object DisplayName
    Write-Log "Found $($AllGPOs.Count) GPOs" "SUCCESS"
} catch {
    Write-Log "Failed to enumerate GPOs: $_" "ERROR"
    throw
}

# ============================================================================
# FULL XML BACKUP (Complete Settings - Restore Capability)
# ============================================================================

Write-Log "Creating full XML backup of all GPOs (restore-ready format)..."

try {
    # Backup all GPOs - this creates GUID-named folders with full settings
    Backup-GPO -All -Path $Paths.XML | Out-Null
    Write-Log "XML backup completed: $($Paths.XML)" "SUCCESS"
    Write-Log "This backup can be restored with Restore-GPO or Import-GPO"
} catch {
    Write-Log "XML backup failed: $_" "WARN"
}

# ============================================================================
# HTML REPORTS (Human Readable - Primary Review Format)
# ============================================================================

Write-Log "Generating HTML reports for each GPO (primary review format)..."

$i = 0
$HTMLIndex = @()

foreach ($GPO in $AllGPOs) {
    $i++
    Write-Progress -Activity "Generating HTML Reports" -Status "$i of $($AllGPOs.Count): $($GPO.DisplayName)" -PercentComplete (($i / $AllGPOs.Count) * 100)
    
    try {
        # Sanitize filename (remove invalid characters)
        $SafeName = $GPO.DisplayName -replace '[\\/:*?"<>|]', '_'
        $HTMLPath = Join-Path $Paths.HTML "$SafeName.html"
        
        # Generate HTML report (human-readable settings view)
        Get-GPOReport -Guid $GPO.Id -ReportType Html -Path $HTMLPath
        
        # Track for index
        $HTMLIndex += [PSCustomObject]@{
            DisplayName = $GPO.DisplayName
            FileName    = "$SafeName.html"
            GUID        = $GPO.Id
        }
        
    } catch {
        Write-Log "Failed to generate HTML for $($GPO.DisplayName): $_" "WARN"
    }
}

# Create clickable index HTML file
$IndexHTML = @"
<!DOCTYPE html>
<html>
<head>
    <title>GPO Audit Index - $($Domain.DNSRoot)</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 20px; background: #f5f5f5; }
        h1 { color: #0078d4; }
        table { border-collapse: collapse; width: 100%; background: white; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        th { background-color: #0078d4; color: white; padding: 12px; text-align: left; position: sticky; top: 0; }
        td { padding: 10px; border-bottom: 1px solid #ddd; }
        tr:hover { background-color: #f1f1f1; }
        a { color: #0078d4; text-decoration: none; }
        a:hover { text-decoration: underline; }
        .info { background: #e7f3ff; padding: 15px; border-left: 4px solid #0078d4; margin-bottom: 20px; }
    </style>
</head>
<body>
    <h1>Group Policy Objects - Audit Index</h1>
    <div class="info">
        <strong>Domain:</strong> $($Domain.DNSRoot)<br>
        <strong>Audit Date:</strong> $($DomainInfo.AuditDate)<br>
        <strong>Total GPOs:</strong> $($AllGPOs.Count)<br>
        <strong>Audited By:</strong> $($DomainInfo.AuditUser)
    </div>
    <table>
        <thead>
            <tr>
                <th>GPO Name</th>
                <th>GUID</th>
                <th>Report</th>
            </tr>
        </thead>
        <tbody>
"@

foreach ($item in $HTMLIndex) {
    $IndexHTML += @"
            <tr>
                <td>$($item.DisplayName)</td>
                <td style="font-family: monospace; font-size: 0.9em;">$($item.GUID)</td>
                <td><a href="$($item.FileName)" target="_blank">View Report</a></td>
            </tr>
"@
}

$IndexHTML += @"
        </tbody>
    </table>
</body>
</html>
"@

$IndexHTML | Out-File -FilePath (Join-Path $Paths.HTML "00-INDEX.html") -Encoding UTF8
Write-Log "HTML index created - open 00-INDEX.html to browse all GPOs" "SUCCESS"

# ============================================================================
# CSV ANALYSIS (Filterable Summary Data)
# ============================================================================

Write-Log "Building CSV analysis files..."

# GPO Summary with link information
$GPOSummary = @()
$LinkageDetails = @()

foreach ($GPO in $AllGPOs) {
    Write-Progress -Activity "Analyzing GPO Details" -Status $GPO.DisplayName
    
    # Get GPO report as XML for parsing
    [xml]$GPOReport = Get-GPOReport -Guid $GPO.Id -ReportType Xml
    
    # Parse links (where is this GPO applied?)
    $Links = $GPOReport.GPO.LinksTo
    if ($Links) {
        foreach ($Link in $Links) {
            $LinkageDetails += [PSCustomObject]@{
                GPOName     = $GPO.DisplayName
                LinkedTo    = $Link.SOMPath
                Enabled     = $Link.Enabled
                NoOverride  = $Link.NoOverride
                Order       = $Link.Order
            }
        }
    } else {
        # Unlinked GPOs are important to find (potential orphans)
        $LinkageDetails += [PSCustomObject]@{
            GPOName     = $GPO.DisplayName
            LinkedTo    = "**UNLINKED**"
            Enabled     = "N/A"
            NoOverride  = "N/A"
            Order       = "N/A"
        }
    }
    
    # Check for high-risk settings (scripts, user rights, etc.)
    # Note: XML namespace handling varies, using simple Contains checks for reliability
    $XMLContent = $GPOReport.OuterXml
    $HasUserRights = $XMLContent -match "UserRightsAssignment"
    $HasSecurityOptions = $XMLContent -match "SecurityOptions"
    $HasScripts = $XMLContent -match "<Script>"
    $HasSoftwareInstall = $XMLContent -match "SoftwareInstallation"
    
    $GPOSummary += [PSCustomObject]@{
        DisplayName         = $GPO.DisplayName
        GUID                = $GPO.Id
        CreatedTime         = $GPO.CreationTime
        ModifiedTime        = $GPO.ModificationTime
        UserEnabled         = $GPO.User.Enabled
        ComputerEnabled     = $GPO.Computer.Enabled
        WMIFilter           = $GPO.WmiFilter.Name
        Description         = $GPO.Description
        HasUserRights       = $HasUserRights
        HasSecurityOptions  = $HasSecurityOptions
        HasScripts          = $HasScripts
        HasSoftwareInstall  = $HasSoftwareInstall
        Owner               = $GPO.Owner
    }
}

$GPOSummary | Export-Csv -Path (Join-Path $Paths.CSV "gpo-summary.csv") -NoTypeInformation
$LinkageDetails | Export-Csv -Path (Join-Path $Paths.CSV "gpo-linkage.csv") -NoTypeInformation

Write-Log "CSV files created - filter/sort in Excel for analysis" "SUCCESS"

# ============================================================================
# PERMISSIONS AUDIT (Who Can Modify GPOs)
# ============================================================================

if ($IncludePermissions) {
    Write-Log "Analyzing GPO permissions..."
    
    $PermissionsReport = @()
    
    foreach ($GPO in $AllGPOs) {
        Write-Progress -Activity "Analyzing Permissions" -Status $GPO.DisplayName
        
        try {
            $Perms = Get-GPPermission -Guid $GPO.Id -All
            
            foreach ($Perm in $Perms) {
                $PermissionsReport += [PSCustomObject]@{
                    GPOName       = $GPO.DisplayName
                    Trustee       = $Perm.Trustee.Name
                    TrusteeSID    = $Perm.Trustee.Sid
                    TrusteeType   = $Perm.Trustee.SidType
                    Permission    = $Perm.Permission
                    Inherited     = $Perm.Inherited
                    Denied        = $Perm.Denied
                }
            }
        } catch {
            Write-Log "Failed to get permissions for $($GPO.DisplayName): $_" "WARN"
        }
    }
    
    $PermissionsReport | Export-Csv -Path (Join-Path $Paths.Permissions "gpo-permissions.csv") -NoTypeInformation
    
    # Find overpermissioned GPOs (non-standard edit rights)
    $SuspectPerms = $PermissionsReport | Where-Object {
        $_.Permission -like "*Edit*" -and 
        $_.Trustee -notmatch "Domain Admins|Enterprise Admins|Group Policy Creator Owners" -and
        -not $_.Denied
    }
    
    if ($SuspectPerms) {
        $SuspectPerms | Export-Csv -Path (Join-Path $Paths.Permissions "REVIEW-overpermissioned-gpos.csv") -NoTypeInformation
        Write-Log "Found $($SuspectPerms.Count) potentially overpermissioned GPO entries - review REVIEW-overpermissioned-gpos.csv" "WARN"
    }
}

# ============================================================================
# WMI FILTER EXPORT
# ============================================================================

if ($IncludeWMIFilters) {
    Write-Log "Exporting WMI Filters..."
    
    try {
        # WMI filters are stored in AD, need to query directly
        $WMIFilters = Get-ADObject -Filter {objectClass -eq "msWMI-Som"} -Properties *
        
        if ($WMIFilters) {
            $WMIReport = @()
            
            foreach ($Filter in $WMIFilters) {
                $WMIReport += [PSCustomObject]@{
                    Name          = $Filter.Name
                    Description   = $Filter.'msWMI-Name'
                    Query         = $Filter.'msWMI-Parm2'
                    CreatedDate   = $Filter.whenCreated
                    ModifiedDate  = $Filter.whenChanged
                }
            }
            
            $WMIReport | Export-Csv -Path (Join-Path $Paths.WMI "wmi-filters.csv") -NoTypeInformation
            Write-Log "Exported $($WMIFilters.Count) WMI filters"
        } else {
            Write-Log "No WMI filters found in domain"
        }
    } catch {
        Write-Log "Failed to export WMI filters: $_" "WARN"
    }
}

# ============================================================================
# GENERATE EXECUTIVE SUMMARY
# ============================================================================

Write-Log "Generating executive summary..."

$UnlinkedGPOs = $LinkageDetails | Where-Object { $_.LinkedTo -eq "**UNLINKED**" }
$DisabledGPOs = $AllGPOs | Where-Object { -not $_.User.Enabled -and -not $_.Computer.Enabled }

$Summary = @"
================================================================================
GROUP POLICY AUDIT SUMMARY
================================================================================
Domain: $($Domain.DNSRoot)
Audit Date: $($DomainInfo.AuditDate)
Audited By: $($DomainInfo.AuditUser)

STATISTICS
--------------------------------------------------------------------------------
Total GPOs:                 $($AllGPOs.Count)
Unlinked GPOs:              $($UnlinkedGPOs.Count) $(if($UnlinkedGPOs.Count -gt 0){"**REVIEW NEEDED**"})
Completely Disabled GPOs:   $($DisabledGPOs.Count)
GPOs with WMI Filters:      $(($AllGPOs | Where-Object {$_.WmiFilter}).Count)

HIGH-RISK SETTINGS DETECTED
--------------------------------------------------------------------------------
GPOs with User Rights:      $(($GPOSummary | Where-Object HasUserRights).Count)
GPOs with Scripts:          $(($GPOSummary | Where-Object HasScripts).Count)
GPOs with Software Install: $(($GPOSummary | Where-Object HasSoftwareInstall).Count)

REVIEW PRIORITIES (for inherited/unknown networks)
--------------------------------------------------------------------------------
1. Open: $($Paths.HTML)\00-INDEX.html
   Browse HTML reports to understand what each GPO does

2. Review: $($Paths.CSV)\gpo-linkage.csv
   Identify where GPOs apply and if scope is appropriate
   Filter for "**UNLINKED**" to find orphaned policies

3. Check: $($Paths.CSV)\gpo-summary.csv
   Filter HasUserRights=TRUE, HasScripts=TRUE for privilege-granting GPOs
   Sort by ModifiedTime to see recent changes

4. Security: $(if($IncludePermissions){"$($Paths.Permissions)\REVIEW-overpermissioned-gpos.csv"}else{"Re-run with -IncludePermissions"})
   Verify only appropriate admins can modify GPOs

5. Backup: $($Paths.XML)
   Full restore-ready backup of all settings (keep this safe!)

RECOMMENDED NEXT STEPS
--------------------------------------------------------------------------------
- Delete or archive unlinked GPOs after confirming they're not needed
- Review GPOs with User Rights Assignment for overprivileged accounts
- Check for hardcoded credentials in startup/logon scripts
- Verify GPO linkage doesn't grant excessive rights to broad OUs
- Compare security settings against Microsoft Security Baselines:
  https://aka.ms/securitybaselines
  
- Document ownership/purpose of each GPO (use Description field)

FILES GENERATED
--------------------------------------------------------------------------------
"@

# List all output files
Get-ChildItem -Path $OutputPath -Recurse -File | ForEach-Object {
    $Summary += "`n$($_.FullName -replace [regex]::Escape($OutputPath), '.')"
}

$Summary += "`n`n"
$Summary += "="*80
$Summary += "`nAudit completed: $(Get-Date)"
$Summary += "`n" + "="*80

$Summary | Out-File -FilePath (Join-Path $Paths.Summary "EXECUTIVE-SUMMARY.txt") -Encoding UTF8

Write-Log "=== Audit Complete ===" "SUCCESS"
Write-Log "Review EXECUTIVE-SUMMARY.txt for findings and next steps"
Write-Host "`n$Summary`n" -ForegroundColor Cyan

# Open summary for convenience
if ($PSVersionTable.Platform -ne 'Unix') {
    Start-Process (Join-Path $Paths.Summary "EXECUTIVE-SUMMARY.txt")
}
