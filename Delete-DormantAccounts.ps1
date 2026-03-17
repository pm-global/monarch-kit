<#
.SYNOPSIS
    Permanently delete dormant accounts after quarantine hold period.

.DESCRIPTION
    Deletes accounts that have been disabled and in quarantine for the specified
    hold period (default: 30 days, configurable 30-90 days per policy).
    
    CRITICAL: This is PERMANENT deletion. Archive SID/history first if needed for
    audit/compliance. Always run with -WhatIf first.

.PARAMETER QuarantineOU
    OU containing quarantined dormant accounts

.PARAMETER MinimumDisabledDays
    Minimum days account must be disabled before deletion (default: 30)

.PARAMETER ArchivePath
    Path to save pre-deletion archive (SID, groups, properties)

.PARAMETER WhatIf
    Preview deletions without making changes (ALWAYS RUN THIS FIRST)

.EXAMPLE
    # STEP 1: Preview with WhatIf
    .\Delete-DormantAccounts.ps1 -WhatIf
    
    # STEP 2: Execute after review
    .\Delete-DormantAccounts.ps1 -MinimumDisabledDays 60

.NOTES
    Author: Network Handover Best Practices
    Version: 1.0
    Requires: ActiveDirectory module, appropriate permissions
    
    HOLD PERIOD GUIDANCE:
    - Microsoft 2026: "several weeks"
    - Industry standard: 30-60 days
    - Conservative: 90 days
    - This script defaults to 30 but allows override
    
    PRE-DELETION ARCHIVE:
    - Saves SID (critical for forensics/audit)
    - Saves group memberships
    - Saves all account properties
    - Required for compliance in some industries
#>

[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
    [Parameter(Mandatory=$false)]
    [string]$QuarantineOU = "",
    
    [Parameter(Mandatory=$false)]
    [ValidateRange(30, 365)]
    [int]$MinimumDisabledDays = 30,
    
    [Parameter(Mandatory=$false)]
    [string]$ArchivePath = ".\Deleted-Accounts-Archive-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv",
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf
)

#Requires -Modules ActiveDirectory

# ============================================================================
# INITIALIZATION
# ============================================================================

$ErrorActionPreference = 'Stop'

Write-Host "=== Delete Dormant Accounts ===" -ForegroundColor Cyan
Write-Host "Minimum disabled period: $MinimumDisabledDays days"
Write-Host "Mode: $(if($WhatIf){'WHATIF (safe preview)'}else{'EXECUTION (PERMANENT DELETION)'})`n" -ForegroundColor $(if($WhatIf){'Green'}else{'Red'})

if (-not $WhatIf) {
    Write-Host "WARNING: This will PERMANENTLY delete accounts!" -ForegroundColor Red
    Write-Host "Press Ctrl+C to abort, or any key to continue..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Write-Host ""
}

# Determine quarantine OU
if ([string]::IsNullOrEmpty($QuarantineOU)) {
    $DomainDN = (Get-ADDomain).DistinguishedName
    $QuarantineOU = "OU=zQuarantine-Dormant,$DomainDN"
}

Write-Host "Quarantine OU: $QuarantineOU`n"

# Verify quarantine OU exists
if (-not (Get-ADOrganizationalUnit -Filter {DistinguishedName -eq $QuarantineOU} -ErrorAction SilentlyContinue)) {
    Write-Error "Quarantine OU not found: $QuarantineOU"
    exit 1
}

# ============================================================================
# FIND ELIGIBLE ACCOUNTS FOR DELETION
# ============================================================================

Write-Host "Finding accounts eligible for deletion..." -ForegroundColor Yellow

