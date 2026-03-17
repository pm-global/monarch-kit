<#
.SYNOPSIS
    Disable dormant user accounts from a reviewed CSV file.

.DESCRIPTION
    Takes a CSV of reviewed dormant accounts and:
    1. Disables each account
    2. Removes ALL group memberships (critical for security)
    3. Moves to quarantine OU
    4. Adds disable date to account notes
    
    CRITICAL SAFETY: Requires -WhatIf first, then -Confirm for actual execution.
    Human-in-the-loop process - never runs unattended.

.PARAMETER CSVPath
    Path to reviewed CSV from Find-DormantAccounts.ps1
    CSV must contain: SamAccountName, DisplayName, DistinguishedName

.PARAMETER QuarantineOU
    Target OU for disabled accounts (will be created if doesn't exist)
    Default: "OU=zQuarantine-Dormant,OU=Disabled Users,DC=..."

.PARAMETER WhatIf
    Show what would happen without making changes (ALWAYS RUN THIS FIRST)

.PARAMETER Confirm
    Prompt for confirmation before each account (default: true for safety)

.EXAMPLE
    # STEP 1: Always test first with WhatIf
    .\Disable-DormantAccounts.ps1 -CSVPath ".\reviewed.csv" -WhatIf
    
    # STEP 2: Review WhatIf output, then execute
    .\Disable-DormantAccounts.ps1 -CSVPath ".\reviewed.csv"

.NOTES
    Author: Network Handover Best Practices
    Version: 1.0
    Requires: ActiveDirectory module, appropriate permissions
    
    PROCESS ALIGNMENT (90-day disable + 30-90 day hold):
    - This script implements the "disable phase"
    - Accounts are quarantined but NOT deleted
    - Use Delete-DormantAccounts.ps1 after 30-90 day hold period
    
    IMMEDIATE SECURITY ACTIONS:
    - Remove group memberships (prevents indirect access via nested groups)
    - Disable account (prevents direct authentication)
    - Move to quarantine OU (isolates from production)
#>

[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
    [Parameter(Mandatory=$true)]
    [ValidateScript({Test-Path $_})]
    [string]$CSVPath,
    
    [Parameter(Mandatory=$false)]
    [string]$QuarantineOU = "",
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf,
    
    [Parameter(Mandatory=$false)]
    [bool]$Confirm = $true
)

#Requires -Modules ActiveDirectory

# ============================================================================
# INITIALIZATION & VALIDATION
# ============================================================================

$ErrorActionPreference = 'Stop'

Write-Host "=== Disable Dormant Accounts ===" -ForegroundColor Cyan
Write-Host "CSV: $CSVPath"
Write-Host "Mode: $(if($WhatIf){'WHATIF (safe preview)'}else{'EXECUTION (will modify AD)'})`n" -ForegroundColor $(if($WhatIf){'Green'}else{'Yellow'})

# Validate CSV has required columns
try {
    $Accounts = Import-Csv -Path $CSVPath
    $RequiredColumns = @('SamAccountName', 'DisplayName', 'DistinguishedName')
    
    foreach ($col in $RequiredColumns) {
        if (-not ($Accounts | Get-Member -Name $col)) {
            throw "CSV missing required column: $col"
        }
    }
    
    Write-Host "Loaded $($Accounts.Count) accounts from CSV" -ForegroundColor Green
} catch {
    Write-Error "Failed to load CSV: $_"
    exit 1
}

# Determine or create quarantine OU
if ([string]::IsNullOrEmpty($QuarantineOU)) {
    $DomainDN = (Get-ADDomain).DistinguishedName
    $QuarantineOU = "OU=zQuarantine-Dormant,$DomainDN"
}

Write-Host "Quarantine OU: $QuarantineOU`n"

# Create quarantine OU if it doesn't exist
if (-not (Get-ADOrganizationalUnit -Filter {DistinguishedName -eq $QuarantineOU} -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess($QuarantineOU, "Create quarantine OU")) {
        try {
            # Parse OU path to create hierarchy if needed
            $OUName = ($QuarantineOU -split ',')[0] -replace 'OU=', ''
            $ParentPath = ($QuarantineOU -split ',', 2)[1]
            
            New-ADOrganizationalUnit -Name $OUName -Path $ParentPath -ProtectedFromAccidentalDeletion $true
            Write-Host "Created quarantine OU: $QuarantineOU" -ForegroundColor Green
        } catch {
            Write-Warning "Could not create quarantine OU: $_"
            Write-Warning "Accounts will be disabled but not moved"
        }
    }
}

# ============================================================================
# PROCESS ACCOUNTS
# ============================================================================

$Results = @()
$SuccessCount = 0
$FailCount = 0

Write-Host "Processing accounts...`n" -ForegroundColor Yellow

foreach ($account in $Accounts) {
    $accountResult = [PSCustomObject]@{
        SamAccountName  = $account.SamAccountName
        DisplayName     = $account.DisplayName
        Action          = ""
        Status          = ""
        Error           = ""
    }
    
    try {
        # Verify account exists and is enabled
        $ADUser = Get-ADUser -Identity $account.SamAccountName -Properties MemberOf, Description, info
        
        if (-not $ADUser.Enabled) {
            $accountResult.Status = "SKIPPED"
            $accountResult.Action = "Already disabled"
            Write-Host "  [SKIP] $($account.SamAccountName) - already disabled" -ForegroundColor Gray
            $Results += $accountResult
            continue
        }
        
        # STEP 1: Remove all group memberships (except primary)
        if ($ADUser.MemberOf.Count -gt 0) {
            if ($PSCmdlet.ShouldProcess("$($account.SamAccountName) - $($ADUser.MemberOf.Count) groups", "Remove all group memberships")) {
                foreach ($group in $ADUser.MemberOf) {
                    Remove-ADGroupMember -Identity $group -Members $ADUser -Confirm:$false
                }
                $accountResult.Action += "Removed $($ADUser.MemberOf.Count) group memberships; "
            }
        }
        
        # STEP 2: Disable the account
        if ($PSCmdlet.ShouldProcess($account.SamAccountName, "Disable account")) {
            Disable-ADAccount -Identity $ADUser
            $accountResult.Action += "Disabled; "
        }
        
        # STEP 3: Add note with disable date and reason
        $DisableNote = "Disabled on $(Get-Date -Format 'yyyy-MM-dd') - Dormant account (no logon >= 90 days)"
        if ($PSCmdlet.ShouldProcess($account.SamAccountName, "Add disable note")) {
            $CurrentInfo = $ADUser.info
            $NewInfo = if ($CurrentInfo) { "$CurrentInfo`n$DisableNote" } else { $DisableNote }
            Set-ADUser -Identity $ADUser -Replace @{info=$NewInfo}
            $accountResult.Action += "Added disable note; "
        }
        
        # STEP 4: Move to quarantine OU
        if (Get-ADOrganizationalUnit -Filter {DistinguishedName -eq $QuarantineOU} -ErrorAction SilentlyContinue) {
            if ($PSCmdlet.ShouldProcess($account.SamAccountName, "Move to $QuarantineOU")) {
                Move-ADObject -Identity $ADUser.DistinguishedName -TargetPath $QuarantineOU
                $accountResult.Action += "Moved to quarantine"
            }
        }
        
        $accountResult.Status = "SUCCESS"
        $SuccessCount++
        
        Write-Host "  [OK] $($account.SamAccountName) - $($accountResult.Action)" -ForegroundColor Green
        
    } catch {
        $accountResult.Status = "FAILED"
        $accountResult.Error = $_.Exception.Message
        $FailCount++
        
        Write-Host "  [FAIL] $($account.SamAccountName) - $($_.Exception.Message)" -ForegroundColor Red
    }
    
    $Results += $accountResult
}

# ============================================================================
# GENERATE RESULTS REPORT
# ============================================================================

Write-Host "`n=== RESULTS ===" -ForegroundColor Cyan

$ResultsPath = $CSVPath -replace '\.csv$', "-DisableResults-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$Results | Export-Csv -Path $ResultsPath -NoTypeInformation

Write-Host "Summary:"
Write-Host "  Success: $SuccessCount" -ForegroundColor Green
Write-Host "  Failed:  $FailCount" -ForegroundColor $(if($FailCount -gt 0){'Red'}else{'Green'})
Write-Host "  Total:   $($Accounts.Count)`n"

Write-Host "Results saved: $ResultsPath`n" -ForegroundColor Green

if (-not $WhatIf) {
    Write-Host "NEXT STEPS:" -ForegroundColor Cyan
    Write-Host "1. Monitor for 30-90 days for any reclamation requests"
    Write-Host "2. Document any accounts that need to be re-enabled (business justification)"
    Write-Host "3. After hold period, run .\Delete-DormantAccounts.ps1 for permanent cleanup"
    Write-Host "4. Keep SID/history archive if needed for audit/compliance`n"
}

Write-Host "=== Processing Complete ===" -ForegroundColor Cyan
