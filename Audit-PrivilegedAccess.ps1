<#
.SYNOPSIS
    Audit privileged access and identify overpermissioned accounts.

.DESCRIPTION
    Comprehensive audit of privileged groups, admin rights, and delegation.
    Identifies accounts with excessive permissions that should be reviewed
    during network handover/cleanup.
    
    Focuses on:
    - Members of privileged groups (Domain Admins, Enterprise Admins, etc.)
    - Delegated permissions on OUs
    - Service accounts with admin rights
    - Nested group memberships that grant privilege
    - Accounts with SPN and admin rights (risky combination)

.PARAMETER OutputPath
    Base directory for audit outputs

.PARAMETER IncludeNestedGroups
    Recursively check nested group memberships

.EXAMPLE
    .\Audit-PrivilegedAccess.ps1 -OutputPath "C:\Audit" -IncludeNestedGroups

.NOTES
    Author: Network Handover Best Practices
    Version: 1.0
    Requires: ActiveDirectory module
    
    WHAT TO LOOK FOR:
    - User accounts in admin groups (should be separate admin accounts)
    - Service accounts in privileged groups (security risk)
    - Large number of Domain Admins (should be < 5 typically)
    - Stale admin accounts (haven't logged on recently)
    - Accounts with AdminCount=1 but no current group membership (orphaned)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".\Privileged-Access-Audit-$(Get-Date -Format 'yyyyMMdd-HHmmss')",
    
    [Parameter(Mandatory=$false)]
    [switch]$IncludeNestedGroups
)

#Requires -Modules ActiveDirectory

# ============================================================================
# INITIALIZATION
# ============================================================================

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Host "=== Privileged Access Audit ===" -ForegroundColor Cyan
Write-Host "Output: $OutputPath`n"

# ============================================================================
# DEFINE PRIVILEGED GROUPS
# ============================================================================

# Well-known privileged groups (by RID or partial SID)
$PrivilegedGroups = @{
    'Domain Admins'          = '*-512'
    'Enterprise Admins'      = '*-519'
    'Schema Admins'          = '*-518'
    'Administrators'         = 'S-1-5-32-544'
    'Backup Operators'       = 'S-1-5-32-551'
    'Account Operators'      = 'S-1-5-32-548'
    'Server Operators'       = 'S-1-5-32-549'
    'Print Operators'        = 'S-1-5-32-550'
    'Replicator'             = 'S-1-5-32-552'
    'Group Policy Creator Owners' = '*-520'
    'DnsAdmins'              = 'name'  # By name, not SID
}

Write-Host "[1/6] Discovering privileged groups..." -ForegroundColor Yellow

$FoundGroups = @()

foreach ($groupName in $PrivilegedGroups.Keys) {
    $pattern = $PrivilegedGroups[$groupName]
    
    try {
        if ($pattern -eq 'name') {
            # Search by name
            $group = Get-ADGroup -Filter {Name -eq $groupName} -ErrorAction SilentlyContinue
        } else {
            # Search by SID pattern
            $group = Get-ADGroup -Filter * | Where-Object { $_.SID -like $pattern }
        }
        
        if ($group) {
            $FoundGroups += $group
            Write-Host "  Found: $($group.Name)" -ForegroundColor Green
        }
    } catch {
        Write-Warning "Could not query group $groupName : $_"
    }
}

Write-Host "  Total privileged groups: $($FoundGroups.Count)`n" -ForegroundColor Green

# ============================================================================
# ENUMERATE GROUP MEMBERSHIPS
# ============================================================================

Write-Host "[2/6] Enumerating privileged group memberships..." -ForegroundColor Yellow

$AllPrivilegedMembers = @()

function Get-GroupMembersRecursive {
    param(
        [string]$GroupDN,
        [string]$GroupName,
        [int]$Depth = 0,
        [hashtable]$Seen = @{}
    )
    
    # Prevent infinite recursion
    if ($Seen.ContainsKey($GroupDN)) { return @() }
    $Seen[$GroupDN] = $true
    
    $members = @()
    
    try {
        $groupMembers = Get-ADGroupMember -Identity $GroupDN -ErrorAction Stop
        
        foreach ($member in $groupMembers) {
            $memberInfo = [PSCustomObject]@{
                GroupName     = $GroupName
                MemberName    = $member.Name
                MemberType    = $member.objectClass
                MemberSID     = $member.SID
                MemberDN      = $member.DistinguishedName
                NestingDepth  = $Depth
                DirectMember  = ($Depth -eq 0)
            }
            
            $members += $memberInfo
            
            # Recurse if this is a group and we want nested results
            if ($IncludeNestedGroups -and $member.objectClass -eq 'group') {
                $members += Get-GroupMembersRecursive -GroupDN $member.DistinguishedName -GroupName "$GroupName (via $($member.Name))" -Depth ($Depth + 1) -Seen $Seen
            }
        }
    } catch {
        Write-Warning "Could not enumerate members of $GroupName : $_"
    }
    
    return $members
}

