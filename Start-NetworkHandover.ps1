<#
.SYNOPSIS
    Master runbook for network handover - guides you through the entire process.

.DESCRIPTION
    Interactive script that walks you through the complete network handover workflow:
    1. Baseline documentation
    2. GPO audit
    3. Privileged access review
    4. Dormant account management
    
    Provides checklists, recommendations, and next steps at each stage.

.PARAMETER Phase
    Which phase to run:
    - Discovery: Initial documentation and audits
    - Review: Analyze outputs and plan remediation
    - Remediation: Execute approved changes
    - Monitoring: Track progress and watch for issues
    - Cleanup: Final deletion after hold period

.PARAMETER OutputPath
    Base directory for all outputs

.EXAMPLE
    .\Start-NetworkHandover.ps1 -Phase Discovery
    .\Start-NetworkHandover.ps1 -Phase Remediation

.NOTES
    Author: Network Handover Best Practices
    Version: 1.0
    Requires: All toolkit scripts in same directory
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('Discovery', 'Review', 'Remediation', 'Monitoring', 'Cleanup', 'Menu')]
    [string]$Phase = 'Menu',
    
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".\Network-Handover-$(Get-Date -Format 'yyyyMMdd')"
)

# ============================================================================
# INITIALIZATION
# ============================================================================

$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path

# Check for required scripts
$RequiredScripts = @(
    'Create-NetworkBaseline.ps1',
    'Export-GPOAudit.ps1',
    'Audit-PrivilegedAccess.ps1',
    'Find-DormantAccounts.ps1',
    'Disable-DormantAccounts.ps1',
    'Delete-DormantAccounts.ps1'
)

$MissingScripts = @()
foreach ($script in $RequiredScripts) {
    if (-not (Test-Path (Join-Path $ScriptPath $script))) {
        $MissingScripts += $script
    }
}

if ($MissingScripts) {
    Write-Host "ERROR: Missing required scripts:" -ForegroundColor Red
    $MissingScripts | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host "`nEnsure all toolkit scripts are in: $ScriptPath" -ForegroundColor Yellow
    exit 1
}

# Create output directory
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Show-Banner {
    param([string]$Text)
    Write-Host ""
    Write-Host "="*80 -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host "="*80 -ForegroundColor Cyan
    Write-Host ""
}

function Show-ChecklistItem {
    param([string]$Item, [switch]$Complete, [switch]$InProgress, [switch]$NotStarted)
    
    if ($Complete) {
        Write-Host "  [✓] $Item" -ForegroundColor Green
    } elseif ($InProgress) {
        Write-Host "  [→] $Item" -ForegroundColor Yellow
    } else {
        Write-Host "  [ ] $Item" -ForegroundColor Gray
    }
}

function Invoke-SafeScript {
    param(
        [string]$ScriptName,
        [hashtable]$Parameters = @{}
    )
    
    $scriptPath = Join-Path $ScriptPath $ScriptName
    
    Write-Host "Running: $ScriptName" -ForegroundColor Yellow
    
    try {
        & $scriptPath @Parameters
        Write-Host "`n$ScriptName completed successfully`n" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "`nERROR in $ScriptName : $_`n" -ForegroundColor Red
        return $false
    }
}

function Show-NextSteps {
    param([string[]]$Steps)
    
    Write-Host "`nNEXT STEPS:" -ForegroundColor Cyan
    $i = 1
    foreach ($step in $Steps) {
        Write-Host "  $i. $step"
        $i++
    }
    Write-Host ""
}

function Wait-ForContinue {
    Write-Host "Press any key to continue..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Write-Host ""
}

# ============================================================================
# PHASE: DISCOVERY
# ============================================================================

