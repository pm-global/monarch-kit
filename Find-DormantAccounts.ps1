<#
.SYNOPSIS
    Discover dormant user accounts across all domain controllers for review.

.DESCRIPTION
    Identifies enabled user accounts with no interactive logon ≥ 90 days.
    Uses accurate cross-DC LastLogon queries (not LastLogonTimestamp).
    
    CRITICAL: This script ONLY generates a CSV for human review. It does NOT
    disable or modify any accounts. Follow human-in-the-loop process:
    1. Generate CSV (this script)
    2. Manual review + stakeholder notification
    3. Use separate Disable script on reviewed CSV
    4. Wait 30-90 days monitoring period
    5. Use separate Delete script if needed

.PARAMETER DormantDays
    Number of days without logon to consider dormant (default: 90, aligns with PCI/NIST/Microsoft 2026 guidance)

.PARAMETER OutputPath
    Path for output CSV file (default: .\Dormant-Accounts-Review-[timestamp].csv)

.PARAMETER IncludeNeverLoggedOn
    Include accounts that have never logged on (evaluate separately based on age)

.EXAMPLE
    .\Find-DormantAccounts.ps1 -DormantDays 90 -OutputPath "C:\Audit\dormant.csv"

.NOTES
    Author: Network Handover Best Practices
    Version: 1.0
    Requires: ActiveDirectory module, read access to all DCs
    
    SAFETY FEATURES:
    - Read-only script (no modifications)
    - Automatic exclusion of service accounts, admins, special accounts
    - Cross-DC LastLogon aggregation for accuracy
    - Exports full account context for informed decisions
    
    EXCLUSIONS (never flagged):
    - PasswordNeverExpires accounts (typically service accounts)
    - Accounts with SPNs (registered service accounts)
    - Keyword-tagged accounts (SERVICE, -SVC, APP, BREAKGLASS, etc.)
    - Built-in accounts (Administrator, Guest, krbtgt, etc.)
    - Privileged admin accounts (separate manual review process)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [int]$DormantDays = 90,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".\Dormant-Accounts-Review-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv",
    
    [Parameter(Mandatory=$false)]
    [switch]$IncludeNeverLoggedOn
)

#Requires -Modules ActiveDirectory

# ============================================================================
# CONFIGURATION & SAFETY PARAMETERS
# ============================================================================

$ErrorActionPreference = 'Stop'

# Service account detection keywords (case-insensitive regex)
$ServiceAccountPatterns = @(
    'SERVICE',
    '-SVC',
    'SVC-',
    '_SVC',
    'SVC_',
    'APP-',
    '-APP',
    'BREAKGLASS',
    'ADMIN',      # Often admin accounts with separate review process
    'SQL',
    'IIS',
    'BACKUP',
    'MONITOR'
)

# Built-in accounts to always exclude
$BuiltInExclusions = @(
    'Administrator',
    'Guest',
    'krbtgt',
    'DefaultAccount',
    'WDAGUtilityAccount'
)

# Privileged group SIDs (separate review process for these)
$PrivilegedGroupSIDs = @(
    'S-1-5-32-544',   # Administrators
    'S-1-5-32-548',   # Account Operators
    'S-1-5-32-549',   # Server Operators
    'S-1-5-32-551',   # Backup Operators
    '*-512',          # Domain Admins
    '*-518',          # Schema Admins
    '*-519'           # Enterprise Admins
)

Write-Host "=== Dormant Account Discovery ===" -ForegroundColor Cyan
Write-Host "Dormant Threshold: $DormantDays days without logon"
Write-Host "Output: $OutputPath`n"

# ============================================================================
# GET ALL DOMAIN CONTROLLERS (for accurate LastLogon)
# ============================================================================

Write-Host "[1/5] Discovering domain controllers..." -ForegroundColor Yellow

try {
    $DomainControllers = Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName
    Write-Host "  Found $($DomainControllers.Count) DCs" -ForegroundColor Green
} catch {
    Write-Error "Failed to get domain controllers: $_"
    exit 1
}

# ============================================================================
# GET ALL ENABLED USER ACCOUNTS
# ============================================================================

Write-Host "[2/5] Retrieving all enabled user accounts..." -ForegroundColor Yellow