try {
    # Get all disabled users in quarantine OU
    $QuarantinedUsers = Get-ADUser -SearchBase $QuarantineOU -Filter {Enabled -eq $false} -Properties `
        whenChanged,
        info,
        Description,
        MemberOf,
        SID,
        Created,
        PasswordLastSet,
        LastLogonDate,
        CanonicalName
    
    Write-Host "Found $($QuarantinedUsers.Count) disabled accounts in quarantine" -ForegroundColor Green
} catch {
    Write-Error "Failed to query quarantine OU: $_"
    exit 1
}

# Filter for accounts that meet minimum disabled time
$CutoffDate = (Get-Date).AddDays(-$MinimumDisabledDays)
$EligibleAccounts = @()

foreach ($user in $QuarantinedUsers) {
    # Try to parse disable date from info field (added by Disable script)
    $DisableDate = $null
    
    if ($user.info -match "Disabled on (\d{4}-\d{2}-\d{2})") {
        $DisableDate = [DateTime]::Parse($Matches[1])
    } else {
        # Fall back to whenChanged (less accurate but better than nothing)
        $DisableDate = $user.whenChanged
    }
    
    # Check if account has been disabled long enough
    if ($DisableDate -and $DisableDate -le $CutoffDate) {
        $DaysDisabled = ((Get-Date) - $DisableDate).Days
        
        $EligibleAccounts += [PSCustomObject]@{
            SamAccountName    = $user.SamAccountName
            DisplayName       = $user.DisplayName
            SID               = $user.SID.Value
            DisableDate       = $DisableDate
            DaysDisabled      = $DaysDisabled
            Created           = $user.Created
            Description       = $user.Description
            CanonicalName     = $user.CanonicalName
            PasswordLastSet   = $user.PasswordLastSet
            LastLogonDate     = $user.LastLogonDate
            MemberOf          = ($user.MemberOf | ForEach-Object { (Get-ADGroup $_).Name }) -join "; "
            Info              = $user.info
            DistinguishedName = $user.DistinguishedName
        }
    }
}

Write-Host "Eligible for deletion: $($EligibleAccounts.Count) accounts (disabled >= $MinimumDisabledDays days)`n" -ForegroundColor Yellow

if ($EligibleAccounts.Count -eq 0) {
    Write-Host "No accounts meet deletion criteria. Exiting." -ForegroundColor Green
    exit 0
}

# ============================================================================
# CREATE PRE-DELETION ARCHIVE
# ============================================================================

Write-Host "Creating pre-deletion archive..." -ForegroundColor Yellow

$EligibleAccounts | Export-Csv -Path $ArchivePath -NoTypeInformation

Write-Host "Archive saved: $ArchivePath" -ForegroundColor Green
Write-Host "This archive contains SIDs and full account details for audit/recovery`n"

# ============================================================================
# DELETE ACCOUNTS
# ============================================================================

if ($EligibleAccounts.Count -gt 0) {
    Write-Host "Accounts to be deleted:" -ForegroundColor Yellow
    $EligibleAccounts | Format-Table SamAccountName, DisplayName, DaysDisabled, DisableDate -AutoSize | Out-String | Write-Host
}

$Results = @()
$DeletedCount = 0
$FailCount = 0

foreach ($account in $EligibleAccounts) {
    $accountResult = [PSCustomObject]@{
        SamAccountName = $account.SamAccountName
        Status         = ""
        Error          = ""
    }
    
    try {
        if ($PSCmdlet.ShouldProcess("$($account.SamAccountName) (disabled $($account.DaysDisabled) days)", "PERMANENTLY DELETE")) {
            # Perform deletion
            Remove-ADUser -Identity $account.SamAccountName -Confirm:$false
            
            $accountResult.Status = "DELETED"
            $DeletedCount++
            
            Write-Host "  [DELETED] $($account.SamAccountName) - disabled $($account.DaysDisabled) days" -ForegroundColor Red
        }
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

$ResultsPath = $ArchivePath -replace '\.csv$', "-DeletionResults.csv"
$Results | Export-Csv -Path $ResultsPath -NoTypeInformation

Write-Host "Summary:"
Write-Host "  Deleted: $DeletedCount" -ForegroundColor $(if($DeletedCount -gt 0){'Red'}else{'Green'})
Write-Host "  Failed:  $FailCount" -ForegroundColor $(if($FailCount -gt 0){'Red'}else{'Green'})
Write-Host "  Total:   $($EligibleAccounts.Count)`n"

Write-Host "Results saved: $ResultsPath" -ForegroundColor Green
Write-Host "Archive saved: $ArchivePath (KEEP FOR COMPLIANCE)`n" -ForegroundColor Yellow

if (-not $WhatIf -and $DeletedCount -gt 0) {
    Write-Host "IMPORTANT:" -ForegroundColor Cyan
    Write-Host "- Accounts have been permanently deleted from Active Directory"
    Write-Host "- SID and property archive saved in: $ArchivePath"
    Write-Host "- Retain archive per your compliance requirements (typically 7 years)"
    Write-Host "- Deletions will replicate to all DCs within 15 minutes"
    Write-Host "- Azure AD Connect will sync deletions on next cycle (if hybrid)`n"
}

Write-Host "=== Processing Complete ===" -ForegroundColor Cyan