function Start-DiscoveryPhase {
    Show-Banner "PHASE 1: DISCOVERY - Document Current State"
    
    Write-Host "This phase will:"
    Write-Host "  • Create baseline documentation of your AD environment"
    Write-Host "  • Export and analyze all Group Policy Objects"
    Write-Host "  • Audit privileged access and permissions"
    Write-Host "  • Identify dormant user accounts"
    Write-Host ""
    Write-Host "Expected time: 30-60 minutes"
    Write-Host "Output directory: $OutputPath`n"
    
    Wait-ForContinue
    
    # Create subdirectories
    $BaselinePath = Join-Path $OutputPath "01-Baseline"
    $GPOPath = Join-Path $OutputPath "02-GPO-Audit"
    $PrivilegedPath = Join-Path $OutputPath "03-Privileged-Access"
    $DormantPath = Join-Path $OutputPath "04-Dormant-Accounts"
    
    # Step 1: Baseline
    Show-Banner "Step 1/4: Creating Network Baseline"
    Write-Host "Documenting domain controllers, FSMO roles, OUs, replication health..."
    Write-Host ""
    
    $success = Invoke-SafeScript -ScriptName "Create-NetworkBaseline.ps1" -Parameters @{
        OutputPath = $BaselinePath
    }
    
    if ($success) {
        Write-Host "✓ Baseline documentation saved to: $BaselinePath" -ForegroundColor Green
    }
    
    Wait-ForContinue
    
    # Step 2: GPO Audit
    Show-Banner "Step 2/4: Exporting Group Policies"
    Write-Host "This will export ALL GPOs in HTML, XML, and CSV formats..."
    Write-Host "Including permission analysis to find overpermissioned GPOs..."
    Write-Host ""
    
    $success = Invoke-SafeScript -ScriptName "Export-GPOAudit.ps1" -Parameters @{
        OutputPath = $GPOPath
        IncludePermissions = $true
        IncludeWMIFilters = $true
    }
    
    if ($success) {
        Write-Host "✓ GPO audit saved to: $GPOPath" -ForegroundColor Green
        Write-Host "  → Open: $GPOPath\01-HTML-Reports\00-INDEX.html" -ForegroundColor Yellow
    }
    
    Wait-ForContinue
    
    # Step 3: Privileged Access
    Show-Banner "Step 3/4: Auditing Privileged Access"
    Write-Host "Analyzing Domain Admins, Enterprise Admins, and other privileged groups..."
    Write-Host "Including nested group memberships and risk scoring..."
    Write-Host ""
    
    $success = Invoke-SafeScript -ScriptName "Audit-PrivilegedAccess.ps1" -Parameters @{
        OutputPath = $PrivilegedPath
        IncludeNestedGroups = $true
    }
    
    if ($success) {
        Write-Host "✓ Privileged access audit saved to: $PrivilegedPath" -ForegroundColor Green
        Write-Host "  → Review: $PrivilegedPath\REVIEW-high-risk-privileged-accounts.csv" -ForegroundColor Yellow
    }
    
    Wait-ForContinue
    
    # Step 4: Dormant Accounts
    Show-Banner "Step 4/4: Finding Dormant Accounts"
    Write-Host "Querying LastLogon across all domain controllers (90-day threshold)..."
    Write-Host "This may take 10-20 minutes depending on domain size..."
    Write-Host ""
    
    $dormantCSV = Join-Path $DormantPath "dormant-accounts.csv"
    
    $success = Invoke-SafeScript -ScriptName "Find-DormantAccounts.ps1" -Parameters @{
        DormantDays = 90
        OutputPath = $dormantCSV
    }
    
    if ($success) {
        Write-Host "✓ Dormant account list saved to: $dormantCSV" -ForegroundColor Green
    }
    
    # Discovery complete
    Show-Banner "DISCOVERY PHASE COMPLETE"
    
    Write-Host "All audit data collected and saved to: $OutputPath`n"
    
    Write-Host "OUTPUTS SUMMARY:" -ForegroundColor Cyan
    Write-Host "  Baseline:     $BaselinePath"
    Write-Host "  GPO Audit:    $GPOPath"
    Write-Host "  Privileged:   $PrivilegedPath"
    Write-Host "  Dormant:      $DormantPath`n"
    
    Show-NextSteps @(
        "Review the EXECUTIVE-SUMMARY.txt files in each directory",
        "Open GPO HTML index and browse through policies",
        "Check REVIEW-high-risk-privileged-accounts.csv for immediate concerns",
        "Review dormant accounts CSV and identify accounts for disabling",
        "Run: .\Start-NetworkHandover.ps1 -Phase Review"
    )
}