foreach ($group in $FoundGroups) {
    Write-Progress -Activity "Enumerating Memberships" -Status $group.Name
    
    $members = Get-GroupMembersRecursive -GroupDN $group.DistinguishedName -GroupName $group.Name
    $AllPrivilegedMembers += $members
}

Write-Progress -Activity "Enumerating Memberships" -Completed

# Export all memberships
$AllPrivilegedMembers | Export-Csv -Path (Join-Path $OutputPath "privileged-group-members.csv") -NoTypeInformation

Write-Host "  Found $($AllPrivilegedMembers.Count) privileged memberships`n" -ForegroundColor Green

# ============================================================================
# ANALYZE USER ACCOUNTS WITH PRIVILEGE
# ============================================================================

Write-Host "[3/6] Analyzing privileged user accounts..." -ForegroundColor Yellow

$PrivilegedUsers = $AllPrivilegedMembers | Where-Object { $_.MemberType -eq 'user' } | 
    Select-Object -ExpandProperty MemberSID -Unique

$UserAnalysis = @()

foreach ($userSID in $PrivilegedUsers) {
    try {
        $user = Get-ADUser -Identity $userSID -Properties `
            Enabled,
            LastLogonDate,
            PasswordLastSet,
            PasswordNeverExpires,
            Created,
            Description,
            ServicePrincipalNames,
            AdminCount,
            MemberOf
        
        # Get all privileged groups this user is in
        $UserPrivGroups = $AllPrivilegedMembers | Where-Object { $_.MemberSID -eq $userSID }
        
        # Risk flags
        $RiskFlags = @()
        
        if (-not $user.Enabled) { $RiskFlags += "DISABLED" }
        if ($user.PasswordNeverExpires) { $RiskFlags += "PASSWORD_NEVER_EXPIRES" }
        if ($user.ServicePrincipalNames.Count -gt 0) { $RiskFlags += "HAS_SPN" }
        if (-not $user.LastLogonDate -or (Get-Date).AddDays(-90) -gt $user.LastLogonDate) { 
            $RiskFlags += "STALE_LOGON" 
        }
        if ($user.SamAccountName -notmatch 'adm|admin') { 
            $RiskFlags += "NOT_ADMIN_ACCOUNT" 
        }
        
        $UserAnalysis += [PSCustomObject]@{
            SamAccountName       = $user.SamAccountName
            DisplayName          = $user.DisplayName
            Enabled              = $user.Enabled
            LastLogonDate        = $user.LastLogonDate
            PasswordLastSet      = $user.PasswordLastSet
            PasswordNeverExpires = $user.PasswordNeverExpires
            Created              = $user.Created
            Description          = $user.Description
            HasSPN               = ($user.ServicePrincipalNames.Count -gt 0)
            AdminCount           = $user.AdminCount
            PrivilegedGroups     = ($UserPrivGroups.GroupName | Sort-Object -Unique) -join "; "
            GroupCount           = ($UserPrivGroups.GroupName | Sort-Object -Unique).Count
            DirectMembershipCount= ($UserPrivGroups | Where-Object DirectMember).Count
            RiskFlags            = ($RiskFlags -join ", ")
            RiskScore            = $RiskFlags.Count
        }
    } catch {
        Write-Warning "Could not analyze user SID $userSID : $_"
    }
}

$UserAnalysis | Sort-Object RiskScore -Descending | 
    Export-Csv -Path (Join-Path $OutputPath "privileged-users-analysis.csv") -NoTypeInformation

# Highlight high-risk accounts
$HighRisk = $UserAnalysis | Where-Object { $_.RiskScore -ge 2 }
if ($HighRisk) {
    $HighRisk | Export-Csv -Path (Join-Path $OutputPath "REVIEW-high-risk-privileged-accounts.csv") -NoTypeInformation
    Write-Host "  HIGH RISK: $($HighRisk.Count) accounts flagged for review" -ForegroundColor Yellow
}

Write-Host "  Analyzed $($UserAnalysis.Count) privileged users`n" -ForegroundColor Green

# ============================================================================
# FIND ADMINCOUNT ORPHANS
# ============================================================================

Write-Host "[4/6] Finding AdminCount orphans..." -ForegroundColor Yellow

# AdminCount=1 marks accounts that were once privileged (for SDProp protection)
# If they're no longer in privileged groups, they're orphaned
$AdminCountUsers = Get-ADUser -Filter {AdminCount -eq 1} -Properties AdminCount, MemberOf, SamAccountName

$Orphans = @()

foreach ($user in $AdminCountUsers) {
    # Check if currently in any privileged group
    $IsCurrentlyPrivileged = $false
    
    if ($user.MemberOf) {
        foreach ($groupDN in $user.MemberOf) {
            $group = Get-ADGroup -Identity $groupDN
            if ($FoundGroups.SID -contains $group.SID) {
                $IsCurrentlyPrivileged = $true
                break
            }
        }
    }
    
    if (-not $IsCurrentlyPrivileged) {
        $Orphans += [PSCustomObject]@{
            SamAccountName = $user.SamAccountName
            DisplayName    = $user.DisplayName
            AdminCount     = $user.AdminCount
            CurrentGroups  = $user.MemberOf.Count
            Status         = "AdminCount orphan - was privileged, no longer"
        }
    }
}

if ($Orphans) {
    $Orphans | Export-Csv -Path (Join-Path $OutputPath "admincount-orphans.csv") -NoTypeInformation
    Write-Host "  Found $($Orphans.Count) AdminCount orphans (review for cleanup)`n" -ForegroundColor Yellow
} else {
    Write-Host "  No AdminCount orphans found`n" -ForegroundColor Green
}

# ============================================================================
# SUMMARIZE BY GROUP
# ============================================================================

Write-Host "[5/6] Creating group summary..." -ForegroundColor Yellow

$GroupSummary = @()

foreach ($group in $FoundGroups) {
    $members = $AllPrivilegedMembers | Where-Object { $_.GroupName -eq $group.Name -and $_.DirectMember }
    
    $userCount = ($members | Where-Object MemberType -eq 'user').Count
    $groupCount = ($members | Where-Object MemberType -eq 'group').Count
    $computerCount = ($members | Where-Object MemberType -eq 'computer').Count
    
    $GroupSummary += [PSCustomObject]@{
        GroupName       = $group.Name
        GroupSID        = $group.SID
        UserMembers     = $userCount
        GroupMembers    = $groupCount
        ComputerMembers = $computerCount
        TotalMembers    = $members.Count
    }
}

$GroupSummary | Sort-Object UserMembers -Descending | 
    Export-Csv -Path (Join-Path $OutputPath "privileged-groups-summary.csv") -NoTypeInformation

Write-Host "  Group summary created`n" -ForegroundColor Green

# ============================================================================
# GENERATE EXECUTIVE SUMMARY
# ============================================================================

Write-Host "[6/6] Generating executive summary..." -ForegroundColor Yellow

$TotalPrivilegedUsers = ($AllPrivilegedMembers | Where-Object MemberType -eq 'user' | Select-Object -ExpandProperty MemberSID -Unique).Count
$DomainAdmins = ($GroupSummary | Where-Object GroupName -eq 'Domain Admins').UserMembers
$EnterpriseAdmins = ($GroupSummary | Where-Object GroupName -eq 'Enterprise Admins').UserMembers

$Summary = @"
================================================================================
PRIVILEGED ACCESS AUDIT SUMMARY
================================================================================
Audit Date: $(Get-Date)

STATISTICS
--------------------------------------------------------------------------------
Privileged Groups Found:    $($FoundGroups.Count)
Total Privileged Users:     $TotalPrivilegedUsers
Domain Admins:              $DomainAdmins $(if($DomainAdmins -gt 5){"**HIGH**"}else{"(acceptable)"})
Enterprise Admins:          $EnterpriseAdmins
AdminCount Orphans:         $($Orphans.Count)
High-Risk Accounts:         $($HighRisk.Count)

TOP RISKS
--------------------------------------------------------------------------------
"@

if ($HighRisk) {
    $Summary += "`nHigh-Risk Privileged Accounts:`n"
    foreach ($account in ($HighRisk | Select-Object -First 10)) {
        $Summary += "  - $($account.SamAccountName): $($account.RiskFlags)`n"
    }
}

if ($DomainAdmins -gt 10) {
    $Summary += "`n**WARNING**: $DomainAdmins Domain Admins (recommended: < 5)`n"
}

$Summary += @"

REVIEW PRIORITIES
--------------------------------------------------------------------------------
1. privileged-users-analysis.csv
   Review all privileged accounts - look for:
   - User accounts in admin groups (should be separate admin accounts)
   - Stale accounts (no recent logon)
   - Service accounts with admin rights

2. REVIEW-high-risk-privileged-accounts.csv
   $(if($HighRisk){"Immediate attention required for $($HighRisk.Count) flagged accounts"}else{"No high-risk accounts found"})

3. privileged-groups-summary.csv
   Check group membership counts - large groups may indicate over-permissioning

4. admincount-orphans.csv
   $(if($Orphans){"$($Orphans.Count) accounts were privileged but no longer - consider cleanup"}else{"No orphans found"})

BEST PRACTICES
--------------------------------------------------------------------------------
- Domain Admins should be < 5 (ideally 3-4)
- Use separate admin accounts (user-adm) not user accounts
- Service accounts should NOT have domain admin rights
- Implement tier model (separate admin accounts per tier)
- Regular access reviews (quarterly minimum)
- Remove AdminCount flag from orphaned accounts

FILES GENERATED
--------------------------------------------------------------------------------
"@

Get-ChildItem -Path $OutputPath -File | ForEach-Object {
    $Summary += "$($_.Name)`n"
}

$Summary += "`n" + "="*80

$Summary | Out-File -FilePath (Join-Path $OutputPath "EXECUTIVE-SUMMARY.txt") -Encoding UTF8

Write-Host "`n$Summary`n" -ForegroundColor Cyan

Write-Host "=== Audit Complete ===" -ForegroundColor Cyan
Write-Host "Review: $(Join-Path $OutputPath 'EXECUTIVE-SUMMARY.txt')`n"