try {
    # Get all enabled users with needed properties
    $AllUsers = Get-ADUser -Filter {Enabled -eq $true} -Properties `
        SamAccountName,
        DisplayName,
        Description,
        CanonicalName,
        Created,
        PasswordLastSet,
        PasswordNeverExpires,
        ServicePrincipalNames,
        MemberOf,
        LastLogonDate,
        whenChanged,
        info,
        extensionAttribute1,
        extensionAttribute2
    
    Write-Host "  Retrieved $($AllUsers.Count) enabled users" -ForegroundColor Green
} catch {
    Write-Error "Failed to retrieve user accounts: $_"
    exit 1
}

# ============================================================================
# APPLY SAFETY EXCLUSIONS
# ============================================================================

Write-Host "[3/5] Applying safety exclusions..." -ForegroundColor Yellow

$FilteredUsers = $AllUsers | Where-Object {
    $user = $_
    $exclude = $false
    
    # Exclusion 1: Built-in accounts
    if ($BuiltInExclusions -contains $user.SamAccountName) {
        $exclude = $true
    }
    
    # Exclusion 2: PasswordNeverExpires (service accounts)
    if ($user.PasswordNeverExpires) {
        $exclude = $true
    }
    
    # Exclusion 3: Has Service Principal Names (registered services)
    if ($user.ServicePrincipalNames.Count -gt 0) {
        $exclude = $true
    }
    
    # Exclusion 4: Keyword-based service account detection
    foreach ($pattern in $ServiceAccountPatterns) {
        if ($user.SamAccountName -match $pattern -or 
            $user.DisplayName -match $pattern -or 
            $user.Description -match $pattern) {
            $exclude = $true
            break
        }
    }
    
    # Exclusion 5: Members of privileged groups (separate review)
    if ($user.MemberOf) {
        foreach ($group in $user.MemberOf) {
            $groupSID = (Get-ADGroup $group).SID.Value
            foreach ($privSID in $PrivilegedGroupSIDs) {
                if ($groupSID -like $privSID) {
                    $exclude = $true
                    break
                }
            }
            if ($exclude) { break }
        }
    }
    
    # Return: keep if NOT excluded
    -not $exclude
}

$ExcludedCount = $AllUsers.Count - $FilteredUsers.Count
Write-Host "  Excluded $ExcludedCount accounts (service/admin/built-in)" -ForegroundColor Green
Write-Host "  Analyzing $($FilteredUsers.Count) standard user accounts`n" -ForegroundColor Green

# ============================================================================
# GET ACCURATE LASTLOGON ACROSS ALL DCs
# ============================================================================

Write-Host "[4/5] Getting accurate LastLogon from all DCs (this may take time)..." -ForegroundColor Yellow

$DormantCutoff = (Get-Date).AddDays(-$DormantDays)
$DormantAccounts = @()
$ProcessedCount = 0

foreach ($user in $FilteredUsers) {
    $ProcessedCount++
    if ($ProcessedCount % 50 -eq 0) {
        Write-Progress -Activity "Checking LastLogon" -Status "$ProcessedCount of $($FilteredUsers.Count)" -PercentComplete (($ProcessedCount / $FilteredUsers.Count) * 100)
    }
    
    # Query each DC for this user's LastLogon
    $LastLogonDates = @()
    
    foreach ($DC in $DomainControllers) {
        try {
            $DCUser = Get-ADUser $user.SamAccountName -Server $DC -Properties LastLogon -ErrorAction SilentlyContinue
            if ($DCUser.LastLogon -gt 0) {
                # Convert FileTime to DateTime
                $LastLogonDates += [DateTime]::FromFileTime($DCUser.LastLogon)
            }
        } catch {
            # DC unreachable or other issue - log but continue
            Write-Verbose "Could not query $DC for $($user.SamAccountName)"
        }
    }
    
    # Get the most recent LastLogon across all DCs
    if ($LastLogonDates.Count -gt 0) {
        $MostRecentLogon = ($LastLogonDates | Measure-Object -Maximum).Maximum
    } else {
        $MostRecentLogon = $null  # Never logged on
    }
    
    # Determine if account is dormant
    $IsDormant = $false
    $DormantReason = ""
    
    if ($null -eq $MostRecentLogon) {
        # Never logged on - check account age
        if ($IncludeNeverLoggedOn) {
            $AccountAge = (Get-Date) - $user.Created
            if ($AccountAge.TotalDays -ge 60) {  # Allow 60 days for new accounts
                $IsDormant = $true
                $DormantReason = "Never logged on (created $($AccountAge.Days) days ago)"
            }
        }
    } elseif ($MostRecentLogon -lt $DormantCutoff) {
        $IsDormant = $true
        $DaysSinceLogon = ((Get-Date) - $MostRecentLogon).Days
        $DormantReason = "No logon for $DaysSinceLogon days"
    }
    
    # Secondary signal: stale password (even if recent logon)
    $PasswordAge = if ($user.PasswordLastSet) { 
        ((Get-Date) - $user.PasswordLastSet).Days 
    } else { 
        999 
    }
    
    if ($PasswordAge -gt 365) {
        $DormantReason += " | Password unchanged for $PasswordAge days"
    }
    
    # Add to dormant list if criteria met
    if ($IsDormant) {
        $DormantAccounts += [PSCustomObject]@{
            SamAccountName      = $user.SamAccountName
            DisplayName         = $user.DisplayName
            LastLogon           = if ($MostRecentLogon) { $MostRecentLogon } else { "Never" }
            DaysSinceLogon      = if ($MostRecentLogon) { ((Get-Date) - $MostRecentLogon).Days } else { "N/A" }
            PasswordLastSet     = $user.PasswordLastSet
            PasswordAgeDays     = $PasswordAge
            Description         = $user.Description
            CanonicalName       = $user.CanonicalName
            Created             = $user.Created
            MemberOfCount       = $user.MemberOf.Count
            MemberOfGroups      = ($user.MemberOf | ForEach-Object { (Get-ADGroup $_).Name }) -join "; "
            Info                = $user.info
            DormantReason       = $DormantReason
            DistinguishedName   = $user.DistinguishedName
        }
    }
}

Write-Progress -Activity "Checking LastLogon" -Completed

Write-Host "  Found $($DormantAccounts.Count) dormant accounts`n" -ForegroundColor $(if ($DormantAccounts.Count -gt 0) { "Yellow" } else { "Green" })

# ============================================================================
# EXPORT RESULTS FOR HUMAN REVIEW
# ============================================================================

Write-Host "[5/5] Exporting results for review..." -ForegroundColor Yellow

if ($DormantAccounts.Count -gt 0) {
    $DormantAccounts | Sort-Object DaysSinceLogon -Descending | 
        Export-Csv -Path $OutputPath -NoTypeInformation
    
    Write-Host "`n=== RESULTS ===" -ForegroundColor Cyan
    Write-Host "Dormant accounts found: $($DormantAccounts.Count)" -ForegroundColor Yellow
    Write-Host "Review CSV: $OutputPath`n" -ForegroundColor Green
    
    # Summary statistics
    $NeverLoggedOn = ($DormantAccounts | Where-Object { $_.LastLogon -eq "Never" }).Count
    $HasGroupMemberships = ($DormantAccounts | Where-Object { $_.MemberOfCount -gt 0 }).Count
    
    Write-Host "Summary:"
    Write-Host "  - Never logged on: $NeverLoggedOn"
    Write-Host "  - With group memberships: $HasGroupMemberships (will be stripped on disable)"
    Write-Host "  - Oldest dormant: $(($DormantAccounts | Sort-Object DaysSinceLogon -Descending | Select-Object -First 1).DaysSinceLogon) days`n"
    
    Write-Host "NEXT STEPS:" -ForegroundColor Cyan
    Write-Host "1. Review the CSV and identify accounts to disable"
    Write-Host "2. Notify account owners/managers where possible"
    Write-Host "3. Create a reviewed subset CSV with only accounts to disable"
    Write-Host "4. Run .\Disable-DormantAccounts.ps1 with the reviewed CSV"
    Write-Host "5. Monitor for 30-90 days before permanent deletion`n"
    
} else {
    Write-Host "`n=== RESULTS ===" -ForegroundColor Cyan
    Write-Host "No dormant accounts found matching criteria!" -ForegroundColor Green
    Write-Host "All enabled users have logged on within $DormantDays days.`n"
}

Write-Host "=== Discovery Complete ===" -ForegroundColor Cyan