# ============================================================================
# PHASE: REVIEW
# ============================================================================

function Start-ReviewPhase {
    Show-Banner "PHASE 2: REVIEW - Analyze Findings and Plan Remediation"
    
    Write-Host "Manual review phase checklist:"
    Write-Host ""
    
    Write-Host "GPO REVIEW:" -ForegroundColor Yellow
    Show-ChecklistItem "Opened GPO HTML index and reviewed major policies"
    Show-ChecklistItem "Checked for unlinked (orphaned) GPOs"
    Show-ChecklistItem "Reviewed policies with User Rights Assignment"
    Show-ChecklistItem "Checked startup/logon scripts for hardcoded credentials"
    Show-ChecklistItem "Verified GPO linkage scope is appropriate"
    Show-ChecklistItem "Compared high-risk settings against security baseline"
    Write-Host ""
    
    Write-Host "PRIVILEGED ACCESS REVIEW:" -ForegroundColor Yellow
    Show-ChecklistItem "Verified Domain Admin count is reasonable (< 10)"
    Show-ChecklistItem "Identified user accounts in admin groups (should be separate admin accounts)"
    Show-ChecklistItem "Found service accounts with admin rights"
    Show-ChecklistItem "Reviewed stale admin accounts (no recent logon)"
    Show-ChecklistItem "Checked for accounts with SPN + admin rights"
    Show-ChecklistItem "Created remediation plan for overpermissioned accounts"
    Write-Host ""
    
    Write-Host "DORMANT ACCOUNT REVIEW:" -ForegroundColor Yellow
    Show-ChecklistItem "Reviewed full dormant accounts CSV"
    Show-ChecklistItem "Validated automatic exclusions are appropriate"
    Show-ChecklistItem "Identified accounts for disabling (business review)"
    Show-ChecklistItem "Notified account owners/managers where possible"
    Show-ChecklistItem "Created reviewed subset CSV for disable phase"
    Show-ChecklistItem "Documented exceptions with business justification"
    Write-Host ""
    
    Write-Host "DOCUMENTATION:" -ForegroundColor Yellow
    Show-ChecklistItem "Created remediation plan document"
    Show-ChecklistItem "Defined rollback procedures"
    Show-ChecklistItem "Scheduled change windows"
    Show-ChecklistItem "Identified stakeholders for notification"
    Show-ChecklistItem "Established monitoring plan"
    Write-Host ""
    
    Show-NextSteps @(
        "Complete all checklist items above",
        "Get approval for remediation plan from management",
        "Schedule maintenance window if needed",
        "Create reviewed-dormant.csv with accounts approved for disabling",
        "Run: .\Start-NetworkHandover.ps1 -Phase Remediation"
    )
}

# ============================================================================
# PHASE: REMEDIATION
# ============================================================================

function Start-RemediationPhase {
    Show-Banner "PHASE 3: REMEDIATION - Execute Approved Changes"
    
    Write-Host "WARNING: This phase will make changes to Active Directory!" -ForegroundColor Red
    Write-Host "Ensure you have:"
    Write-Host "  • Completed full review phase"
    Write-Host "  • Received management approval"
    Write-Host "  • Created reviewed-dormant.csv with accounts to disable"
    Write-Host "  • Taken AD backup or snapshots"
    Write-Host "  • Scheduled maintenance window (if applicable)"
    Write-Host ""
    
    $continue = Read-Host "Continue with remediation? (yes/no)"
    if ($continue -ne 'yes') {
        Write-Host "Remediation cancelled." -ForegroundColor Yellow
        return
    }
    
    # Disable dormant accounts
    Show-Banner "Disabling Dormant Accounts"
    
    $reviewedCSV = Read-Host "Path to reviewed dormant accounts CSV"
    
    if (-not (Test-Path $reviewedCSV)) {
        Write-Host "ERROR: CSV not found: $reviewedCSV" -ForegroundColor Red
        return
    }
    
    Write-Host "`nStep 1: Preview changes with WhatIf..." -ForegroundColor Yellow
    
    $success = Invoke-SafeScript -ScriptName "Disable-DormantAccounts.ps1" -Parameters @{
        CSVPath = $reviewedCSV
        WhatIf = $true
    }
    
    if (-not $success) {
        Write-Host "WhatIf failed. Review errors before proceeding." -ForegroundColor Red
        return
    }
    
    Write-Host "`nStep 2: Execute disable operation..." -ForegroundColor Yellow
    $execute = Read-Host "Proceed with actual disable? (yes/no)"
    
    if ($execute -eq 'yes') {
        $success = Invoke-SafeScript -ScriptName "Disable-DormantAccounts.ps1" -Parameters @{
            CSVPath = $reviewedCSV
        }
        
        if ($success) {
            Show-Banner "REMEDIATION PHASE COMPLETE"
            
            Write-Host "Accounts have been disabled and moved to quarantine.`n"
            
            Show-NextSteps @(
                "Monitor for 30-90 days (default: 30 days per policy)",
                "Watch for authentication failures or reclamation requests",
                "Document any accounts that need to be re-enabled",
                "Track metrics for reporting",
                "Run: .\Start-NetworkHandover.ps1 -Phase Monitoring"
            )
        }
    } else {
        Write-Host "Remediation cancelled." -ForegroundColor Yellow
    }
}

# ============================================================================
# PHASE: MONITORING
# ============================================================================

function Start-MonitoringPhase {
    Show-Banner "PHASE 4: MONITORING - Track Progress and Issues"
    
    Write-Host "Monitoring phase checklist (30-90 day period):"
    Write-Host ""
    
    Write-Host "DAILY CHECKS:" -ForegroundColor Yellow
    Show-ChecklistItem "Review authentication failure logs"
    Show-ChecklistItem "Monitor helpdesk tickets related to account access"
    Show-ChecklistItem "Check for unexpected service interruptions"
    Write-Host ""
    
    Write-Host "WEEKLY CHECKS:" -ForegroundColor Yellow
    Show-ChecklistItem "Review reclamation requests"
    Show-ChecklistItem "Document any re-enabled accounts with justification"
    Show-ChecklistItem "Update exception list based on learnings"
    Show-ChecklistItem "Report metrics to stakeholders"
    Write-Host ""
    
    Write-Host "HOLD PERIOD COMPLETE:" -ForegroundColor Yellow
    Show-ChecklistItem "Minimum hold period elapsed (30-90 days)"
    Show-ChecklistItem "No outstanding reclamation requests"
    Show-ChecklistItem "All exceptions documented"
    Show-ChecklistItem "Final approval for deletion obtained"
    Write-Host ""
    
    Write-Host "`nMONITORING METRICS TO TRACK:" -ForegroundColor Cyan
    Write-Host "  • Accounts disabled: ___"
    Write-Host "  • Reclamation requests: ___"
    Write-Host "  • Accounts re-enabled: ___"
    Write-Host "  • Days in monitoring: ___"
    Write-Host "  • Issues encountered: ___"
    Write-Host ""
    
    Show-NextSteps @(
        "Complete monitoring hold period (30-90 days)",
        "Document all reclamations and exceptions",
        "Get final approval for permanent deletion",
        "Run: .\Start-NetworkHandover.ps1 -Phase Cleanup"
    )
}

# ============================================================================
# PHASE: CLEANUP
# ============================================================================

function Start-CleanupPhase {
    Show-Banner "PHASE 5: CLEANUP - Permanent Deletion"
    
    Write-Host "WARNING: This phase PERMANENTLY deletes accounts!" -ForegroundColor Red
    Write-Host ""
    Write-Host "Pre-deletion checklist:" -ForegroundColor Yellow
    Show-ChecklistItem "Hold period complete (30-90 days)"
    Show-ChecklistItem "No outstanding reclamation requests"
    Show-ChecklistItem "All exceptions documented"
    Show-ChecklistItem "Final approval obtained"
    Show-ChecklistItem "Archive retention plan in place (typically 7 years)"
    Write-Host ""
    
    $continue = Read-Host "Continue with permanent deletion? (yes/no)"
    if ($continue -ne 'yes') {
        Write-Host "Cleanup cancelled." -ForegroundColor Yellow
        return
    }
    
    Show-Banner "Deleting Dormant Accounts After Hold Period"
    
    $minimumDays = Read-Host "Minimum disabled days for deletion (default: 30)"
    if ([string]::IsNullOrWhiteSpace($minimumDays)) {
        $minimumDays = 30
    }
    
    Write-Host "`nStep 1: Preview deletions with WhatIf..." -ForegroundColor Yellow
    
    $params = @{
        MinimumDisabledDays = [int]$minimumDays
        WhatIf = $true
    }
    
    $success = Invoke-SafeScript -ScriptName "Delete-DormantAccounts.ps1" -Parameters $params
    
    if (-not $success) {
        Write-Host "WhatIf failed. Review errors before proceeding." -ForegroundColor Red
        return
    }
    
    Write-Host "`nStep 2: Execute deletion..." -ForegroundColor Yellow
    $execute = Read-Host "Proceed with PERMANENT deletion? (yes/no)"
    
    if ($execute -eq 'yes') {
        $params.Remove('WhatIf')
        
        $success = Invoke-SafeScript -ScriptName "Delete-DormantAccounts.ps1" -Parameters $params
        
        if ($success) {
            Show-Banner "CLEANUP PHASE COMPLETE"
            
            Write-Host "Accounts have been permanently deleted.`n"
            
            Show-NextSteps @(
                "Retain deletion archive per compliance requirements (typically 7 years)",
                "Document final metrics for audit",
                "Schedule next quarterly audit (repeat discovery phase)",
                "Update documentation with lessons learned",
                "Consider tightening dormancy threshold if appropriate"
            )
        }
    } else {
        Write-Host "Cleanup cancelled." -ForegroundColor Yellow
    }
}

# ============================================================================
# MAIN MENU
# ============================================================================

function Show-MainMenu {
    while ($true) {
        Show-Banner "NETWORK HANDOVER TOOLKIT - MAIN MENU"
        
        Write-Host "Select phase to run:"
        Write-Host ""
        Write-Host "  1. Discovery    - Document current state (GPOs, privileges, dormant accounts)"
        Write-Host "  2. Review       - Checklist for manual review and planning"
        Write-Host "  3. Remediation  - Execute approved changes (disable accounts)"
        Write-Host "  4. Monitoring   - Track progress during hold period"
        Write-Host "  5. Cleanup      - Permanent deletion after hold period"
        Write-Host ""
        Write-Host "  Q. Quit"
        Write-Host ""
        
        $choice = Read-Host "Enter choice (1-5 or Q)"
        
        switch ($choice) {
            '1' { Start-DiscoveryPhase; Wait-ForContinue }
            '2' { Start-ReviewPhase; Wait-ForContinue }
            '3' { Start-RemediationPhase; Wait-ForContinue }
            '4' { Start-MonitoringPhase; Wait-ForContinue }
            '5' { Start-CleanupPhase; Wait-ForContinue }
            'Q' { Write-Host "Exiting..."; return }
            default { Write-Host "Invalid choice. Press any key to continue..." -ForegroundColor Red; Wait-ForContinue }
        }
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Show-Banner "NETWORK HANDOVER TOOLKIT"

Write-Host "Professional scripts for inheriting and cleaning up un/mismanaged networks"
Write-Host "Version: 1.0"
Write-Host ""
Write-Host "Output directory: $OutputPath"
Write-Host ""

# Execute requested phase or show menu
switch ($Phase) {
    'Discovery'    { Start-DiscoveryPhase }
    'Review'       { Start-ReviewPhase }
    'Remediation'  { Start-RemediationPhase }
    'Monitoring'   { Start-MonitoringPhase }
    'Cleanup'      { Start-CleanupPhase }
    'Menu'         { Show-MainMenu }
}
